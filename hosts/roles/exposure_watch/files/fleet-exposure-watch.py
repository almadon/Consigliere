#!/usr/bin/env python3
"""Exposure watch: compare what the internet can reach on the fleet's public addresses with what is declared.

For every target (a host's public IPs and the ports it is SUPPOSED to expose):
  1. an active TCP scan (nmap, all ports) from this host, which must be outside the target's own network;
  2. what Shodan already knows (the API with a key, else the free InternetDB).
A port that is open but not declared (or seen by Shodan but not declared) is a finding; a declared port that is closed is
reported as a warning. New findings are notified once (fleet-notify), repeated weekly while they persist, and a note is sent when
they clear. Everything is logged as JSON lines (the journal, so Loki) and kept in a state file and a last report.

  fleet-exposure-watch                run everything and notify
  fleet-exposure-watch --learn        print what is open now as YAML to paste as the declared ports; notify nothing
  fleet-exposure-watch --dry-run      run everything, print findings, notify nothing, keep no state
  fleet-exposure-watch --target NAME  only this target (repeatable)
Config: /etc/fleet-exposure-watch.json  (targets, schedule options); the Shodan key: /etc/fleet-exposure-watch.key (optional).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

CONF = os.environ.get("EXPOSURE_CONF", "/etc/fleet-exposure-watch.json")
KEYFILE = os.environ.get("EXPOSURE_KEYFILE", "/etc/fleet-exposure-watch.key")
STATE = os.environ.get("EXPOSURE_STATE", "/var/lib/fleet-exposure-watch/state.json")
REPORT = os.environ.get("EXPOSURE_REPORT", "/var/lib/fleet-exposure-watch/last-report.json")
REMIND_AFTER = 7 * 86400


def log(event, **kw):
    print(json.dumps({"event": event, **kw}, sort_keys=True), flush=True)


def is_v6(ip):
    return ":" in ip


class Unreliable(Exception):
    """A scan result that must not be trusted: nmap gave up on the host, or the target answers on a flood of ports (upstream scan protection)."""


FLOOD = 200          # more open ports than this on one address is not a service list, it is something answering for everything


def run_nmap(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=4 * 3600)
    # nmap exits 0 and reports a host with no ports when it gives up on it (<host timedout="true">): that is a failed scan, never "nothing open"
    timed_out = "due to host timeout" in p.stdout + p.stderr
    try:
        timed_out = timed_out or any(h.get("timedout") == "true" for h in ET.fromstring(p.stdout).iter("host"))
    except ET.ParseError:
        pass
    if timed_out:
        raise Unreliable("nmap gave up on the host (host timeout)")
    return p


def nmap_base(ip, cfg, rate, timeout):
    base = ["nmap", "-Pn", "-n", "--open", "-oX", "-", "--max-retries", str(cfg.get("max_retries", 2)), "--host-timeout", timeout, "--max-rate", str(rate)]
    return base + (["-6"] if is_v6(ip) else [])


def sweep(ip, cfg, rate):
    cmd = nmap_base(ip, cfg, rate, cfg.get("host_timeout", "60m")) + ["-sT" if os.geteuid() != 0 else "-sS", "-p", str(cfg.get("tcp_ports", "-")), ip]
    found = parse_nmap(run_nmap(cmd), "tcp")
    if len(found) > FLOOD:
        raise Unreliable(f"{len(found)} ports answered: something upstream is answering for the whole address (scan protection?)")
    return found


def verify(ip, cfg, ports):
    """Probe what the sweep found again, slowly, on its own: a port that only 'opened' under load is dropped."""
    if not ports:
        return set()
    cmd = nmap_base(ip, cfg, 25, "10m") + ["-sS" if os.geteuid() == 0 else "-sT", "-p", ",".join(str(p) for p in sorted(ports)), ip]
    return parse_nmap(run_nmap(cmd), "tcp")


def scan(ip, cfg, target=None):
    """Open TCP ports (and UDP from the list, if any) according to nmap; raises RuntimeError when no trustworthy answer could be had."""
    if shutil.which("nmap") is None:
        raise RuntimeError("nmap is not installed")
    rate = int((target or {}).get("max_rate", cfg.get("max_rate", 300)))
    last = ""
    tcp = None
    for r in (rate, max(20, rate // 5)):                 # one retry, five times slower
        try:
            tcp = verify(ip, cfg, sweep(ip, cfg, r))
            break
        except Unreliable as e:
            last = str(e)
            log("scan_retry", ip=ip, rate=r, reason=last)
    if tcp is None:
        raise RuntimeError(f"scan unreliable ({last}); set a lower max_rate for this target, or rely on Shodan for it")
    ports = {"tcp": tcp, "udp": set()}
    if cfg.get("udp_ports"):
        cmd = nmap_base(ip, cfg, rate, "20m") + ["-sU", "-p", ",".join(str(p) for p in cfg["udp_ports"]), ip]
        ports["udp"] |= parse_nmap(run_nmap(cmd), "udp")
    return ports


def parse_nmap(proc, proto):
    if proc.returncode != 0 and not proc.stdout.strip().startswith("<?xml"):
        raise RuntimeError("nmap failed: " + proc.stderr.strip()[:200])
    root = ET.fromstring(proc.stdout)
    found = set()
    for p in root.iter("port"):
        st = p.find("state")
        if p.get("protocol") == proto and st is not None and st.get("state") in ("open", "open|filtered") and \
                (proto == "tcp" or st.get("state") == "open"):
            found.add(int(p.get("portid")))
    return found


def shodan(ip, key):
    """Ports Shodan has indexed for this address, from the API (key) or InternetDB (none). Returns (ports, extra) or None on failure."""
    url = f"https://api.shodan.io/shodan/host/{ip}?key={key}" if key else f"https://internetdb.shodan.io/{ip}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "fleet-exposure-watch"}), timeout=30) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:           # nothing indexed for this address
            return set(), {"source": "shodan-api" if key else "internetdb", "note": "not indexed"}
        log("shodan_error", ip=ip, status=e.code)
        return None
    except Exception as e:  # noqa: BLE001 - the network is allowed to fail; the scan is the authority
        log("shodan_error", ip=ip, error=type(e).__name__)
        return None
    return set(int(p) for p in d.get("ports", [])), {"source": "shodan-api" if key else "internetdb", "vulns": sorted(d.get("vulns", []))[:20],
                                                      "last_update": d.get("last_update", "")}


def load_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
    os.replace(tmp, path)


def evaluate(target, ip, scanned, shod):
    """The findings for one address. Pure: no I/O, so it can be tested."""
    exp_tcp, exp_udp = set(target.get("tcp", [])), set(target.get("udp", []))
    out = []
    for p in sorted(scanned["tcp"] - exp_tcp):
        out.append({"kind": "unexpected-open", "proto": "tcp", "port": p, "severity": "alert", "source": "scan"})
    for p in sorted(scanned["udp"] - exp_udp):
        out.append({"kind": "unexpected-open", "proto": "udp", "port": p, "severity": "alert", "source": "scan"})
    for p in sorted(exp_tcp - scanned["tcp"]):
        out.append({"kind": "expected-closed", "proto": "tcp", "port": p, "severity": "warn", "source": "scan"})
    if shod is not None:
        for p in sorted(shod[0] - exp_tcp - exp_udp - scanned["tcp"] - scanned["udp"]):
            out.append({"kind": "shodan-only", "proto": "?", "port": p, "severity": "info", "source": shod[1].get("source", "shodan"),
                        "note": "Shodan lists it, the scan did not see it (closed since, or filtered from this vantage)"})
        for v in shod[1].get("vulns", []):
            out.append({"kind": "shodan-vuln", "proto": "", "port": 0, "severity": "alert", "source": shod[1].get("source", "shodan"), "note": v})
    return out


def notify(title, body):
    exe = shutil.which("fleet-notify")
    if not exe:
        log("notify_unavailable", title=title)
        return
    subprocess.run([exe, title, body], timeout=60, check=False)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--learn", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--target", action="append", default=[])
    a = ap.parse_args(argv)
    cfg = load_json(CONF, None)
    if not cfg or not cfg.get("targets"):
        print(f"no targets in {CONF}", file=sys.stderr)
        return 2
    key = ""
    try:
        key = open(KEYFILE).read().strip()
    except OSError:
        pass
    targets = [t for t in cfg["targets"] if not a.target or t["name"] in a.target]
    state = {} if a.dry_run or a.learn else load_json(STATE, {})
    now = int(time.time())
    seen_ids, report, learn, failed = set(), {"time": now, "targets": {}}, {}, 0
    for t in targets:
        for ip in t.get("ips", []):
            try:
                scanned = scan(ip, cfg, t)
            except Exception as e:  # noqa: BLE001
                log("scan_failed", target=t["name"], ip=ip, error=str(e)[:200])
                failed += 1
                fid = f"{t['name']}|{ip}|scan-failed"
                seen_ids.add(fid)
                rec = state.get(fid)
                if not a.dry_run and not a.learn and (rec is None or now - rec["last_alert"] > REMIND_AFTER):
                    notify(f"Exposure scan could not be trusted: {t['name']} {ip}", str(e)[:300])
                    state[fid] = {"first_seen": now if rec is None else rec["first_seen"], "last_alert": now, "target": t["name"], "ip": ip,
                                  "finding": {"kind": "scan-failed", "proto": "", "port": 0, "severity": "warn"}}
                continue
            if a.learn:
                learn.setdefault(t["name"], {"ips": [], "tcp": set(), "udp": set()})
                learn[t["name"]]["ips"].append(ip)
                learn[t["name"]]["tcp"] |= scanned["tcp"]
                learn[t["name"]]["udp"] |= scanned["udp"]
                continue
            shod = shodan(ip, key) if cfg.get("shodan", True) else None
            findings = evaluate(t, ip, scanned, shod)
            report["targets"].setdefault(t["name"], {})[ip] = {"open_tcp": sorted(scanned["tcp"]), "open_udp": sorted(scanned["udp"]),
                                                               "findings": findings}
            log("scanned", target=t["name"], ip=ip, open_tcp=sorted(scanned["tcp"]), open_udp=sorted(scanned["udp"]), findings=len(findings),
                finding_list=[{"kind": f["kind"], "proto": f["proto"], "port": f["port"], "severity": f["severity"], "note": f.get("note", "")} for f in findings])
            for f in findings:
                fid = f"{t['name']}|{ip}|{f['kind']}|{f['proto']}|{f['port']}|{f.get('note', '')}"
                seen_ids.add(fid)
                rec = state.get(fid)
                new = rec is None
                if new:
                    state[fid] = {"first_seen": now, "last_alert": 0, "finding": f, "target": t["name"], "ip": ip}
                    rec = state[fid]
                log("finding", target=t["name"], ip=ip, new=new, **f)
                if f["severity"] in ("alert", "warn") and (new or now - rec["last_alert"] > REMIND_AFTER) and not a.dry_run:
                    what = f"{f['kind']} {f['proto']}/{f['port']}" if f["port"] else f"{f['kind']} {f.get('note', '')}"
                    notify(f"Exposure: {t['name']} {ip}", f"{what} ({'new' if new else 'still open after a week'}); declared ports tcp={t.get('tcp', [])}")
                    rec["last_alert"] = now
    if a.learn:
        print("# Open now (review: anything here you did not mean to expose is a finding, not a baseline)")
        for name, d in learn.items():
            print(f"- name: {name}\n  ips: {json.dumps(d['ips'])}\n  tcp: {sorted(d['tcp'])}" + (f"\n  udp: {sorted(d['udp'])}" if d["udp"] else ""))
        return 1 if failed else 0
    scanned_names = {t["name"] for t in targets}
    if not a.dry_run:
        for fid in [k for k in state if k not in seen_ids and state[k]["target"] in scanned_names]:
            f = state.pop(fid)
            if f["finding"]["severity"] in ("alert", "warn") and f["last_alert"]:
                notify(f"Exposure cleared: {f['target']} {f['ip']}", f"{f['finding']['kind']} {f['finding']['proto']}/{f['finding']['port']} is no longer reported")
                log("cleared", target=f["target"], ip=f["ip"], kind=f["finding"]["kind"], port=f["finding"]["port"])
        save_json(STATE, state)
        save_json(REPORT, report)
    n_alert = sum(1 for t in report["targets"].values() for r in t.values() for f in r["findings"] if f["severity"] == "alert")
    log("summary", targets=len(targets), alerts=n_alert, scan_failures=failed)
    if a.dry_run:
        for name, ips in report["targets"].items():
            for ip, r in ips.items():
                for f in r["findings"]:
                    print(f"{name:12} {ip:40} {f['severity']:5} {f['kind']} {f['proto']}/{f['port']} {f.get('note', '')}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
