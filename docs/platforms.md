# Platforms and architectures

| Host | Support |
|---|---|
| Debian 13, Debian 12 and **Ubuntu 24.04 or newer**, **x86_64** and **aarch64 (ARM64)** | Full: `bootstrap.sh` + the systemd timer (VPS, LXC, VM, bare metal, Oracle Ampere A1). Tested on Debian 13 (x86_64) and Ubuntu 24.04 (ARM64); Debian 12 takes the same path as Ubuntu below but has not been run |
| Ubuntu 22.04 and older | Not supported: ansible-core 2.19 needs Python 3.11 or newer, and `install-ansible.sh` stops with that message |
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

## Ansible on the host

The roles are written and tested against the "ansible" 12 bundle (ansible-core 2.19 with its collections), which is what Debian 13 ships. `bootstrap.sh` runs
`hosts/bootstrap/install-ansible.sh` after cloning the framework: if the host already has core 2.19 or newer it does nothing; if the distribution package is new
enough it installs that; otherwise (Ubuntu 24.04 packages core 2.16, which lacks `meta: end_role`) it installs the pinned bundle into a virtualenv at
`/opt/fleet-ansible` (system packages visible, so the apt module finds `python3-apt`) and links `ansible`, `ansible-playbook` and friends into `/usr/local/bin`,
which comes first on the reconcile service's PATH. `ANSIBLE_BUNDLE_VERSION` (default 12.0.0) picks the release. Collection versions then match the Debian 13 fleet.

## Applying sshd settings

The baseline role handler applies sshd changes with `systemctl restart ssh` when `ssh.socket` (socket activation) is active, and `reload` otherwise (restart as the fallback), and always ends by
making sure sshd is running. A plain reload is unsafe under socket activation: OpenSSH 10 re-executes itself on `SIGHUP`, cannot bind port 22 because systemd's socket holds it
(`fatal: Cannot bind any address`), and exits, leaving the service stopped until the next connection starts it. Existing sessions survive the restart (`KillMode=process`).

## Firewall rules preinstalled by cloud images

Some images (Oracle Cloud's Ubuntu among them) save firewall rules for `netfilter-persistent`: allow SSH, then `REJECT` everything else in `INPUT` and `FORWARD`. Those sit in front of
ufw's chains, so ufw's allows for host services (the tailnet interface, a syslog listener) never take effect, and SSH stays open to the world. The `firewall` role detects such a saved
`REJECT` in `/etc/iptables/rules.v4|v6`, removes exactly those rules from the running firewall once ufw is active, copies the files to `/var/backups/consigliere/*.from-image`, and masks
`netfilter-persistent` so they do not return at boot (it never stops that service, because stopping it would flush every rule). Docker-published ports were never affected by those rules
(they pass through `FORWARD` ahead of the `REJECT`); the docker guard controls them as usual. Set `firewall_remove_image_rules: false` to leave the image's rules alone.
The cloud provider's own network firewall (Oracle's security lists) is separate and is not touched.
