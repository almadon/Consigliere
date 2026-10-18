# restic_mirror

Keeps a second restic REST server (the mirror) in step with the first, so Arkeep only
uploads each backup once. The mirror pulls from the source with `rsync` over the tailnet (the source is looked up with `tailscale ip`, so MagicDNS is not needed)
on a systemd timer.

- Run it on the mirror host: `util: [restic, restic_mirror]` and `restic_mirror_source: pulsar`.
- Restic pack, index and snapshot files never change after they are written, so
  `--ignore-existing` makes each run copy only what is new. `locks/` is skipped and
  nothing is deleted: a prune on the source does not remove data from the mirror.
- The mirror gets its own SSH key (`/root/.ssh/restic_mirror`), created on the first run,
  and the run prints its public key. Put it in `restic_server_mirror_keys` for the source
  host (e.g. `config/vars/host/pulsar.yml`); the source then accepts that key only for a
  read-only `rrsync` of its data directory.
- The mirror's own REST server is a standby: restore from it by pointing restic at it.
- Corruption on the source would be copied too. Run `restic check --read-data` against
  the source now and then.
- Not tested against a live host.
