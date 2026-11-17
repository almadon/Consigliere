# Platforms and architectures

| Host | Support |
|---|---|
| Debian 13, Debian 12 and **Ubuntu 24.04 or newer**, **x86_64** and **aarch64 (ARM64)** | Full: `bootstrap.sh` + the systemd timer (VPS, LXC, VM, bare metal, Oracle Ampere A1). Tested on Debian 13 (x86_64) and Ubuntu 24.04 (ARM64); Debian 12 takes the same path as Ubuntu below but has not been run |
| Ubuntu 22.04 and older | Not supported: ansible-core 2.19 needs Python 3.11 or newer, and `install-ansible.sh` stops with that message |
| Alpine (LXC or VM) | Docker and Tailscale from `apk`, then the same self-scheduling container as Unraid (`hosts/bootstrap/alpine/`); only container-based roles run there. The roles themselves also run on an Alpine host with OpenRC in the CI matrix; a bootstrap that reconciles an Alpine host natively is not built |
| Unraid (7.x) | A self-scheduling container (`hosts/bootstrap/unraid/`); only container-based roles run there |
| macOS | A launchd agent running its own small playbook (`macos/`); not on the platform layer yet (see below) |
| Windows 11 (amd64) | A pull-only PowerShell reconciler (`windows/`), experimental, run on one VM: [windows-host.md](windows-host.md) |

## The platform layer

What kind of machine a host is gets decided once, in one place, and roles read the answer ([decision 19](decisions.md)). The `platform` role runs at the start of `fleet_plan` and sets:

| Fact | Values |
|---|---|
| `platform_family` | `debian` (also Ubuntu), `alpine`, `unraid`, `macos`, `unknown`: a profile file in `hosts/platforms/` |
| `platform_arch` | `amd64`, `arm64`, `armv7`, or the raw value: one spelling, whatever the OS calls it |
| `platform_runtime_mode` | `host` (Ansible changes the machine) or `container` (Ansible runs in a container on the Docker socket: Unraid, Alpine) |
| `platform_capabilities` | what a role can count on: `host`, `apt`, `apk`, `systemd`, `openrc`, `launchd`, `docker`, `ufw` |
| `platform_defaults` | the profile's defaults: package manager, init system, SSH service name |

A role that cannot work everywhere says so in `hosts/roles/<role>/platform.yml` (`requires: [host, apt, systemd]`). When a tag selects it on a platform that lacks one of those,
`fleet_plan` skips it and logs which capability is missing, instead of failing in the middle of the role. A role with no `platform.yml` runs wherever a tag selects it, as
before. Inside a container the Ansible facts describe the container, not the machine, so the container playbook states `platform_host` (and the Alpine bootstrap writes it into `vars.yml`).

The host table can say what a host is: `os:` (`debian`, `ubuntu`, `alpine`, `unraid`, `macos`, `windows`) and `arch:` (`amd64`, `arm64`). Both are optional for a host that runs Ansible itself, which
works them out from its facts and logs a line if the table disagrees. A container-reconciled host needs `os:`: its facts describe the container, and the fleet's scripts (`reconcile-now`, `fleet-run`) use
it to pick how to reconcile the host. `os:` and `arch:` also become groups (`os_alpine`, `arch_amd64`), like the other table values.

Releases and tool versions are part of it too: `platform_version` holds the distribution's release, a profile can override itself by release (`versions:`), and a role can require a tool version
(`requires_version: {apt: ">=2.4"}` in its `platform.yml`). `baseline_apt_retries: auto` is the first use: the apt retries stopgap applies only where the installed apt is in a vulnerable range.
See `hosts/platforms/README.md`.

Roles install packages, add vendor repositories, manage services, run jobs on a schedule and at boot, and install pinned release downloads through the platform role's `package`, `repo`, `service`, `schedule`, `boot_task` and `artifact` tasks, so the same role runs on Debian, Ubuntu and Alpine, and `ci/run-matrix.sh`
checks that in containers (see `hosts/platforms/README.md`).

### What the platform layer covers, and what it does not

The layer is for hosts that run the framework's Ansible code, so it covers every Linux-like host and any other family that gets a profile. Where each platform stands:

| Platform | Runs through | Package | Service | Schedule | Boot task | Download |
|---|---|---|---|---|---|---|
| Debian, Ubuntu | `hosts/site.yml`, host run | apt | systemd | systemd timer | systemd unit | `artifact` |
| Alpine (host run, CI matrix) | `hosts/site.yml`, host run | apk | OpenRC | cron | `local.d` | `artifact` |
| Alpine, Unraid (container reconciler) | `hosts/site.yml` with `RECONCILE_RUNTIME=container`: only roles that need just `docker` run | none (the host is out of reach) | none | none | none | none |
| macOS | `macos/site.yml`, its own playbook and launchd agent; **not on the layer** | Homebrew modules called directly | launchd, by the agent | not done | not done | not done |
| Windows | `windows/`, a PowerShell reconciler; **Ansible does not run there** | its own installers, pinned by digest | its own role code | its own Scheduled Task | its own role code | inline in `bootstrap.ps1` |

**macOS** has its own playbook and one role that calls Homebrew modules directly. Bringing it onto the layer means implementing the same tasks for Homebrew and launchd (a package task over `brew`, a service task over `launchctl`, a schedule as a `StartCalendarInterval` job, a boot task as `RunAtLoad`), running the `platform` role and `fleet_plan` from `macos/site.yml`, and testing on a Mac. None of that is done; the `macos` profile only names the family.

**Windows** is not Ansible, so the layer's tasks cannot apply. It shares what is not code: the host table (with `os: windows` and `arch:`), the variable merge order, the tag manifests, sops and age for secrets, check-then-apply, and a role contract (a role returns what changed, honours a check pass and throws on failure). A Windows counterpart of the primitives would be PowerShell helpers for pinned installs, services and scheduled tasks; the bootstrap has these inline today and they are not abstracted.

What is the same everywhere is the model: each host reconciles itself on a timer from the two repositories, and a role says what it needs before it runs.

To support a new platform: add `hosts/platforms/<family>.yml`, then give the roles that are host-bound a `platform.yml`. Declarations are written by hand, because a role that mentions apt or
systemd only conditionally may still work on a platform without them.

## ARM64

Everything the roles install is multi-architecture, checked against the registries when the Oracle Ampere VPS was prepared:

| Component | amd64 | arm64 |
|---|---|---|
| sops (pinned binary + checksum in `install-sops.sh`), Docker's apt repo, Tailscale's apt repo | yes | yes |
| OpenTelemetry Collector `.deb` (`otel_agent`) | yes | yes (selected from `ansible_facts['architecture']`) |
| Arkeep agent, Beszel agent, Arcane agent, restic REST server, Muximux, Garage + web UI, Loki, Traefik, nginx | yes | yes |
| Mailflow (`mailflow-frontend`, `mailflow-backend`), PostgreSQL 16, Redis 7 | yes | yes |

Re-check an image before you add it: `docker manifest inspect <image:tag> | grep architecture`; a single-architecture image will not run on an ARM host.
When a role downloads a binary itself it must choose by `ansible_facts['architecture']` (`x86_64` / `aarch64`) and verify a checksum, as `install-sops.sh` and
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
