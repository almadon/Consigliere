# Consigliere

**Declare a fleet in git. Every host keeps itself that way.**

Consigliere is a GitOps framework for a homelab or small fleet of Linux hosts (macOS and Unraid in a smaller role) on a Tailscale network. You describe each machine in one table and a few variable files. Each host pulls that description on a timer, checks it against reality, and corrects the difference, with no central server pushing changes.

> **Status: in testing.** Used on a real fleet, but the interfaces still move and several roles have not been run on every platform.
> This project comes with no warranty or guarantee of fitness for any purpose. Use it at your own risk.
>
> **LLM use.** Built and maintained with substantial AI assistance (Claude Code). Design decisions and reviews are by a human; generated code is reviewed before it is merged. See [AGENTS.md](AGENTS.md).

<p align="center">
  <img src="docs/images/layers.svg" alt="The six layers of Consigliere, from git at the top to applications at the bottom, with Tailscale on the left and drift checking on the right" width="100%">
</p>

## What it does

A host's table entry lists tags such as `util: [traefik]` or `feat: [otel]`. Each tag has a manifest that names the Ansible roles to run. The host reconciles itself every 20 minutes: it pulls the framework repo and your private fleet repo, runs a check pass when something changed, applies, and skips the run when nothing is new. Drift is corrected without anyone running a playbook.

## Use cases

**Reach for it when** you run a handful to a few dozen hosts you care about (a homelab, a few VPSs, a Proxmox node, an Unraid box), you want the whole setup reviewable in git, and you do not want to run a central controller or keep a push-based pipeline healthy.

**Look elsewhere when** you need dynamic autoscaling, thousands of nodes, or a hosted control plane with a vendor behind it.

## What Consigliere manages, and what it does not

This is the contract. If a thing is in the first table, edit it in git and let the reconciler apply it; a hand edit is reverted on the next run. If it is in the second, Consigliere leaves it alone, so a change there is made where it lives and is not undone.

### Managed: declared in git, rewritten by the reconciler

| Area | What | Where it is declared |
|---|---|---|
| Host OS | Packages, users, ssh hardening, sysctl, unattended upgrades, hostname, time zone, journald and reconcile limits | `baseline` role, `vars/` |
| Network | Tailscale install and enrollment, the ufw firewall (tailnet open, the world only where a tag asks), DNS resolver | `tailscale`, `firewall`, `dns_resolver` |
| Container engine | Docker install, the guard that controls published ports, Arcane's own containers | `docker`, `arcane_*` |
| Edge | Traefik routes, headers and certificates per host, issued once by Cert Warden and fetched as files | `traefik_server`, `certwarden_*`, `vars/routes/` |
| Observability | The otel agent on each host, Loki, VictoriaMetrics, Grafana's provisioned data sources and dashboards, exposure scans | `otel_agent`, `loki_server`, `victoria_server`, `grafana_server`, `exposure_watch` |
| Backups | The Arkeep server and agents, the restic REST target and mirror | `arkeep_*`, `restic_*` |
| Security | The Wazuh agents and the manager's kernel setting | `wazuh_*` |
| Consoles | Cmdr (the fleet console), Muximux tiles, Homarr and its sign-in gate | `cmdr`, `muximux`, `homarr` |
| Shared services | Garage S3, Apprise notifications and run reports, scheduled apt and compose updates, Forgejo runner | `garage`, `apprise`, `apt_updates`, `compose_updates`, `forgejo_runner` |
| Secrets access | Who can decrypt which secret, derived from tags | `config/secrets/`, `scripts/access.sh` in the fleet repo |

### Not managed: owned by something else

| Thing | Owner | Consigliere's part |
|---|---|---|
| Application stacks (`stacks/`) | **Arcane**, which syncs them from git and owns drift and redeploys | Installs Arcane, never touches the running containers |
| Edits made in an app's own UI: Grafana dashboards saved in the UI, Muximux tiles you add, Homarr boards | **You, in that app** | Only what is declared is restored; everything else is yours |
| Who may sign in, groups, passkeys, OIDC clients | **Your identity provider** (for example Pocket ID) | Reads the client ID and secret from a sops secret |
| DNS records, registrar settings | **Your DNS provider** | Documents the names; the one automated part is the ACME challenge record |
| Tailscale ACLs, tailnet settings, key expiry | **The Tailscale admin console** | Enrolls the host; never edits the policy |
| Cloud provider firewalls and security lists (for example Oracle's) | **The provider** | Leaves them alone |
| Creating hosts: VMs, VPSs, bare metal, hypervisor guests | **You** (provisioning is not built) | Takes a host that already exists and makes it converge |
| Proxmox, Unraid and the hardware under them | **The platform itself** | Container-based roles run on Unraid; Proxmox has its own [guide](docs/proxmox-host.md) |
| Data inside services: backups' contents, databases, object storage buckets' contents | **The service and you** | Runs the service and declares buckets and keys, not the data |
| Hand-registered credentials: the Forgejo runner registration, Garage's capacity layout | **You, once** | Keeps the result in place afterwards |
| Windows hosts | Not supported | None |

The full table, with the mechanism and rollback for each row, is [docs/ownership.md](docs/ownership.md).

## How it fits together

| Layer | Where | Does |
|---|---|---|
| 1. Declare | This repo (public, generic) and your **private fleet repo** | Roles, scripts and the console live here; your host table, variables and sops-encrypted secrets live there |
| 2. Reconcile | `hosts/bootstrap/reconcile.sh`, a systemd timer on every host | Syncs both repos, assembles a run directory, checks, applies |
| 3. Configure | `hosts/tags/`, your `config/tags/`, `hosts/roles/` | A host's tags choose roles, in manifest order |
| 4. Host | `baseline`, `tailscale`, `firewall`, `docker` | The same ground floor on every host |
| 5. Platform | The role library | Edge, observability, backups, security, consoles |
| 6. Applications | `stacks/` and Arcane | Your containers |

Two rules keep this readable. The **host table** (`config/inventory/hosts.yml` in your fleet repo) is the one place that says what a machine is, keyed by its Tailscale name. Settings live in one file per scope: `config/vars/group/<group>.yml`, `config/vars/host/<host>.yml` and `config/vars/routes/<host>.yml`, which the reconciler gives each host as a merged `host_vars/<host>/` directory.

## Getting started

1. Create your private fleet repo from [consigliere-fleet-template](https://github.com/almadon/consigliere-fleet-template) ("Use this template", private).
2. Describe a host in `config/inventory/hosts.yml`, keyed by its Tailscale hostname.
3. On the new host, as root, run `hosts/bootstrap/bootstrap.sh`. It installs git and Ansible, clones this repo, grants the host a read-only deploy key for your fleet repo, runs one reconcile, and installs the timer.
4. Give the host its secrets from your admin machine: `scripts/access.sh add-host <name> <age key>`, then `sync`, then push.

The host generates its own age key; nothing secret is copied to it. Tailscale auth keys are never stored: `bootstrap.sh` prompts for one.

## Reconciling

Each run is a short sequence, and every step is skippable on purpose:

1. **Sync** the framework and fleet repos.
2. **Skip** the whole run if neither repo changed since the last successful apply and a full run is not yet due (every 6 hours by default). `scripts/reconcile-now.sh` forces a run.
3. **Check** (`--check --diff`) when a repo changed. A failing check stops the run before anything is applied. `RECONCILE_PRECHECK=1` checks always, `0` never.
4. **Apply**, and record the commits that were applied.

Reconcile runs at low CPU and disk priority and caps the journal, so it does not compete with what the host is really for. `RECONCILE_PROFILE=1` prints per-task timings. The variables are in the [command-line reference](docs/cli-reference.md).

## Secrets

Nothing sensitive is committed to this repo, ever. Secrets live in your fleet repo under `config/secrets/<kind>/<name>.yml`, encrypted with [sops](https://github.com/getsops/sops) to the age public keys of the hosts allowed to read them. A host decrypts only what it is a recipient of, with a private key that never leaves it. Who can read what follows from each host's tags: add `util: [arkeep]` to a host, run `scripts/access.sh sync`, and it can read the Arkeep secrets. The `load_secrets` role is the only code that reads them. See [docs/security.md](docs/security.md).

## The role library

<details>
<summary><b>Roles by area</b> (each links to its README where it has one)</summary>

| Area | Roles |
|---|---|
| Ground floor | `baseline`, `tailscale`, `sops`, `docker`, `firewall`, `timezone`, `dns_resolver`, `nic_offload`, `data_disk` |
| Edge and certificates | [`traefik_server`](hosts/roles/traefik_server/README.md), `certwarden_server`, `certwarden_agent` |
| Observability | [`otel_agent`](hosts/roles/otel_agent/README.md), [`loki_server`](hosts/roles/loki_server/README.md), `victoria_server`, [`grafana_server`](hosts/roles/grafana_server/README.md), `exposure_watch`, `beszel_hub`, `beszel_agent` |
| Backups | `arkeep_server`, `arkeep_agent`, [`restic_server`](hosts/roles/restic_server/README.md), `restic_mirror`, `pbs_server` |
| Security | `wazuh_agent`, `wazuh_server` |
| Consoles | [`cmdr`](hosts/roles/cmdr/README.md), [`muximux`](hosts/roles/muximux/README.md), [`homarr`](hosts/roles/homarr/README.md) |
| Shared services | [`garage`](hosts/roles/garage/README.md), `apprise`, `apprise_server`, `apt_updates`, `compose_updates`, `semaphore_server`, [`forgejo_runner`](hosts/roles/forgejo_runner/README.md), `zwave_js_ui` |
| Containers | `arcane_server`, `arcane_agent` |
| Internals | `fleet_plan` (reads tag manifests), `load_secrets`, `safe_apply` (validate, keep a copy, apply, health-check, restore) |

</details>

## Documentation

| Read | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How the pieces fit and why |
| [docs/ownership.md](docs/ownership.md) | What is managed, how, and how to roll it back |
| [docs/cli-reference.md](docs/cli-reference.md) | `bootstrap.sh`, `reconcile.sh` and their variables |
| [docs/platforms.md](docs/platforms.md) | Debian, Ubuntu, ARM64, Unraid, macOS |
| [docs/proxmox-host.md](docs/proxmox-host.md), [docs/coordination-server.md](docs/coordination-server.md) | Specific host kinds |
| [docs/security.md](docs/security.md) | Trust boundaries and secrets |
| [docs/decisions.md](docs/decisions.md), [docs/STATE.md](docs/STATE.md), [CHANGELOG.md](CHANGELOG.md) | Why it is this way, what is true now, what changed |
| [VISION.md](VISION.md) | Where it is going and what it will not do |

## Contributing

Pushes to `main` are what hosts apply, so the lint gate (`ansible-lint` and `yamllint` in `.github/workflows/lint.yml`) is the change-approval step: review pull requests like deployments. The project follows the [conformIT](https://github.com/almadon/conformIT) engineering standard; conventions for people and agents are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE).
