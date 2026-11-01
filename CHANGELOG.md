# Changelog

What changed and why, including reverts. Dates are absolute.

## 2026-11-01

- **Muximux 3.7.0 (from 3.6.2).** Released 2026-10-29. Embedded apps such as a Homarr dashboard can now switch Muximux to other apps (`allow_navigation`, off by default, per app), and the release updates `go-jose` for a denial-of-service fix. The role gains an optional `allow_navigation` field on tiles in `muximux_apps`; nothing changes for a tile that does not set it. The role's own pin is the only version change, so a host takes the upgrade at its next reconcile (the container image is pulled and recreated).

## 2026-10-28

- **Reconcile is faster on routine runs.** `RECONCILE_PRECHECK` now defaults to `auto`: the check pass runs only when a repo changed since the last successful apply. A scheduled drift-correction pass over commits already checked and applied goes straight to apply, roughly halving its time. `RECONCILE_PRECHECK=1` restores the old always-check behaviour. Measured on an Oracle ARM VM: one pass took about 76 seconds, spread over roughly 80 tasks, so there was no single slow task to fix.
- `site.yml`: the second play no longer gathers facts again; the first play's stay available.
- `RECONCILE_PROFILE=1` prints per-task timings.
- Documentation brought onto the conformIT standard: README redesign with a layer diagram and a managed/not-managed contract, `docs/ownership.md`, `architecture.md`, `security.md`, `credits.md`, `STATE.md`, `decisions.md`, `AGENTS.md`, `LICENSE`.
- Naming history and references to unrelated sibling projects removed from the docs.
