# exposure_watch

Checks, on a schedule, what the internet can reach on the fleet's public addresses, against what the fleet **declares**. Run it on a host outside the
networks it scans (tag `util: [exposure]`; it skips any target named like itself, so give another host the same tag to cover this one).

For each target in `exposure_watch_targets` (`{name, ips, tcp, udp}`):

1. **Active scan** of every address, all 65535 TCP ports (and any listed UDP ports) with `nmap`, at a low rate. This is the authority: it is immediate.
2. **Shodan**: the API with the key in the secret `shodan.api` (`exposure_watch_shodan_key`), else the free InternetDB. It shows what the internet
   has already indexed, including known vulnerabilities; it lags by days and can miss things, so it is an independent second view.

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
Tested against containers (an undeclared listener, a closed declared port, repeat and clear notifications) and the InternetDB lookup; not yet on the fleet.
