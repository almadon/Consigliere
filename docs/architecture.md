# Architecture

How the pieces fit, and why each is where it is. The picture is at the top of the [README](../README.md); this is the reasoning behind it.

## Two repositories

The framework (this repo) is public and generic: roles, scripts, bootstrap, the Cmdr console. It holds no secrets, no site values and no taxonomy. Tag names and "which roles run where" are the
operator's own design, so they live in a private fleet repo made from [consigliere-fleet-template](https://github.com/almadon/consigliere-fleet-template).
**The split exists so the framework can be reused and reviewed in public while the fleet stays private.** The cost is that a change often touches both repos, and the two must agree on variable names.

## Every host reconciles itself

There is no controller that pushes. Each host runs `hosts/bootstrap/reconcile.sh` from a systemd timer (20 minutes plus jitter), which:

1. syncs both repos, using a read-only deploy key that never leaves the host;
2. skips the run when neither repo changed since the last successful apply, unless a full run is due or `force-run` exists;
3. assembles a throwaway run directory: `group_vars`, a merged `host_vars/<host>/` (settings and routes kept in separate files), the lowercased host table, the secrets directory and the tag-manifest search path;
4. runs the playbook against this host only, over a local connection, with a check pass first when a repo changed.

Why pull rather than push: a host that is offline catches up when it returns, there is no inventory server or SSH fan-out to keep healthy, and the blast radius of a bad run is one host. The cost is that a change
takes up to 20 minutes to land, which `scripts/reconcile-now.sh` shortens on demand, and that every host carries Ansible.

## Tags choose roles

A host's table entry carries tags in dimensions (`util`, `feat`, `prop`, `fw`, `cert`) and descriptive values (`site`, `org`, `type`, `location`, `geo`). The `groups.yml` in the fleet repo turns values into
groups so variables can be attached (`vars/group/util_traefik.yml`). For `util` and `feat`, `hosts/tags/<dimension>/<value>.yml` names the roles and task files, an `order`, the secrets it needs and the ports it opens.
The `fleet_plan` role reads these and runs the plan; `site.yml` needs no edit to add a service. The fleet may override or add manifests under `config/tags/`.

## Rollback of a running service

A role that owns a long-running service's config includes `safe_apply`: it checks the service is healthy now, keeps the running file as `.last-good`, writes the new one (with the tool's own validator), restarts, health-checks, and
on failure restores the previous file, restarts, and **fails the run** so a rollback is never reported as success. A configuration that failed once is not retried until its content changes. Today `otel_agent`, `forgejo_runner` and
`zwave_js_ui` use it; the rest still write a file and restart (see [STATE.md](STATE.md)).

## Where state lives

| State | Where |
|---|---|
| Desired state | Git, in two repos |
| Secrets | Encrypted files in the fleet repo; the private key per host in `/etc/fleet-reconcile/age.key` |
| Last applied commits and time | `/opt/fleet-reconcile/last-applied` |
| The last run's output | `/opt/fleet-reconcile/last-run.log` |
| Service data | On the host, on a data disk where the host has one |

## Drift check

Applying is half of the loop. The check is separate: a `--check --diff` pass reports differences, `exposure_watch` compares what the internet can reach against what the fleet declares, and Cmdr and Grafana
show what each host reports. Each is a read of what is actually true.

## What this is deliberately not

Not a provisioner (hosts must already exist), not a hosted service, not a secrets vault for application data, and not an application deployer: containers in `stacks/` belong to Arcane.
See [VISION.md](../VISION.md) for the longer list.

## Replacing a part

| Part | Chosen because | Would justify replacing it |
|---|---|---|
| Ansible, local connection | Idempotent, readable, large module library | Per-task cost becomes the reason runs take minutes (about a second per task on a small ARM VM) and a faster engine fits the same roles |
| Tailscale | Zero-config encrypted mesh, MagicDNS | A requirement to self-host the coordination server fully (see [coordination-server.md](coordination-server.md)) |
| sops with age | Per-host keys, encrypted files in git, no server | A need for dynamic, short-lived credentials |
| Arcane for stacks | Compose GitOps with drift detection | Loss of upstream maintenance |
