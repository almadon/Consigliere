# forgejo_runner

A [Forgejo Actions](https://forgejo.org/docs/latest/admin/actions/) runner in Docker, owned by the repo: its compose file, `config.yml` and labels.

- **Registered once, by hand** (`forgejo-runner register`); this role then keeps it. The registration credential (uuid and token) is the secret `forgejo.runner`.
- **Pin images by digest.** `forgejo_runner_image` and each entry of `forgejo_runner_labels` should end in `@sha256:...`. A floating tag such as `node:22-bookworm` stays whatever was pulled first
  (`force_pull: false`), which is how a runner ends up building with a months-old Node. Pinned digests change only when the fleet repo changes (Renovate proposes bumps after your cooldown period).
- **Quiet moments only.** The runner is not restarted while a job runs; the next run applies the change.
- **Applying a change** goes through [safe_apply](../safe_apply/README.md) (compose path), so a runner that does not come back is rolled back.
