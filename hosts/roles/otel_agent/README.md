# otel_agent

The [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) (contrib build, from the project's `.deb`, version pinned in
`otel_agent_version`, download verified against the release's `.sha256`) as a systemd service. It ships this host's logs to
[Loki](../loki_server/README.md)'s native OTLP endpoint (`otel_agent_loki_url`, for example `http://lk.ctrl.a64.one:3100/otlp`):

- **The systemd journal** (`journald` receiver; entries at `otel_agent_journal_priority` or more severe, default `info`). The message
  is the line, the unit (or syslog identifier) is the label `unit`.
- **Docker container logs** (json-file driver; `otel_agent_docker_logs: auto` = when Docker is installed). One catch-all file reader
  derives the container id from the path; the label `container_name` comes from a table the role writes from `docker ps -a` at each
  reconcile. A container newer than the table is labelled `c-<short id>` until the next run (at most about 20 minutes).

Every line carries `host_name` (`otel_agent_host_name`, the fleet's short name). These labels are indexed by Loki (see
`loki_server_index_*`); everything else (`log_iostream`, the journal's other fields) is structured metadata you can filter on.

- **Runs as an unprivileged user** (`otelcol-contrib`), in group `systemd-journal`. Reading Docker's root-owned logs uses only
  `CAP_DAC_READ_SEARCH` (read, never write); with Docker logs off the service has no capabilities at all. The unit is sandboxed
  (`ProtectSystem=strict`, `NoNewPrivileges`, state only in `/var/lib/otelcol-contrib`).
- **Limits:** a soft memory limit (`otel_agent_memory_limit_mib`, 128) in the collector, `GOMEMLIMIT`, and `MemoryMax` (256M). Measured on
  the fleet's nine hosts: 67-94 MB of heap per agent (`RssAnon`; the cgroup shows 68-173 MiB including evictable file cache). `ps` reports 240-265 MB
  resident because it also counts the shared file pages of the large executable; those are reclaimable and not extra pressure. Startup spikes higher for a moment. The installed binary is large (~370 MB on disk).
- **Syslog relay (optional, `otel_agent_syslog_listeners`):** the same collector can also receive syslog from devices that cannot run it (Unraid,
  UniFi access points and switches, other network gear) and forward it to Loki. Each message is stored under the sender's own name
  (`host_name`, lower-cased from the syslog header) and program (`unit`), with the severity taken from the syslog priority and the listener's
  name in `syslog_listener`. Listeners are `tcp` or `udp`, `rfc3164` (classic BSD syslog, what Unraid and most gear send) or `rfc5424`, on an
  unprivileged port. Bind them to the senders' network (a LAN address, not a public one) and open the port to that network only
  (`firewall_extra_rules` on the host). Prefer tcp where the sender allows it, since udp drops lines. rfc3164 timestamps carry no time zone:
  set `otel_agent_syslog_timezone` to the zone the senders use, or lines land hours off. A line the listener cannot read (a sender using the other protocol, garbage) is still delivered, as `host_name="unknown"` with its raw text, so a protocol mismatch shows up instead of vanishing. Tested with TCP and UDP messages into a real Loki.
- **Failsafes:** the rendered configuration is checked by the collector itself (`otelcol-contrib validate`, which parses every OTTL
  statement) before it replaces the live file, so a mistake stops that host's run with the reason and the working configuration stays.
  After any change the role waits a few seconds and fails, with the service's last journal lines, if the collector is not running
  steadily. Transient unit names (`session-123.scope`, container scopes, `run-*`) are folded into a few stable `unit` values so
  Loki's stream count stays bounded.
- **No data lost across restarts:** read offsets and the send queue are kept on disk (`file_storage`); if Loki is unreachable the agent
  queues and retries.
- **Metrics relay (optional, `otel_agent_metrics_url` + `otel_agent_otlp_listen`):** the collector also receives OTLP/HTTP metrics from software on
  the host (Proxmox's built-in metric server, pointed at `127.0.0.1:4318`, path `/v1/metrics`) and forwards them to
  [VictoriaMetrics](../victoria_server/README.md) as protobuf, with the same on-disk queue. Proxmox may send JSON, which VictoriaMetrics rejects;
  the collector accepts both. Host metrics and Docker stats are not collected (Beszel does that).
- **Host metrics (optional, `otel_agent_hostmetrics`):** the collector scrapes this host's CPU, memory, root-and-data filesystem use and load every minute
  (`otel_agent_hostmetrics_interval`) and sends them to `otel_agent_metrics_url`; cmdr shows them on the host cards. Container, tmpfs and pseudo filesystems are left out.
- No secret is needed: Loki and VictoriaMetrics take data only from the tailnet.
- Unraid hosts are not supported by this role (no systemd, no apt).

Tested on a clean Debian 13 machine against Loki 3.7.8 with Docker and a running container: check, apply, check, apply (the last two
change nothing); journal lines written after start and container lines arrived with the right labels.
