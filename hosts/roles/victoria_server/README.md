# victoria_server

[VictoriaMetrics](https://victoriametrics.com/), the fleet's metrics store: one container, bound to this host's Tailscale address
(`http://<host>:8428`), never given a public route (it has no sign-in of its own). It takes metrics as OTLP/HTTP **protobuf**
(`/opentelemetry/v1/metrics`) or Prometheus remote write (`/api/v1/write`); Grafana (`grafana_server`) reads it over the shared Docker
network (`observability`) as a Prometheus data source, `http://victoria:8428`.

- **Retention:** `victoria_server_retention` (default 12 months). Older data is deleted.
- **Disk:** `victoria_server_data_dir`; on a host with a data disk point it under the mount (for example `/srv/bulk/victoria`).
- **Hardening:** unprivileged user, read-only root filesystem, no capabilities, memory-capped (`victoria_server_memory_limit`).
- **Senders:** the `otel_agent` role can relay OTLP metrics (`otel_agent_metrics_url`, `otel_agent_otlp_listen`); that is how Proxmox's
  built-in metric server reaches it (Proxmox may send JSON, which VictoriaMetrics rejects; the local collector converts it).
