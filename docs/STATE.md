# State

What is true right now, including what does not work. This file has an expiry: delete it when it stops being edited, rather than let it become a misleading history. Last reviewed 2026-10-28.

## Works

- Reconcile on Debian and Ubuntu, x86_64 and ARM64, on a real fleet; skip-unchanged and the low-priority service units are in place.
- The role library listed in the [README](../README.md#the-role-library), in use on the maintainer's fleet.

## Known gaps

- **`safe_apply` covers three roles** (`otel_agent`, `forgejo_runner`, `zwave_js_ui`). Other roles that own a service's config still write a file and restart, with no automatic restore after a bad config. See [decisions.md](decisions.md) #3.
- **Role READMEs are not all on the contract block** from [ownership.md](ownership.md); 23 of 42 roles have a README at all.
- **Provisioning is not built.** Hosts must exist before Consigliere can configure them.
- **Wazuh** (`stacks/wazuh/` and the Wazuh roles) has not been run against a live host. The submodule is pinned to `v4.14.7` as of 2026-08-21; `main` tracks an unreleased 5.x line, so recheck before deploying. **VERIFY**
- **The bespoke console** in `console/` builds and typechecks but has not been run against real Outline, Pocket ID and Tailscale accounts. Its Outline API field names are unverified. The recommended console is Cmdr. **VERIFY**
- **Dependency hygiene**: `.github/dependabot.yml` now sets a cooldown (added 2026-10-28). Base images in `console/Dockerfile` float on `node:24-alpine`, and `requirements-ci.txt` is unpinned. conformIT's cooldown rule ([its decision #26](https://github.com/almadon/conformIT)) flags the last two, and they are not fixed.
- **conformIT audit** (2026-10-28): after this change 18 pass, 9 warn, 2 fail. The two fails are false positives of the scanner: `git@github.com:` clone-URL syntax read as email addresses, and example tailnet placeholders in `console/.env.example` read as private hostnames. Neither is a real address.

## Unverified

- The reconcile speedups in the [changelog](../CHANGELOG.md) were reasoned from a profile of one pass on one host; the end-to-end saving on a scheduled run has not been measured yet.

## What earlier notes got wrong

- An earlier README listed naming, hosting and Arkeep/Arcane as open questions. All are settled and in use; they were removed rather than left to look unresolved.
