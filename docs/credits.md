# Credits

What this project adopts, under which licence, and what it passed over. A licence marked VERIFY has not been checked at the pinned version; check it before distributing anything built on this.

| Component | Used for | Licence |
|---|---|---|
| Ansible | Configuration engine | GPL-3.0, VERIFY |
| Tailscale client | Network | BSD-3-Clause, VERIFY |
| sops, age | Secrets | MPL-2.0, BSD-3-Clause, VERIFY |
| Docker CE | Container engine | Apache-2.0, VERIFY |
| Traefik | Edge proxy | MIT, VERIFY |
| Cert Warden | ACME client | Stated in the README as non-commercial; VERIFY the exact terms |
| OpenTelemetry Collector (contrib) | Log and metric shipping | Apache-2.0, VERIFY |
| Loki, Grafana | Logs, dashboards | AGPL-3.0, VERIFY |
| VictoriaMetrics | Metrics | Apache-2.0, VERIFY |
| Arkeep | Backups | VERIFY |
| restic, rest-server | Backups | BSD-2-Clause, VERIFY |
| Arcane | Compose GitOps | VERIFY |
| Garage | S3 object store | AGPL-3.0, VERIFY |
| Muximux, Homarr, Beszel | Console, dashboard, host monitoring | VERIFY |
| Wazuh | Security monitoring | VERIFY |
| Apprise | Notifications | BSD-2-Clause, VERIFY |
| Pocket ID | Sign-in (used by the fleet, not deployed by this repo) | VERIFY |

World map outlines in Cmdr come from Natural Earth (public domain), via the `world-atlas` package.

**Passed over:** Zerobyte for backups (Arkeep chosen, 2026-10-01); Watchtower-style blind image updates for stacks (pin or exclude instead); a hand-rolled restic timer (retired once Arkeep's agent took over).
