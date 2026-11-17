# State

What is true right now, including what does not work. This file has an expiry: delete it when it stops being edited, rather than let it become a misleading history. Last reviewed 2026-11-17.

## Works

- Reconcile on Debian and Ubuntu, x86_64 and ARM64, on a real fleet; skip-unchanged and the low-priority service units are in place.
- The platform layer ([platforms.md](platforms.md)) on Debian 13, Ubuntu 24.04 and Alpine 3.22 in the CI matrix (containers, x86_64 runners), including a cron job that fires and a boot task that runs on OpenRC; and on real Debian and Ubuntu hosts through check-only runs compared with the previous version.
- An Alpine LXC on a Proxmox node reconciled by the container reconciler, as Unraid is.
- Traefik routes in per-domain files on the maintainer's fleet, with the host tables carrying `os:` and `arch:`.
- The role library listed in the [README](../README.md#the-role-library), in use on the maintainer's fleet.

## Known gaps

- **`safe_apply` covers three roles** (`otel_agent`, `forgejo_runner`, `zwave_js_ui`). Other roles that own a service's config still write a file and restart, with no automatic restore after a bad config. See [decisions.md](decisions.md) #3.
- **Role READMEs are not all on the contract block** from [ownership.md](ownership.md); 25 of 43 roles have a README at all.
- **macOS and Windows are not on the platform layer.** macOS has its own small playbook; Windows is a separate PowerShell reconciler, run on one VM only, with its `ssh` and `tailscale` roles and the MinGit and Tailscale installers not yet run on a host and no ARM64 Windows tried ([windows-host.md](windows-host.md)).
- **Alpine hosts run only container-based roles in practice.** The host-level roles pass the matrix in a container, but no Alpine host reconciles natively (no bootstrap for it), so `otel_agent` (a systemd service installed from a `.deb`), `wazuh_agent`, `firewall` (ufw) and `dns_resolver` do not run there. A collector in a container reading the host is the likely route for `otel_agent`; a `daemon` primitive (a unit or an OpenRC script) is the other.
- **cron cannot catch up a missed run** (systemd's `Persistent=true`), so on a host without systemd a job missed while it was off waits for the next schedule.
- **Provisioning is not built.** Hosts must exist before Consigliere can configure them.
- **Wazuh** (`stacks/wazuh/` and the Wazuh roles) has not been run against a live host. The submodule is pinned to `v4.14.7` as of 2026-08-21; `main` tracks an unreleased 5.x line, so recheck before deploying. **VERIFY**
- **The bespoke console** in `console/` builds and typechecks but has not been run against real Outline, Pocket ID and Tailscale accounts. Its Outline API field names are unverified. The recommended console is Cmdr. **VERIFY**
- **Dependency hygiene**: `.github/dependabot.yml` now sets a cooldown (added 2026-10-28). Base images in `console/Dockerfile` float on `node:24-alpine`, and `requirements-ci.txt` is unpinned. conformIT's cooldown rule ([its decision #26](https://github.com/almadon/conformIT)) flags the last two, and they are not fixed.
- **conformIT audit** (2026-10-28): after this change 18 pass, 9 warn, 2 fail. The two fails are false positives of the scanner: `git@github.com:` clone-URL syntax read as email addresses, and example tailnet placeholders in `console/.env.example` read as private hostnames. Neither is a real address.

## Unverified

- The calendar translator (systemd to cron) is tested on the forms the fleet uses and refuses the rest; it has not seen a fleet value outside those.
- The `platforms` CI workflow had passed for earlier merges when this was written; the run for the latest commit was still going.
- The reconcile speedups in the [changelog](../CHANGELOG.md) were reasoned from a profile of one pass on one host; the end-to-end saving on a scheduled run has not been measured yet.

## What earlier notes got wrong

- An earlier README listed naming, hosting and Arkeep/Arcane as open questions. All are settled and in use; they were removed rather than left to look unresolved.
