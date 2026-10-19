# Consigliere

GitOps-based baseline setup and continuous maintenance for a homelab cluster
(Linux servers today, macOS hosts eventually), networked over Tailscale.
Formerly named ATC (Air Traffic Control), then Kuzka.

See [VISION.md](VISION.md) for what this project actually is, how its
modules relate to each other and to the sibling `novak`/`flashCtrl`
projects, and what's deliberately out of scope.

## Architecture

Two layers, each with its own reconciliation loop. Git is the source of
truth for both — nothing gets applied by hand.

### 1. Host OS layer — `hosts/` (Ansible)

Packages, Tailscale enrollment, Docker engine install, security posture
checks. Applied via **`reconcile.sh`** on a systemd timer running on every
host (see `hosts/bootstrap/`) — each host reconciles itself against this
repo (plus your private fleet-config repo, see below) on a schedule, so
drift gets corrected automatically without anyone running a playbook by
hand.

[Semaphore UI](https://github.com/semaphoreui/semaphore) sits alongside for
visibility (run history, dashboard) and on-demand/webhook-triggered runs —
it is not the primary execution path, `ansible-pull` is.

Roles:
- `baseline` — users, SSH hardening, unattended-upgrades, short OS hostnames (an FQDN is trimmed to its first label; `baseline_short_hostname: false` turns it off)
- `tailscale` — install + join (see inventory below)
- `firewall` — ufw, run last by `fleet_plan`: deny inbound except everything on the tailnet
  interface, plus ports the tags ask for (`util: [traefik]` opens 80/443; a manifest's
  `firewall:` list). SSH is not opened to the world: reach it over Tailscale, or list LAN
  networks in `firewall_ssh_from`. A host that isn't on the tailnet yet keeps SSH open (with
  a warning) so it can't be locked out. Docker-published ports bypass ufw.
- `docker` — Docker CE install; `docker_mode: standalone|swarm` toggles swarm-specific tasks
- `wazuh_agent` — opt-in via the `wazuh_agent` group (so nothing breaks before a manager exists); enrolls a Wazuh agent against `wazuh_server_addr`
  (see [stacks/wazuh/](stacks/wazuh/)); replaced an earlier Lynis+maldet
  approach, see VISION.md
- `wazuh_server` — applied only to the `wazuh_server` group, sets the
  `vm.max_map_count` sysctl the Wazuh indexer requires
- `arkeep_server` / `arkeep_agent` — centralized backups via
  [Arkeep](https://github.com/arkeep-io/arkeep): one host runs the server
  (the `arkeep_server` group), every backed-up host runs the agent
  (the `arkeep_agent` group), connecting outbound over gRPC
- `certwarden_server` / `certwarden_agent` — a central ACME client
  ([Cert Warden](https://github.com/gregtwallace/certwarden); non-commercial
  license) issues certificates once, and consumer hosts fetch them as files, so
  DNS API credentials live on one host
- `traefik_server` — renders Traefik's dynamic config per host (a shared base,
  that host's own routes gathered from `traefik_server_routes*` variables, and the
  fetched certificates); see [its README](hosts/roles/traefik_server/README.md)
- `muximux` — the fleet console: a [Muximux](https://github.com/mescon/Muximux) dashboard whose tiles come
  from fleet variables (`util: [muximux]`, sign-in through OIDC such as Pocket ID, secret `muximux.server`);
  see [its README](hosts/roles/muximux/README.md)
- `beszel_hub` / `beszel_agent` — [Beszel](https://www.beszel.dev) host monitoring: one hub (`util: [beszel]`),
  an agent on every host that carries `prop: [beszel]` (secret `beszel.agent`)
- `restic_server` — a [restic REST server](https://github.com/restic/rest-server)
  backup target (`util: [restic]`); see [its README](hosts/roles/restic_server/README.md)
- `apprise` — notifications through [Apprise](https://github.com/caronc/apprise) (~100
  services); installs `fleet-notify` for other roles (`feat: [apprise]`, secret `apprise.notify`)
- `apt_updates`, `compose_updates` — scheduled `apt update && upgrade` and `docker compose
  pull && up -d`, each followed by an Apprise notification (`feat: [apt_updates]`,
  `feat: [compose_updates]`; both pull in `apprise`). `compose_updates` moves `:latest`
  images forward: pin or exclude what you don't want updated.
- `timezone`, `dns_resolver` — optional, driven by `prop:` manifests in your repo
- `arcane_server` / `arcane_agent` — deploys
  [Arcane](https://github.com/getarcaneapp/arcane) itself (one manager,
  agents elsewhere) — Ansible's job is getting Arcane running at all;
  everything in `stacks/` below is then Arcane's job, not Ansible's

### 2. Application/stack layer — `stacks/` (Arcane)

Docker Compose / Swarm stack definitions, one directory per service, once
Arcane itself is running (see `arcane_server`/`arcane_agent` above — a
bootstrapping step, since Arcane can't GitOps-deploy itself). Arcane then
watches this tree directly and handles sync, drift detection, and
redeploys — it owns this layer, Ansible does not touch running containers
beyond the Docker engine itself and Arcane's own containers.

Scaffolded so far: `console/` (below) and `wazuh/` — the manager/indexer/
dashboard for fleet security monitoring, vendored as a git submodule
rather than hand-copied (see [stacks/wazuh/README.md](stacks/wazuh/README.md)).

### 3. macOS — `macos/`

Same philosophy (git is source of truth, self-reconciling), but Homebrew
instead of apt, and a launchd agent instead of a systemd timer since macOS
has no systemd. Security posture role is skipped for now — XProtect is
already native; revisit if that ever feels insufficient.

### 4. Fleet console

The default console is the **`muximux` role** (see the role list above): a Muximux dashboard generated from
the fleet repo (`util: [muximux]`; set up with the fleet repo's `scripts/console.sh init`). The bespoke
Next.js app described below is optional and no longer the recommended base.

#### The bespoke Next.js console — `console/`

A bespoke webUI, deployed as its own stack (`stacks/console/`) and gated
behind OIDC login via [Pocket ID](https://github.com/pocket-id/pocket-id).
One tile per machine — KVM link, SSH launch, dashboard links, live
reachability — sourced from a pluggable machine-data provider
(`console/src/lib/providers/`); the only implementation today reads one
Outline doc per machine and can regenerate a fleet-wide overview table
from those docs on demand, so nothing has to be hand-copied between pages.
See [console/README.md](console/README.md) for the per-doc convention and
setup. Status: scaffold builds and typechecks clean, not yet run against
real Outline/Pocket ID/Tailscale accounts.

### 5. Provisioning — not yet built

Terraform, for standing up new Debian servers themselves (not just
configuring ones that already exist) — the provisioning substrate is a mix
of hypervisor/cloud/bare-metal and not yet settled, so this hasn't been
scaffolded. `hosts/bootstrap/` + cloud-init covers "a box already exists,
get it self-reconciling" in the meantime.

## Public framework, private fleet repo

This repo is public and generic: a library of roles, a default playbook, the
console, bootstrap scripts. It contains **no taxonomy, no site-specific
values, and no secrets**. Your fleet lives in a **separate private repo** you
create from [consigliere-fleet-template](https://github.com/almadon/consigliere-fleet-template)
(GitHub forks of public repos can't be private, so use "Use this template" ->
Private). That repo has two jobs:

1. **Customization**: your host table and grouping (`config/inventory/hosts.yml`,
   `groups.yml`), optionally which roles run where (`config/site.yml`), your own roles/apps,
   and your runbooks.
2. **Secrets and variables**: `config/vars/group/`, `config/vars/host/` (a host's settings),
   `config/vars/routes/` (a host's Traefik routes, kept apart from its settings; optional), and the
   sops-encrypted files under `config/secrets/`. The reconciler gives each host a `host_vars/<host>/`
   directory holding its `host` and `routes` files, which Ansible merges.

### Inventory and group names

Each host reconciles itself, so the inventory is just that host:
`hosts/inventory/tailscale_self.py` reports it under its Tailscale hostname
(from the local `tailscale status`, no API key). Your private repo's
`config/inventory/hosts.yml` is the host table: one entry per host, keyed by that
hostname, with values like `type`, `site`, `util` and `feat`. `groups.yml`
turns those values into groups (`type_vps`, `site_home`, `util_rpc_proxy`, ...)
(OS groups such as `os_linux_debian` are added automatically). What a host *runs* is
chosen by **tag manifests**: for each `util:` / `feat:` value in its entry,
`hosts/tags/<dimension>/<value>.yml` (or the same path in your repo's `config/tags/`,
which wins) names the roles and task files to run, e.g. `util: [traefik]` runs
`traefik_server` and `feat: [arkeep]` runs `arkeep_agent`. Edit a manifest to change what
a tag does; add a role plus a manifest to add a tag. `hosts/site.yml` needs no edit. The
run is limited to the host itself, and Tailscale tags are not used for grouping or as a
source of truth. Every tag value is also a group (`util_traefik`, `feat_arkeep`,
`type_vps`) for attaching variables (`vars/group/util_traefik.yml`). A tag with no manifest
is just such a class. Roles run in each manifest's `order`.
them to attach variables). A host matching no group still gets the baseline.

### Optional extensions

Anything beyond the core (baseline, Tailscale, Docker, secrets, tag manifests) is an
optional, self-contained extension: a role plus, if you like, a manifest that names it.
Nothing runs unless a host's table entry asks for it, so adopt them one at a time.
`timezone` and `dns_resolver` are examples; they are driven by `prop:` tags whose
manifests live in *your* repo's `config/tags/prop/` (see the template's `.example`
files), so which properties exist is your choice, not the framework's.

## Bootstrapping a brand-new host

A fresh host has neither repo nor Ansible yet, so reconciliation can't be
the *first* step. `hosts/bootstrap/bootstrap.sh`:

1. Installs `git`, `ansible`, `curl`.
2. Clones this framework repo.
3. **Grants the host access to your private repo** (`ensure-access.sh`): it
   generates a read-only deploy key on the host (the private half never leaves
   it); with `FLEET_CONFIG_REGISTER_TOKEN` it registers the key on GitHub for
   you, otherwise it prints the public key and waits until you add it.
4. Runs `hosts/bootstrap/reconcile.sh` once. That clones your private repo,
   assembles a run directory (your vars + your `groups.yml` + your `site.yml`
   if you have one, else the default, + framework and fleet roles), and runs
   the playbook against this host.
5. Installs `fleet-reconcile.timer` so it repeats on a schedule; each run
   re-syncs both repos, so drift in either is corrected. Every apply is preceded by
   a check pass; set `RECONCILE_MODE=check` for a report-only host.

Secrets are not copied to hosts. The host generates its own age key and prints the
public half; you grant it its secrets from your admin machine
(`scripts/access.sh add-host <name> <key>`, `sync`, push). See "Secrets" below.

## Secrets

Nothing sensitive is committed in this repo, ever. Backup credentials, API keys
and the like live in your private repo's `config/secrets/<kind>/<name>.yml`,
encrypted with [sops](https://github.com/getsops/sops) to the age public keys of
the hosts allowed to read each file. A host can decrypt only the files it is a
recipient of, with a private key that never leaves it (`/etc/fleet-reconcile/age.key`),
so there are no shared passwords to copy around. Who may read what is derived from
each host's tags (`config/inventory/hosts.yml` plus the tag manifests'
`secrets:` lists): add `util: [arkeep]` to a host, run `scripts/access.sh sync`, and
it can read the Arkeep secrets. The `load_secrets` role is the only place that reads
secrets, so the backend can change later. Tailscale auth keys are never stored:
`bootstrap.sh` prompts for one. The template ships a pre-commit guard that refuses
to commit a secret unencrypted.

## CI

`.github/workflows/lint.yml` runs `ansible-lint` + `yamllint` on every
push/PR. Since pushes to `main` are what reconciliation actually applies
to live hosts, this lint gate is effectively the change-approval step —
review PRs like it. (Your private fleet-config repo should have its own
equivalent gate — this one only covers the framework.)

## Open decisions (not yet settled)

- Naming — "Consigliere" vs something else (conformIT was
  raised too). Internal docs still say "Consigliere"; infra-level names
  (env vars, systemd units) were deliberately made name-agnostic so this
  doesn't need a second mass-rename once it's settled.
- Where this framework repo itself is hosted — currently GitHub
  (`github.com/almadon/Consigliere`), presumably staying there.
- Whether swarm join tokens get regenerated/rotated, and how.
- Provisioning substrate for Terraform (hypervisor/cloud/bare-metal mix) —
  needed before the provisioning layer can be scaffolded.
- Outline API field names in `console/src/lib/outline/client.ts` are
  unverified against a live instance — check on first real run.
- Wazuh's stable tag (submodule pinned to `v4.14.7` as of 2026-08-21) —
  reverify before deploying, since `main` already tracks an unreleased 5.x
  line.
- Nothing in `stacks/wazuh/` or the Wazuh-related roles has been run
  against a live host yet.
