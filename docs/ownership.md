# Ownership

What Consigliere manages, who controls each thing, and why. The summary table is in the [README](../README.md#what-consigliere-manages-and-what-it-does-not); this is the full one.
A role that sets something up and then leaves it to the app's own UI is a legitimate answer. An unstated one is not.

| Thing | Owner | Mechanism | Why | Where to change it | Backup |
|---|---|---|---|---|---|
| OS baseline (packages, ssh, sysctl, users, upgrades) | This repo | Rewritten every run | One source of truth; drift is the failure mode | Role defaults, fleet `config/vars/` | Hand-made sysctl lines are commented out, originals kept in `/var/backups/consigliere` |
| Firewall rules | This repo | Rewritten every run | A closed host by default | `firewall` role, tag manifests' `firewall:` lists | Image-provided rules saved to `/var/backups/consigliere/*.from-image` |
| Tailscale enrollment | This repo, first run | Seeded once | Auth keys are never stored | `bootstrap.sh` prompt | Re-run `tailscale up` |
| Tailscale ACLs and tailnet settings | The Tailscale admin console | Read-only here | Policy belongs to the network, not a host | Tailscale admin | Tailscale's own history |
| Docker engine, published-port guard | This repo | Rewritten every run | The guard is what keeps ufw meaningful | `docker` role | Package manager |
| Traefik routes, headers, certificates | This repo | Rewritten every run, via `safe_apply` for service config | Routes are declared per host | Fleet `config/vars/routes/<host>.yml` | `<file>.last-good` next to each file |
| ACME issuance | Cert Warden (this repo deploys it) | Issued once, fetched as files | DNS credentials live on one host | `certwarden_*` roles | Cert Warden's own store |
| otel agent config | This repo | Rewritten every run, via `safe_apply` | The collector must never crash-loop silently | `otel_agent` defaults and fleet vars | `<file>.last-good` |
| Loki, VictoriaMetrics storage | The service | Data kept on a data disk | Data is not config | Retention in role vars | Per the fleet's backup jobs |
| Grafana data sources and provisioned dashboards | This repo | Rewritten every run | Dashboards from git survive a rebuild | Fleet `assets/dashboards/*.json` | Git |
| Grafana dashboards saved in the UI | You, in Grafana | Not touched | A UI edit is a deliberate act | Grafana | Grafana's database |
| Arkeep jobs and repositories | Arkeep's UI | Seeded; the role deploys the server and agents | Schedules are an operator decision | Arkeep | Arkeep's own database |
| Arcane and the stacks it deploys | Arcane | Consigliere installs Arcane only | Arcane watches `stacks/` and owns drift for them | `stacks/` in git, then Arcane | Git |
| Muximux tiles | Split: declared tiles are restored, the rest is yours | Declared tiles rewritten; others ignored | See [Muximux README](../hosts/roles/muximux/README.md) | Fleet vars, or Muximux for your own | Git for declared tiles |
| Cmdr console | This repo | Rewritten every run | A generated view of the host table | `cmdr` role and fleet vars | Stateless |
| Homarr boards and users | You, in Homarr | Container and gate are managed; boards are not | Boards are personal | Homarr UI | Its appdata volume |
| Garage buckets and keys | This repo | Declared buckets and keys applied | Names are config | Fleet vars | The data is not backed up by this role |
| Garage capacity layout | You, once | Manual (`garage layout assign`) | Capacity depends on the disk | Command in the Garage README | Garage's metadata |
| Forgejo runner registration | You, once | Manual `forgejo-runner register` | A token is minted per runner | Forgejo | Secret `forgejo.runner` |
| Secrets | This repo's tooling, your fleet repo's files | sops, one age key per host | A host reads only its own | `scripts/secrets.sh`, `scripts/access.sh` | Git history of the encrypted files, plus each host's age key |
| Identity: users, groups, OIDC clients | Your identity provider | Read-only here | Authentication is a separate system | The provider | The provider |
| DNS records | Your DNS provider | Documented, not applied | No DNS credentials are kept beyond the ACME challenge | The provider | The provider |
| Cloud provider firewalls and security lists | The provider | Not touched | Out of reach of a host-level agent | The provider | The provider |
| Host creation | You | Not built | Provisioning substrate is a mix | Your tooling | n/a |
| Proxmox, Unraid, hardware | The platform | Not touched beyond a documented profile | See [proxmox-host.md](proxmox-host.md), [platforms.md](platforms.md) | The platform | The platform |

## Synced both ways

Nothing is synced both ways. Everything marked "This repo" flows from git to the host, and a hand edit is overwritten on the next run. Everything marked
with an app or an operator as owner is never written back to git by Consigliere.

## Module contract block

Each role README opens with five lines:

- **Does:** what it does
- **Owns settings:** who controls its settings
- **Keeps state:** what it stores, and where
- **Rolls back by:** `safe_apply`, a kept original, or the recorded exception
- **Exposes:** ports, endpoints and files others rely on

Roles written before this contract have not been brought onto it yet (see [STATE.md](STATE.md)).
