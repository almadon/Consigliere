# restic_server

A [restic REST server](https://github.com/restic/rest-server) in Docker: the backup
target restic clients write to over HTTP. Run it on a host tagged `util: [restic]`.

- Users: the secret `restic.server` (`config/secrets/restic/server.yml`), one
  `user:bcrypt-hash` line per user (`htpasswd -nbB alice 'pw'`).
- Listens on the host's Tailscale IP (port 8000) by default; set
  `restic_server_network: proxynet` to put it behind Traefik instead.
- `restic_server_append_only: true` (default): clients can add data but not delete or
  overwrite it, so a compromised client can't destroy its backups. `restic forget --prune`
  needs delete rights, so to prune: set `restic_server_append_only: false`, let it
  reconcile, prune from a client, then set it back to true.
- A dedicated disk: set `restic_server_data_device` (a `/dev/disk/by-id/...` path); a blank disk is formatted (ext4) and mounted at the data dir, one with data on it fails the run instead of being wiped.
- Data lives in `restic_server_data_dir` (default `/srv/restic`): size the disk for it and
  back it up (an offsite copy with `restic copy` or rclone).
- Client example: `restic -r rest:http://alice:PASSWORD@<tailscale-ip>:8000/alice init`.

The environment variables used (`DATA_DIRECTORY`, `PASSWORD_FILE`, `DISABLE_AUTHENTICATION`,
`OPTIONS`) are those of the upstream image's entrypoint (verified against its
`docker/entrypoint.sh`); I have not run this role against a live host.
