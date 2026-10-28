# Changelog

What changed and why, including reverts. Dates are absolute.

## 2026-10-28

- **Reconcile is faster on routine runs.** `RECONCILE_PRECHECK` now defaults to `auto`: the check pass runs only when a repo changed since the last successful apply. A scheduled drift-correction pass over commits already checked and applied goes straight to apply, roughly halving its time. `RECONCILE_PRECHECK=1` restores the old always-check behaviour. Measured on an Oracle ARM VM: one pass took about 76 seconds, spread over roughly 80 tasks, so there was no single slow task to fix.
- `site.yml`: the second play no longer gathers facts again; the first play's stay available.
- `RECONCILE_PROFILE=1` prints per-task timings.
- Documentation brought onto the conformIT standard: README redesign with a layer diagram and a managed/not-managed contract, `docs/ownership.md`, `architecture.md`, `security.md`, `credits.md`, `STATE.md`, `decisions.md`, `AGENTS.md`, `LICENSE`.
- Naming history and references to unrelated sibling projects removed from the docs.
