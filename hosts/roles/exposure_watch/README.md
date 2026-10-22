# exposure_watch

Checks, on a schedule, what the internet can reach on the fleet's public addresses, against what the fleet **declares**. Run it on a host outside the
networks it scans (tag `util: [exposure]`; it skips any target named like itself, so give another host the same tag to cover this one).

For each target in `exposure_watch_targets` (`{name, ips, tcp, udp}`):

1. **Active scan** of every address, all 65535 TCP ports (and any listed UDP ports) with `nmap`, at a low rate. This is the authority: it is immediate.
2. **Shodan**: the API with the key in the secret `shodan.api` (`exposure_watch_shodan_key`), else the free InternetDB. It shows what the internet
   has already indexed, including known vulnerabilities; it lags by days and can miss things, so it is an independent second view.

**A result is only trusted when it can be.** nmap exits successfully with an empty result when it gives up on a host, and some providers answer every SYN once a
scan is fast enough (SYN-proxy "scan protection"), which looks like thousands of open ports. The scanner detects both (`<host timedout="true">`, and more
than 200 ports open on one address), retries five times slower, re-probes whatever it found one port at a time at 25 packets per second (a port that only
"opened" under load is dropped), and if there is still no trustworthy answer it reports `scan unreliable` (notified once a week while it persists) and never
"nothing open". A target may set its own `max_rate`, `tcp_ports` and `host_timeout`: a provider that throttles scans (Empros's answers every SYN once a sweep is fast, and drops replies at any rate) gets `tcp_ports: top1000` and a low rate, and Shodan covers the long tail.

Findings: an open port that is not declared (`alert`), a known vulnerability on an address (`alert`), a declared port that is closed (`warn`), a port
Shodan lists that the scan did not see (`info`). New alerts and warnings are sent once through `fleet-notify` (Pushover/Apprise), repeated weekly while
they persist, and a note is sent when they clear. Every scan and finding is a JSON line in the journal (so Loki); the last result is
`/var/lib/fleet-exposure-watch/last-report.json`.

```
fleet-exposure-watch --learn        # print what is open now as YAML (review it: unexpected ports are findings, not a baseline)
fleet-exposure-watch --dry-run      # run everything, print findings, notify nothing
fleet-exposure-watch --target NAME  # one target
```

Scanning your own addresses is normal, but keep the rate low and scan from a host you control; some providers ask to be told about regular scans.
Tested against containers (an undeclared listener, a closed declared port, repeat and clear notifications, a rate-triggered flood, a permanent flood) and with nmap's real timed-out XML; the InternetDB and Shodan API lookups work.
