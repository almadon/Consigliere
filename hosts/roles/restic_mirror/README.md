# restic_mirror

Keeps a second restic REST server (the mirror) in step with the first, so Arkeep only
uploads each backup once. The mirror pulls from the source with `rsync` over the tailnet (the source is looked up with `tailscale ip`, so MagicDNS is not needed)
on a schedule (a systemd timer, or cron where there is no systemd: the platform layer's `schedule` task).

- Run it on the mirror host: `util: [restic, restic_mirror]` and `restic_mirror_source: <the source host>`.
- Restic pack, index and snapshot files never change after they are written, so
  `--ignore-existing` makes each run copy only what is new. `locks/` is skipped and
  nothing is deleted: a prune on the source does not remove data from the mirror.
- The mirror gets its own SSH key (`/root/.ssh/restic_mirror`), created on the first run,
  and the run prints its public key. Put it in `restic_server_mirror_keys` for the source
  host (e.g. `config/vars/host/<the source host>.yml`); the source then accepts that key only for a
  read-only `rrsync` of its data directory.
- **Pinning the source's SSH host key.** Set `restic_mirror_source_host_keys` (on the mirror host, for example in `config/vars/host/<the mirror host>.yml`)
  to the source's public key: the line from `/etc/ssh/ssh_host_ed25519_key.pub` on the source, read on the source itself. The role writes it to
  `/root/.ssh/restic_mirror_known_hosts` and the mirror then trusts only that key, matched by the source's name so a new tailnet address does not
  matter. If the source's keys later change (it was rebuilt, or its host keys were regenerated), the run stops, the failure alert says why, and the
  fix is to confirm the new key on the source and put it in the fleet; nobody has to log in to the mirror host. Without it the mirror trusts the
  first key it sees and refuses a changed one with a plain ssh error, which is easy to miss.
- The mirror's own REST server is a standby: restore from it by pointing restic at it.
- Corruption on the source would be copied too. Run `restic check --read-data` against
  the source now and then.
- Not tested against a live host.

- `restic_mirror_excludes: [/.pbs/]` keeps paths that are not restic repositories (for example another service on the source's data disk) out of the copy.
