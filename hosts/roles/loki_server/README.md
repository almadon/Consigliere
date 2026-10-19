# loki_server

[Loki](https://grafana.com/oss/loki/), the fleet's log store: one container, filesystem storage, bound to this host's Tailscale
address (`http://<host>:3100`), never given a public route (it has no sign-in of its own). Hosts send logs with OpenTelemetry
(`http://<host>:3100/otlp`, native OTLP) or any Loki client; Grafana (`grafana_server`) reads it over the shared Docker network
(`observability`, as `http://loki:3100`).

- **Retention:** `loki_server_retention_days` (default 90). The compactor deletes older logs.
- **Disk:** the log chunks and the uploaded index are the bulk and go in `loki_server_data_dir`; on a host with a dedicated data
  disk (see the `data_disk` role) set it under the mount, for example `/srv/bulk/loki`, so the root disk cannot fill up. The
  write-ahead log, the live index and caches stay in `/opt/loki/state` (small). Loki's filesystem store has no automatic
  hot-to-cold tiering by age: everything older than the WAL is already on the data disk.
- **Memory:** the container is capped at `loki_server_memory_limit` (default 1536m).
- **Ownership:** the image runs as uid 10001; the role gives that user the state and data directories.
- OpenTelemetry resource attributes arrive as structured metadata (`allow_structured_metadata: true`); the `service.name`
  attribute becomes the `service_name` label.

Tested against Loki 3.7.8: check, apply, check, apply (the last two change nothing); an OTLP log line pushed to `/otlp/v1/logs`
and read back with a query.
