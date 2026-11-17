# otel_agent

- **Does:** ships the host's logs (the systemd journal, or the system log file where there is no journal; Docker container logs) and, optionally, metrics to Loki and VictoriaMetrics, as a systemd service where there is apt and systemd and as a container everywhere else.
- **Owns settings:** this repo: the `otel_agent_*` defaults and the fleet's overrides.
- **Keeps state:** read offsets and the send queue, so nothing is lost across restarts: `/var/lib/otelcol-contrib/storage` (container mode: `<common_dir>/otel-agent/storage`).
- **Rolls back by:** `safe_apply`: the collector validates a new configuration first, the running files are kept as `.last-good`, and a change that does not leave it healthy is undone and fails the run.
- **Exposes:** nothing inbound by default; optional listeners on the addresses you give (`otel_agent_otlp_listen`, `otel_agent_syslog_listeners`), and the read-only Docker proxy on `127.0.0.1` for container metrics.

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
- **Per-container metrics (optional, `otel_agent_docker_stats: true`, needs `otel_agent_metrics_url`):** CPU, memory, network, block I/O, restarts and uptime of every container, every
  `otel_agent_docker_stats_interval` (30s), labelled `host.name`, `container.name`, `container.image.name` and the Compose project and service. The collector does **not** get Docker's socket: the role runs a
  read-only [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) (containers, events and ping; no writes) bound to `127.0.0.1:2375`. The fleet's "Containers" Grafana dashboard reads these.
- **Syslog relay (optional, `otel_agent_syslog_listeners`):** the same collector can also receive syslog from devices that cannot run it (Unraid,
  UniFi access points and switches, other network gear) and forward it to Loki. Each message is stored under the sender's own name
  (`host_name`, lower-cased from the syslog header) and program (`unit`), with the severity taken from the syslog priority and the listener's
  name in `syslog_listener`. Listeners are `tcp` or `udp`, `rfc3164` (classic BSD syslog, what Unraid and most gear send) or `rfc5424`, on an
  unprivileged port. Bind them to the senders' network (a LAN address, not a public one) and open the port to that network only
  (`firewall_extra_rules` on the host). Prefer tcp where the sender allows it, since udp drops lines. rfc3164 timestamps carry no time zone:
  set `otel_agent_syslog_timezone` to the zone the senders use, or lines land hours off. A line the listener cannot read (a sender using the other protocol, garbage) is still delivered, as `host_name="unknown"` with its raw text, so a protocol mismatch shows up instead of vanishing. Tested with TCP and UDP messages into a real Loki.
- **Failsafes:** the configuration and the service's limits are applied through [safe_apply](../safe_apply/README.md): the collector validates the file before it replaces the live one, the running files are kept as `.last-good`, and if the collector is not healthy afterwards the old ones are put back and the run fails with the reason (and an alert when `fleet-notify` is installed). The rendered configuration is checked by the collector itself (`otelcol-contrib validate`, which parses every OTTL
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
- Where the collector runs (`otel_agent_mode`: `auto`, `native` or `container`): `auto` is native on a host with apt and systemd and a container on everything else (Alpine, Unraid, anything a container reconciler runs on). See below.

## Container mode

For hosts without apt and systemd the collector runs from the `otel/opentelemetry-collector-contrib` image (the same `otel_agent_version`), under Docker, and reads the host through mounts. It needs only the `docker` capability, so it runs under the container reconciler as the other container roles do.

| What | How |
|---|---|
| System log | There is no journal, so the collector follows the system log file as plain syslog lines: `/var/log/messages` on Alpine (BusyBox's syslogd) and `/var/log/syslog` on Unraid, from the platform profile; `otel_agent_system_log_files` reads others and `otel_agent_system_log: false` turns it off. The program becomes the label `unit`, the rest the line. The time is when the line was read (the file is followed live). A line it cannot read is still delivered, as it is. |
| Docker logs | `/var/lib/docker/containers` mounted read-only; the same labels as the native service. |
| Host metrics | Off by default. With `otel_agent_hostmetrics: true` the host's root is mounted read-only at `otel_agent_hostfs` (`/hostfs`) and the collector's `root_path` points there. It is the widest thing the container is given. |
| Container metrics | The same read-only Docker proxy as the native service. |
| Privileges | Root inside the container (to read root-owned logs) with every capability dropped except `DAC_READ_SEARCH`, a read-only root filesystem, no new privileges, host networking (so `127.0.0.1` is the host), a memory limit of `otel_agent_memory_max` (tried first and left out, with a note in the run, on a host whose Docker cannot set one, such as an LXC without the memory controller; `otel_agent_memory_max: ""` means none). |
| Its own logs | `docker logs otel-agent` works; the container uses Docker's `local` log driver, so the collector neither ships nor follows itself. |
| Applying a change | Through `safe_apply` (kind `compose`): the new configuration is validated by running the collector image's own `validate` on it, passed in by value, because the reconciler's temporary file is not a path the host's Docker can mount. A configuration the collector rejects stops the run and the running container keeps the good configuration. |

Every run makes sure the collector is up (`docker compose up`, which changes nothing when it already is) and fails with Docker's reason when it cannot start, so a failed first install is not reported as converged on the next run.

Not handled: switching a host between native and container (remove the old one first). First real hosts (an Alpine LXC and an Unraid server) failed to start it: an explicit `rslave` mount of `/` is refused where the root is not a shared mount (Unraid), and the memory limit cannot be set in an LXC. Both are fixed (the mount names no mode, as the Arkeep agent's does; the limit is probed). the container mode is tested against the collector image with a sink (logs from a syslog file in three line styles, container logs and host metrics arrive with the right labels) and in `ci/otel-container.sh` (the role applied from an Alpine container driving the host's Docker: it comes up, stays up with a dead Loki address, a second run changes nothing, a bad configuration is refused). The collector logs a deprecation notice that the `hostmetrics` receiver is being renamed `host_metrics`; it applies to the native service too and is left as it is until the pinned version changes.

Tested on a clean Debian 13 machine against Loki 3.7.8 with Docker and a running container: check, apply, check, apply (the last two
change nothing); journal lines written after start and container lines arrived with the right labels.
