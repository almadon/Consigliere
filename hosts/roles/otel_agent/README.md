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
- **Failsafes:** the rendered configuration is checked by the collector itself (`otelcol-contrib validate`, which parses every OTTL
  statement) before it replaces the live file, so a mistake stops that host's run with the reason and the working configuration stays.
  After any change the role waits a few seconds and fails, with the service's last journal lines, if the collector is not running
  steadily. Transient unit names (`session-123.scope`, container scopes, `run-*`) are folded into a few stable `unit` values so
  Loki's stream count stays bounded.
- **No data lost across restarts:** read offsets and the send queue are kept on disk (`file_storage`); if Loki is unreachable the agent
  queues and retries.
- No secret is needed: Loki takes logs only from the tailnet. Metrics (host metrics, Docker stats) are not sent yet, because there is no
  metrics store.
- Unraid hosts are not supported by this role (no systemd, no apt).

Tested on a clean Debian 13 machine against Loki 3.7.8 with Docker and a running container: check, apply, check, apply (the last two
change nothing); journal lines written after start and container lines arrived with the right labels.
