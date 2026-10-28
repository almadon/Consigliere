# What Consigliere is

Consigliere is a single pane of glass for a fleet of hosts: baseline config,
provisioning, updates, security posture, and out-of-band hardware access
(KVM/DRAC/IPMI/AMT/SSH), all declared in git and continuously checked
against what's actually true - not just applied once and forgotten.

## The core discipline: declare, apply, and separately check for drift

A pattern worth stating plainly: declarative input, a dumb applier, and a separate check of what is actually true.
The drift check is the more valuable half, because it catches the failure that really happens: someone edits the live
copy instead of the source, and it silently stops matching. Consigliere applies it to a fleet of machines:

- **Declare** in git (Ansible roles, Terraform, stack definitions).
- **Apply** via a dumb, idempotent pusher - `ansible-pull`, Arcane's sync,
  Terraform.
- **Check for drift** separately and continuously - this is the piece that
  makes the rest trustworthy instead of "ran once, hope it held."

Every module below is either a *declare-and-apply* half or a *drift-check*
half of this same loop. Naming a future `consigliere drift`/`consigliere status`
surface - the console view that says "here's everywhere reality has
diverged from git" across *all* modules, not just OS packages - is the
throughline that ties them into one project rather than a pile of
unrelated integrations.

## Public framework, private fleet repo

Settled 2026-10-01/02: this repo is public and meant to be reusable by anyone
running their own fleet. It holds the *framework of all the software* (roles,
libraries, the console, bootstrap) and **nothing of the operator's**: no
secrets, no site values, and no taxonomy, since tag names and "which roles run
where" are the operator's own design.

All of that lives in a separate **private fleet repo**, created from
[consigliere-fleet-template](https://github.com/almadon/consigliere-fleet-template)
(not a fork: forks of public repos can't be private). Its two purposes:
**customization** (node taxonomy, composition, apps, runbooks) and
**secrets/variables**. The framework references that repo and is responsible
for making sure every host can read it when deployed: each host generates its
own read-only deploy key and has it registered (`hosts/bootstrap/ensure-access.sh`).
`hosts/bootstrap/reconcile.sh` then assembles each run from both repos and
reconciles the host against itself. See [README.md](README.md).

Infra-level names (env vars, systemd units, the launchd label) stay
product-name-agnostic (`FRAMEWORK_REPO_URL`, `fleet-reconcile.*`).

## Modules

### Declared config - `hosts/` (Ansible + `reconcile.sh`)
OS baseline, Tailscale, Docker engine, backups. See [README.md](README.md).

### Provisioning - Terraform (not yet built)
Stands servers up, doesn't just configure ones that exist. Blocked on
settling the substrate (hypervisor/cloud/bare-metal - currently a mix).

### Backups - Arkeep (decided 2026-10-01, over Zerobyte)
`hosts/roles/arkeep_server` (one host, the `arkeep_server` group) and
`hosts/roles/arkeep_agent` (every backed-up host, the `arkeep_agent` group)
deploy [Arkeep](https://github.com/arkeep-io/arkeep) - restic+rclone under
the hood, central server + gRPC/mTLS agents, agents auto-enroll via the
server's HTTP API (no manual cert/token exchange for *this* part - see
below for what *does* need a manual step). Superseded an earlier generic
`hosts/roles/backup` (hand-rolled restic + systemd timer), retired once
Arkeep's own agent took over scheduling/retention. All real values (server
address, secrets) come from the private fleet-config repo.

**One thing that can't be automated**: the shared `arkeep_agent_secret` and
`arkeep_server_secret_key` go in a sops secret like any other, but there's no
verified API for *minting* things - enrollment itself is automatic
(auto-PKI), so this is simpler than it sounds; see
`hosts/roles/arkeep_server/README.md` for the one manual step there is
(reverse-proxy wiring, if applicable).

### GitOps engine - Arcane (self-hosted via Ansible)
`hosts/roles/arcane_server` (one host) and `hosts/roles/arcane_agent`
(other Docker hosts) deploy [Arcane](https://github.com/getarcaneapp/arcane)
itself - previously assumed to just exist; this was a real gap until
2026-10-01 (Arcane obviously can't GitOps-deploy itself). The manager
variant uses Arcane's docker-socket-proxy-hardened compose shape since
that node is also internet-facing (reverse proxy). Agents run in **edge
mode** (as the manager's agent wizard generates): they poll the manager's
HTTPS URL outbound, so agent hosts publish no ports and need no firewall
changes. **One thing that can't be automated**: `arcane_agent_token` is
generated per agent by that wizard - a one-time manual step per agent host
(goes in that host's `config/vars/host/` file, not the shared
`config/vars/group/` files; a leaked token can be invalidated and
regenerated). The manager itself needn't be deployed by this role: an
existing manager works, agents just need its URL.

Also note: `getarcaneapp/arcane` is the *current* repo - it moved from
`ofkm/arcane` at some point before 2026-10-01; links elsewhere may still
say the old name.

### Containers - `stacks/` (Arcane)
Adopted, not built - Arcane already does compose/swarm GitOps sync well.

### Update intelligence (new - not yet built)
Applying updates (already covered: `unattended-upgrades` in `baseline`,
Watchtower/Shepherd for containers) isn't the same as *knowing what
changed*. This module is reporting, not another updater:
- **OS packages**: [`apt-listchanges`](https://packages.debian.org/apt-listchanges)
  - mature, Debian-native, surfaces each package's actual changelog on
  upgrade. Adopt, don't rebuild.
- **Container images**: [Diun](https://crazymax.dev/diun/) or
  [Renovate](https://docs.renovatebot.com/) for tag/digest diffs with
  links to release notes.
- **Breaking-change flagging**: a real heuristic Consigliere can own - semver
  major-bump detection across both of the above, surfaced in the console
  as "these updates likely need a look before they land," rather than
  trying to parse changelog prose for risk.

### Security posture / malware detection - Wazuh
The `wazuh_agent` role now enrolls a **Wazuh agent** rather than
running Lynis + maldet - fleet-wide file-integrity monitoring,
rootkit/malware detection, and log analysis with a real single-pane
dashboard, instead of Consigliere hand-rolling posture reporting on top of two
separate CLI tools. Same "adopt, don't reinvent" call as Arcane for
containers. The manager/indexer/dashboard stack lives in `stacks/wazuh/`
(vendored as a git submodule, see its README); `wazuh_server` (a new,
manager-only role) handles the one host-level prerequisite (OpenSearch's
`vm.max_map_count` sysctl). Scaffolded, not yet run against a live host.

### Fleet console - `console/` (Next.js)
Ties the modules together: OIDC via Pocket ID, per-machine metadata from
Outline, links/actions per host (KVM, SSH, dashboards), and - as the other
modules land - the place `consigliere drift` gets surfaced as one view instead
of five separate tools' separate dashboards. See
[console/README.md](console/README.md).

## What sets it apart from adopting something off the shelf

Every module above was picked *after* asking "does a robust existing tool
already do this" - most of them are adopted tools (Arcane, Wazuh, and
eventually apt-listchanges/Diun), not reinventions. What's actually
custom is small and deliberate:

- **Not a bookmark dashboard** (Homepage/Homarr): the console drives real
  actions, such as config enforcement via
  Ansible/Terraform - not just curated links. (Homepage is still fine to
  keep running separately for general household links; Consigliere isn't trying
  to replace that use case.)
- **Not a second inventory database** (NetBox): metadata lives in Outline,
  which was already in daily use, via a documented per-machine convention
  - one source of truth instead of two.
- **Not a general enterprise platform** (Foreman/Fleet): scoped tightly to
  this actual stack - Tailscale-first, Ansible/Terraform, Arcane, Pocket
  ID - rather than a platform with its own opinions to work around.
## Explicitly out of scope for now: Android TV / device MDM

Raised as a future need (wiping personal data on checkout) but deliberately
not folded into any module above. It's a different protocol (Android
Enterprise / Android Management API, not SSH/IPMI/KVM) and a different
trust model. If it happens, it's its own integration hanging off the same
console - not evidence that Consigliere needs to become a universal device
manager.

## Roadmap (as of 2026-10-01, user-stated priority order)

1. **Centralized backup management** - Arkeep chosen 2026-10-01, roles
   scaffolded, see Backups above. First real deployment target: two nodes,
   one running the Arkeep server + Arcane manager + reverse proxy, the
   other an agent-only node.
2. **Caddy → Traefik + Bunny "geoDNS" for existing edge proxies** - lives in
   a *separate* sibling repo, `geotraefik` (`~/Workspaces/Apps/tooling/geotraefik`),
   not here. That repo already has a real Traefik v3.6 + Bunny DNS-01 pilot
   committed. 
3. **A web UI surfacing all of this** - this is `console/`, already built.
   A guest-portal web app (a fork the maintainer has) was mentioned as a
   framework worth drawing from for this - not yet located/reviewed; get the
   repo path before assuming anything about its stack or design.
4. **Wazuh rollout** - already scaffolded, see Security posture above.
## Open threads (tracked so they don't get re-derived)

- **Backup tool - settled 2026-10-01: Arkeep** (over Zerobyte).
- Terraform's provisioning substrate - hypervisor/cloud/bare-metal mix,
  unresolved.
- Outline vs. WikiJS - under consideration, doesn't block anything (the
  provider abstraction isolates it).
- Where this framework repo is hosted - currently GitHub
  (`github.com/almadon/Consigliere`).
- Wazuh's default credentials need rotating before `stacks/wazuh/` touches
  anything but localhost - see its README's procedure.
- Update intelligence module (apt-listchanges, Diun/Renovate, breaking-
  change flagging) is named but not yet built.
- A guest-portal web app (a fork the maintainer has) - referenced as design
  inspiration for `console/`, location not yet provided.
- None of `arkeep_server`/`arkeep_agent`/`arcane_server`/`arcane_agent`
  have been run against a real host yet - scaffolded and template-rendering
  verified (valid YAML in both the standalone and behind-proxy branches),
  not deployment-verified.
- **Stashed idea (2026-10-03): warn instead of fail, driven by a `req:` property.** A
  failing role currently stops its play (and, on a first run, the whole bootstrap). The
  idea: mark what is essential per tag or host (e.g. `req: yes`); anything *not*
  required would log a strong warning and carry on, and the run would end with a
  post-run summary/log (and an Apprise notification) of everything that failed or was
  skipped, while a failure in something required still stops the run. Not designed or
  built: open questions are where the flag lives (tag manifest vs host table), how
  failures are collected (`block`/`rescue` around each plan item in `fleet_plan`),
  and what a partially applied host should report to the heartbeat.
