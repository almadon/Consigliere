#!/usr/bin/env python3
"""cmdr: the fleet's control page. Metadata from the fleet repo, live status from Loki, launch buttons for the admin tools.

Standard library only. Sign-in is OpenID Connect (authorization code + PKCE) against your identity provider, with a signed session
cookie; optionally a trusted reverse proxy may pass the identity in headers (only with a shared secret the proxy adds).
This page shows and links; it runs nothing on any host. The only thing it can do is re-read its own live status (POST /api/refresh).
"""
import base64
import hashlib
import hmac
import html
import http.server
import json
import os
import re
import secrets
import socketserver
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ENV = os.environ.get
URL = (ENV("CMDR_URL") or "").rstrip("/")
AUTH = ENV("CMDR_AUTH", "oidc")
ISSUER = (ENV("CMDR_ISSUER") or "").rstrip("/")
CLIENT_ID, CLIENT_SECRET = ENV("CMDR_CLIENT_ID", ""), ENV("CMDR_CLIENT_SECRET", "")
SESSION_SECRET = (ENV("CMDR_SESSION_SECRET") or "").encode()
ADMIN_GROUPS = [g.strip() for g in (ENV("CMDR_ADMIN_GROUPS") or "").split(",") if g.strip()]
VIEWER_GROUPS = [g.strip() for g in (ENV("CMDR_VIEWER_GROUPS") or "").split(",") if g.strip()]
PROXY_SECRET = ENV("CMDR_PROXY_SECRET", "")
FRAME_ANCESTORS = ENV("CMDR_FRAME_ANCESTORS", "'none'")
INVENTORY = ENV("CMDR_INVENTORY", "/data/inventory.json")
LOKI = (ENV("CMDR_LOKI") or "").rstrip("/")
VICTORIA = (ENV("CMDR_VICTORIA") or "").rstrip("/")
INTERVAL = int(ENV("CMDR_STATUS_INTERVAL", "60"))
TAGS_DIRS = [d for d in (ENV("CMDR_TAGS_DIRS") or "").split(":") if d]
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
SESSION_TTL = int(ENV("CMDR_SESSION_TTL", str(8 * 3600)))
SECURE = URL.startswith("https://")
SAMESITE = ENV("CMDR_COOKIE_SAMESITE", "Lax") if ENV("CMDR_COOKIE_SAMESITE", "Lax") in ("Lax", "Strict", "None") else "Lax"
REFRESH_MIN = 10
RECAP = re.compile(r"ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)")


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def sign(payload):
    raw = b64(json.dumps(payload, separators=(",", ":")).encode())
    return raw + "." + b64(hmac.new(SESSION_SECRET, raw.encode(), hashlib.sha256).digest())


def verify(token):
    try:
        raw, mac = token.split(".", 1)
        want = b64(hmac.new(SESSION_SECRET, raw.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(mac, want):
            return None
        data = json.loads(unb64(raw))
        return data if data.get("exp", 0) > time.time() else None
    except Exception:  # noqa: BLE001 - any malformed cookie is simply "not signed in"
        return None


def http_json(url, data=None, headers=None, timeout=15):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data is not None else None, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


_disc = {"t": 0, "d": None}


def discovery():
    if not _disc["d"] or time.time() - _disc["t"] > 3600:
        _disc["d"], _disc["t"] = http_json(ISSUER + "/.well-known/openid-configuration"), time.time()
    return _disc["d"]


def role_for(groups):
    if set(groups) & set(ADMIN_GROUPS):
        return "admin"
    if set(groups) & set(VIEWER_GROUPS):
        return "viewer"
    return ""


# ---------------------------------------------------------------- inventory and status
def load_inventory():
    try:
        with open(INVENTORY) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"hosts": [], "tools": [], "host_links": [], "generated": 0}


def load_tag_descriptions():
    out = {}
    for d in TAGS_DIRS:
        try:
            for dim in sorted(os.listdir(d)):
                p = os.path.join(d, dim)
                if not os.path.isdir(p):
                    continue
                for f in sorted(os.listdir(p)):
                    if f.endswith(".yml"):
                        m = re.search(r'^description:\s*"?(.*?)"?\s*$', open(os.path.join(p, f)).read(), re.M)
                        out.setdefault(dim, {}).setdefault(f[:-4], m.group(1) if m else "")
        except OSError:
            continue
    return out


STATUS = {"updated": 0, "ok": False, "error": "not collected yet", "alive": {}, "reconcile": {}, "exposure": {}, "stats": {}}
LOCK = threading.Lock()


def loki(path, **params):
    return http_json(LOKI + path + "?" + urllib.parse.urlencode(params), timeout=20)


def loki_lines(query, hours, limit):
    end = int(time.time())
    r = loki("/loki/api/v1/query_range", query=query, start=(end - hours * 3600) * 10**9, end=end * 10**9, limit=limit, direction="backward")
    for s in r.get("data", {}).get("result", []):
        for ts, line in s["values"]:
            yield s["stream"], int(ts) // 10**9, line


def parse_event(line):
    i, j = line.find("{"), line.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        d = json.loads(line[i:j + 1])
    except ValueError:
        return None
    if isinstance(d.get("MESSAGE"), str):          # journald records may wrap the original line
        return parse_event(d["MESSAGE"])
    return d if "event" in d else None


# ---------------------------------------------------------------- host stats (VictoriaMetrics, from the otel_agent's hostmetrics)
HOST_LABELS = ("host.name", "host_name", "host", "instance")
METRIC = {  # OTLP names, then the Prometheus-style spellings a store may have converted them to
    "cpu": ["system.cpu.utilization", "system_cpu_utilization_ratio", "system_cpu_utilization"],
    "mem": ["system.memory.utilization", "system_memory_utilization_ratio", "system_memory_utilization"],
    "disk": ["system.filesystem.utilization", "system_filesystem_utilization_ratio", "system_filesystem_utilization"],
    "load": ["system.cpu.load_average.1m", "system_cpu_load_average_1m"],
}


def vm(path, **params):
    return http_json(VICTORIA + path + "?" + urllib.parse.urlencode(params))


def vm_instant(kind, matcher=""):
    """The series for one kind of metric, trying each spelling of its name; returns (name, [(labels, value)])."""
    for name in METRIC[kind]:
        r = vm("/api/v1/query", query='{__name__="%s"%s}' % (name, matcher))
        res = r.get("data", {}).get("result", [])
        if res:
            return name, [(x["metric"], float(x["value"][1])) for x in res]
    return None, []


def label_of(metric):
    for k in HOST_LABELS:
        if metric.get(k):
            return k, metric[k].lower()
    return None, None


def collect_stats():
    out, label = {}, None
    cpu_by, mem_by, disk_by, load_by = {}, {}, {}, {}
    _, cpu = vm_instant("cpu", ',state="idle"')
    for m, v in cpu:
        label, host = label_of(m)
        if host:
            cpu_by.setdefault(host, []).append(v)
    _, mem = vm_instant("mem", ',state="used"')
    for m, v in mem:
        label, host = label_of(m)
        if host:
            mem_by[host] = v
    _, disk = vm_instant("disk")
    for m, v in disk:
        label, host = label_of(m)
        if host:
            # the root filesystem if there is one, else the fullest
            if m.get("mountpoint") == "/" or host not in disk_by or (disk_by[host][0] != "/" and v > disk_by[host][1]):
                disk_by[host] = (m.get("mountpoint", ""), v)
    _, load = vm_instant("load")
    for m, v in load:
        label, host = label_of(m)
        if host:
            load_by[host] = v
    now = int(time.time())
    for host in set(cpu_by) | set(mem_by) | set(disk_by):
        out[host] = {"cpu": (1 - sum(cpu_by[host]) / len(cpu_by[host])) if host in cpu_by else None, "cores": len(cpu_by.get(host, [])) or None,
                     "mem": mem_by.get(host), "disk": disk_by[host][1] if host in disk_by else None, "load": load_by.get(host), "ts": now}
    return out, label


def stats_history(host):
    """Six hours of cpu and memory for one host, 5-minute steps, as lists of [timestamp, 0..1]."""
    label = STATS_LABEL
    if not VICTORIA or not label or not re.fullmatch(r"[a-z0-9._-]+", host):
        return {}
    end = int(time.time())
    out = {}
    for kind, tmpl in (("cpu", '1 - avg({__name__="%s",state="idle",%s="%s"})'), ("mem", 'avg({__name__="%s",state="used",%s="%s"})')):
        for name in METRIC[kind]:
            q = tmpl % (name, label, host)
            res = vm("/api/v1/query_range", query=q, start=end - 6 * 3600, end=end, step=300).get("data", {}).get("result", [])
            if res:
                out[kind] = [[int(t), float(v)] for t, v in res[0]["values"]]
                break
    return out


STATS_LABEL = None


def collect():
    alive, recon, expo, errors = {}, {}, {}, []
    try:
        r = loki("/loki/api/v1/query", query='sum by (host_name) (count_over_time({host_name=~".+"}[10m]))')
        for s in r.get("data", {}).get("result", []):
            alive[s["metric"].get("host_name", "").lower()] = int(float(s["value"][1]))
    except Exception as e:  # noqa: BLE001
        errors.append("alive: " + type(e).__name__)
    try:
        for stream, ts, line in loki_lines('{unit=~"fleet-reconcile(.service)?"} |~ "ok=[0-9]+ +changed="', 24, 2000):
            m = RECAP.search(line)
            host = (stream.get("host_name") or "").lower()
            if m and host and (host not in recon or ts > recon[host]["ts"]):
                recon[host] = {"ts": ts, "ok": int(m.group(1)), "changed": int(m.group(2)), "unreachable": int(m.group(3)), "failed": int(m.group(4))}
    except Exception as e:  # noqa: BLE001
        errors.append("reconcile: " + type(e).__name__)
    try:
        for stream, ts, line in loki_lines('{unit=~"fleet-exposure-watch(.service)?"} |= "\\"event\\""', 72, 2000):
            d = parse_event(line)
            if d and d.get("event") == "scanned":
                key = d.get("target", "") + "|" + d.get("ip", "")
                if key not in expo or ts > expo[key]["ts"]:
                    expo[key] = {"ts": ts, "target": d.get("target"), "ip": d.get("ip"), "open_tcp": d.get("open_tcp", []), "findings": d.get("finding_list", [])}
    except Exception as e:  # noqa: BLE001
        errors.append("exposure: " + type(e).__name__)
    stats = None
    if VICTORIA:
        global STATS_LABEL
        try:
            stats, label = collect_stats()
            STATS_LABEL = label or STATS_LABEL
        except Exception as e:  # noqa: BLE001
            errors.append("stats: " + type(e).__name__)
    with LOCK:
        STATUS.update({"updated": int(time.time()), "ok": not errors, "error": "; ".join(errors), "alive": alive, "reconcile": recon, "exposure": expo})
        if stats is not None:
            STATUS["stats"] = stats


WAKE = threading.Event()


def collector():
    while True:
        if LOKI:
            collect()
        else:
            with LOCK:
                STATUS.update({"updated": int(time.time()), "ok": False, "error": "no Loki configured"})
        WAKE.wait(INTERVAL)
        WAKE.clear()


def fleet_view(user):
    inv = load_inventory()
    with LOCK:
        st = dict(STATUS)
    hosts = []
    for h in inv.get("hosts", []):
        n = h["name"].lower()
        rec = st["reconcile"].get(n)
        hosts.append(dict(h, status={"alive": (st["alive"].get(n, 0) > 0) if st["alive"] else None, "reconcile": rec, "stats": st.get("stats", {}).get(n)}))
    return {"user": user, "generated": inv.get("generated", 0), "hosts": hosts, "tools": inv.get("tools", []), "host_links": inv.get("host_links", []),
            "host_commands": inv.get("host_commands", []), "commands": inv.get("commands", []), "tag_kinds": inv.get("tag_kinds", {}), "mgmt_kinds": inv.get("mgmt_kinds", {}), "tag_overrides": inv.get("tag_overrides", {}),
            "idp_name": inv.get("idp_name", ""), "stats_on": bool(VICTORIA),
            "tags": load_tag_descriptions(), "exposure": sorted(st["exposure"].values(), key=lambda e: (e["target"] or "", e["ip"] or "")),
            "status": {"updated": st["updated"], "ok": st["ok"], "error": st["error"]}}


# ---------------------------------------------------------------- web
# What the sign-in panel inside a frame needs before anyone is signed in (nothing about the fleet).
PUBLIC_STATIC = {"/static/signin.js", "/static/style.css", "/static/theme.js", "/static/logo.svg", "/static/done.js"}
CT = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "cmdr"
    sys_version = ""

    def log_message(self, fmt, *args):
        print(json.dumps({"event": "http", "client": self.client_address[0], "line": fmt % args}), flush=True)

    def send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
                         f"base-uri 'none'; form-action 'self'; frame-ancestors {FRAME_ANCESTORS}")
        if ctype.startswith("application/json"):
            self.send_header("Cache-Control", "no-store")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, cookies=()):
        self.send(302, b"", extra=[("Location", to)] + [("Set-Cookie", c) for c in cookies])

    def cookie(self, name):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return ""

    def set_cookie(self, name, value, max_age, samesite="Lax"):
        # SameSite=None is only honoured by browsers on Secure cookies; without https it falls back to Lax.
        if samesite == "None" and not SECURE:
            samesite = "Lax"
        return f"{name}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite={samesite}" + ("; Secure" if SECURE else "")

    def user(self):
        if AUTH == "none":
            return {"name": "dev", "role": "admin"}
        if PROXY_SECRET and hmac.compare_digest(self.headers.get("X-Cmdr-Proxy", ""), PROXY_SECRET) and self.headers.get("Remote-User"):
            role = role_for([g.strip() for g in (self.headers.get("Remote-Groups") or "").split(",") if g.strip()])
            return {"name": self.headers.get("Remote-Name") or self.headers.get("Remote-User"), "role": role} if role else None
        s = verify(self.cookie("cmdr_session"))
        return {"name": s["name"], "role": s["role"]} if s else None

    def do_GET(self):  # noqa: N802
        p = urllib.parse.urlsplit(self.path)
        path, q = p.path, urllib.parse.parse_qs(p.query)
        if path == "/healthz":
            return self.send(200, b"ok")
        if path == "/auth/login":
            return self.login(q.get("next", ["/"])[0])
        if path == "/auth/callback":
            return self.callback(q)
        if path == "/auth/logout":
            return self.redirect("/auth/signed-out", [self.set_cookie("cmdr_session", "", 0)])
        if path == "/auth/signed-out":
            return self.send(200, b"<!doctype html><meta charset=utf-8><title>Signed out</title><p>Signed out. <a href='/'>Sign in again</a>", "text/html; charset=utf-8")
        if path == "/auth/done":
            return self.static("done.html")
        u = self.user()
        if not u:
            if path.startswith("/api/"):
                return self.send(401, b'{"error":"sign in"}', "application/json")
            if path in PUBLIC_STATIC or path == "/static/done.html":
                return self.static(path.lstrip("/")[len("static/"):])
            if self.headers.get("Sec-Fetch-Dest") == "iframe":
                # The identity provider refuses to be framed, so signing in cannot happen here: ask for it in a real tab; this frame reloads when the cookie exists.
                return self.signin()
            return self.redirect("/auth/login?next=" + urllib.parse.quote(self.path if self.path.startswith("/") and not self.path.startswith("//") else "/"))
        if path == "/api/fleet":
            return self.send(200, json.dumps(fleet_view(u)).encode(), "application/json")
        if path == "/api/stats":
            try:
                return self.send(200, json.dumps(stats_history(q.get("host", [""])[0].lower())).encode(), "application/json")
            except Exception:  # noqa: BLE001
                return self.send(200, b"{}", "application/json")
        if path == "/api/me":
            return self.send(200, json.dumps(u).encode(), "application/json")
        name = "index.html" if path == "/" else path.lstrip("/")
        return self.static(name[len("static/"):] if name.startswith("static/") else name)

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        u = self.user()
        if not u:
            return self.send(401, b'{"error":"sign in"}', "application/json")
        # A custom header cannot be sent cross-site without a CORS preflight, which this server never approves: a page on another site cannot trigger this.
        if path != "/api/refresh" or self.headers.get("X-Cmdr") != "1":
            return self.send(404, b"not found")
        now = time.time()
        with LOCK:
            wait = REFRESH_MIN - (now - STATUS.get("refresh_asked", 0))
            if wait > 0:
                return self.send(429, b'{"error":"just refreshed"}', "application/json")
            STATUS["refresh_asked"] = now
        WAKE.set()
        return self.send(202, b'{"ok":true}', "application/json")

    def signin(self):
        name = html.escape(str(load_inventory().get("idp_name") or "").strip())
        with open(os.path.join(STATIC, "signin.html"), encoding="utf-8") as fh:
            page = fh.read().replace("__WITH__", f" with {name}" if name else "").replace("__WHO__", name or "Your identity provider")
        return self.send(200, page.encode(), "text/html; charset=utf-8")

    def static(self, name):
        full = os.path.normpath(os.path.join(STATIC, name))
        if not full.startswith(STATIC + os.sep) or not os.path.isfile(full):
            return self.send(404, b"not found")
        with open(full, "rb") as fh:
            return self.send(200, fh.read(), CT.get(os.path.splitext(full)[1], "application/octet-stream"))

    def login(self, nxt):
        if AUTH != "oidc":
            return self.redirect("/")
        nxt = nxt if nxt.startswith("/") and not nxt.startswith("//") else "/"
        verifier, state, nonce = secrets.token_urlsafe(48), secrets.token_urlsafe(24), secrets.token_urlsafe(16)
        try:
            ep = discovery()["authorization_endpoint"]
        except Exception as e:  # noqa: BLE001
            return self.send(502, f"identity provider unreachable: {type(e).__name__}".encode())
        challenge = b64(hashlib.sha256(verifier.encode()).digest())
        params = urllib.parse.urlencode({"response_type": "code", "client_id": CLIENT_ID, "redirect_uri": URL + "/auth/callback", "scope": "openid profile email groups",
                                         "state": state, "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256"})
        tmp = sign({"state": state, "verifier": verifier, "nonce": nonce, "next": nxt, "exp": time.time() + 600})
        self.redirect(ep + ("&" if "?" in ep else "?") + params, [self.set_cookie("cmdr_oidc", tmp, 600)])

    def callback(self, q):
        tmp = verify(self.cookie("cmdr_oidc"))
        if not tmp or q.get("state", [""])[0] != tmp["state"] or "code" not in q:
            return self.send(400, b"sign-in failed: start again from the front page")
        try:
            d = discovery()
            tok = http_json(d["token_endpoint"], {"grant_type": "authorization_code", "code": q["code"][0], "redirect_uri": URL + "/auth/callback",
                                                  "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET, "code_verifier": tmp["verifier"]})
            idt = json.loads(unb64(tok["id_token"].split(".")[1])) if tok.get("id_token") else {}
            if idt and (idt.get("nonce") != tmp["nonce"] or (CLIENT_ID not in ([idt.get("aud")] if isinstance(idt.get("aud"), str) else idt.get("aud", [])))):
                return self.send(400, b"sign-in failed: the identity token does not match this request")
            info = http_json(d["userinfo_endpoint"], headers={"Authorization": "Bearer " + tok["access_token"]})
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"event": "login_error", "error": type(e).__name__}), flush=True)
            return self.send(502, b"sign-in failed: the identity provider did not accept the request")
        groups = info.get("groups") or idt.get("groups") or []
        role = role_for(groups if isinstance(groups, list) else [groups])
        name = info.get("name") or info.get("preferred_username") or info.get("email") or info.get("sub", "?")
        print(json.dumps({"event": "login", "user": name, "role": role or "denied"}), flush=True)
        if not role:
            return self.send(403, b"<!doctype html><meta charset=utf-8><title>No access</title><p>You are signed in but not in a group that may use this page.", "text/html; charset=utf-8")
        sess = sign({"name": name, "role": role, "exp": time.time() + SESSION_TTL})
        self.redirect(tmp["next"], [self.set_cookie("cmdr_session", sess, SESSION_TTL, SAMESITE), self.set_cookie("cmdr_oidc", "", 0)])


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    if AUTH == "oidc" and not (URL and ISSUER and CLIENT_ID and CLIENT_SECRET and len(SESSION_SECRET) >= 32 and (ADMIN_GROUPS or VIEWER_GROUPS)):
        raise SystemExit("cmdr: CMDR_URL, CMDR_ISSUER, CMDR_CLIENT_ID, CMDR_CLIENT_SECRET, a CMDR_SESSION_SECRET of 32+ characters and a group are required")
    if AUTH == "none" and ENV("CMDR_ALLOW_NO_AUTH") != "1":
        raise SystemExit("cmdr: CMDR_AUTH=none is refused unless CMDR_ALLOW_NO_AUTH=1 (it would list every admin tool to anyone)")
    if AUTH not in ("oidc", "none"):
        raise SystemExit("cmdr: CMDR_AUTH must be oidc or none")
    threading.Thread(target=collector, daemon=True).start()
    port = int(ENV("PORT", "8080"))
    print(json.dumps({"event": "start", "port": port, "auth": AUTH}), flush=True)
    Server(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
