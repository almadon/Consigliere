# pbs_server

A [Proxmox Backup Server](https://www.proxmox.com/en/products/proxmox-backup-server) in Docker (community image
`ayufan/proxmox-backup-server`), set up to **pull** a primary PBS's backups so the VM backups exist in a second place. Run it on a host
tagged `util: [pbs]`. Not an Arkeep job: PBS stores deduplicated, compressed chunks, so a restic copy of its datastore would be slow
and gain nothing; PBS's own sync is incremental and verifiable.

- **Secret** `pbs.server` (`config/secrets/pbs/server.yml`): `pbs_server_admin_password` and `pbs_server_remote_secrets`
  (`{<remote name>: "<API token secret>"}`). `scripts/pbs.sh init` makes it with a generated admin password.
- **Listens** on the host's Tailscale address, port 8007, so it is not reachable from anywhere else. The certificate is PBS's own
  (self-signed). To serve it under a real name, put a Traefik route in front with `insecure: true`.
- **Datastores, remotes and pull jobs** are plain fleet vars (`pbs_server_datastores`, `pbs_server_remotes`, `pbs_server_sync_jobs`) and
  are created once: changing one that exists is done in the PBS UI. A prune job and a weekly garbage collection are made per datastore.
- **Pull only**: the remote is a read-only API token on the primary; nothing here can change the primary. Jobs are made with
  `remove-vanished` off, so what the primary prunes or loses stays here (a last resort grows; the prune job on this side sets how far back).
- **Ownership**: PBS runs as uid 34 and refuses to start (on some hosts) when its config, state or datastore directories belong to
  anyone else; the role creates them with that numeric owner.
- **Admin password**: the image starts with a published default. The first run changes it to the secret's value through PBS's API
  (the command-line `user update --password` does not take effect in this image). If PBS accepts neither, the run stops and says so.
- **Where the data goes**: `pbs_server_data_dir` (default `/srv/pbs`), mounted at `/backups`. On a host whose data disk also holds
  restic repositories, use a directory beside them and list it in the restic mirror's `restic_mirror_excludes`.
- Tested: the CLI sequence (password, datastore, prune job, remote, pull job) against the image; the full role is applied with a
  check run first.
