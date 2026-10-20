# Platforms and architectures

| Host | Support |
|---|---|
| Debian 12/13 and Ubuntu, **x86_64** and **aarch64 (ARM64)** | Full: `bootstrap.sh` + the systemd timer (VPS, LXC, VM, bare metal, Oracle Ampere A1) |
| Unraid (7.x) | A self-scheduling container (`hosts/bootstrap/unraid/`); only container-based roles run there |
| macOS | launchd agent (`macos/`) |

## ARM64

Everything the roles install is multi-architecture, checked against the registries when the Oracle Ampere VPS was prepared:

| Component | amd64 | arm64 |
|---|---|---|
| sops (pinned binary + checksum in `install-sops.sh`), Docker's apt repo, Tailscale's apt repo | yes | yes |
| OpenTelemetry Collector `.deb` (`otel_agent`) | yes | yes (selected from `ansible_architecture`) |
| Arkeep agent, Beszel agent, Arcane agent, restic REST server, Muximux, Garage + web UI, Loki, Traefik, nginx | yes | yes |
| Mailflow (`mailflow-frontend`, `mailflow-backend`), PostgreSQL 16, Redis 7 | yes | yes |

Re-check an image before you add it: `docker manifest inspect <image:tag> | grep architecture`; a single-architecture image will not run on an ARM host.
When a role downloads a binary itself it must choose by `ansible_architecture` (`x86_64` / `aarch64`) and verify a checksum, as `install-sops.sh` and
`otel_agent` do.
