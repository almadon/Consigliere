#!/usr/bin/env python3
"""The notification relay: takes an alert from a fleet host and hands it to Home Assistant's Supernotify (decision 31).

It exists so that only one host holds a Home Assistant token. A host sends  POST /notify  (form fields title, body, tag, host) with the shared
key in X-Notify-Key. The answer is 200 only when Home Assistant accepted the call. Anything else is an error the caller can see, because there
is no second delivery path. A 200 means Home Assistant took the request, not that a phone received it. Standard library only.
"""
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 16 * 1024


def settings(env):
    s = {
        "ha_url": env.get("RELAY_HA_URL", "").rstrip("/"),
        "ha_token": env.get("RELAY_HA_TOKEN", ""),
        "key": env.get("RELAY_KEY", ""),
        "action": env.get("RELAY_ACTION", "supernotify/notify").strip("/"),
        "targets": json.loads(env.get("RELAY_TARGETS", "[]")),
        "priorities": json.loads(env.get("RELAY_PRIORITIES", '{"alert": "high", "info": "low"}')),
        "timeout": float(env.get("RELAY_HA_TIMEOUT", "15")),
    }
    missing = [k for k in ("ha_url", "ha_token", "key", "targets") if not s[k]]
    if len(s["key"]) < 24:
        missing.append("key of 24 characters or more")
    if missing:
        raise SystemExit("notify relay: missing " + ", ".join(missing))
    return s


def payload(s, title, body, tag):
    # An unknown tag is treated as an alert: too loud is a better mistake than silent.
    priority = s["priorities"].get(tag) or s["priorities"].get("alert", "high")
    # force_resend: a repeated alert is a new fact, not a duplicate to be dropped.
    return {"title": title, "message": body, "target": s["targets"], "priority": priority, "force_resend": True}


def deliver(s, data):
    """(ok, short reason). The reason never contains the token."""
    req = urllib.request.Request(f"{s['ha_url']}/api/services/{s['action']}", data=json.dumps(data).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {s['ha_token']}"})
    try:
        with urllib.request.urlopen(req, timeout=s["timeout"]) as r:
            r.read()
        return True, "accepted"
    except urllib.error.HTTPError as exc:
        return False, f"Home Assistant refused the call (HTTP {exc.code})"
    except Exception as exc:  # unreachable, timed out, TLS
        return False, f"Home Assistant could not be reached ({type(exc).__name__})"


def handler(s):
    class Handler(BaseHTTPRequestHandler):
        server_version = "fleet-notify-relay"
        timeout = 30

        def log_message(self, *args):  # the access log would repeat what the JSON line says
            pass

        def reply(self, code, text):
            out = (text + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            self.reply(200, "ok") if self.path == "/healthz" else self.reply(404, "not found")

        def do_POST(self):
            if self.path != "/notify":
                return self.reply(404, "not found")
            if not hmac.compare_digest(self.headers.get("X-Notify-Key", "").encode(), s["key"].encode()):
                return self.reply(401, "wrong or missing key")
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self.reply(411, "length required")
            if not 0 < length <= MAX_BODY:
                return self.reply(413, "empty or too large")
            form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
            title = form.get("title", [""])[0].strip()
            if not title:
                return self.reply(400, "title is required")
            body = form.get("body", [""])[0].strip() or "(no details)"
            tag = form.get("tag", ["alert"])[0]
            ok, why = deliver(s, payload(s, title, body, tag))
            print(json.dumps({"event": "notify", "host": form.get("host", ["?"])[0][:64], "tag": tag[:32], "title": title[:120], "ok": ok, "result": why}), flush=True)
            self.reply(200 if ok else 502, why)

    return Handler


def main():
    s = settings(os.environ)
    port = int(os.environ.get("PORT", "8080"))
    print(json.dumps({"event": "start", "port": port, "targets": len(s["targets"])}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), handler(s)).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
