# garage

[Garage](https://garagehq.deuxfleurs.fr): a small S3-compatible object store, for services that want S3 (Outline
attachments, Tududi, ...). One node (replication 1), the S3 API on the host's Tailscale address, pinned image
(`garage_version`).

- **Secret** `garage.server` (`garage_rpc_secret`, 64 hex characters): `scripts/garage.sh init` in the fleet repo creates it
  and tags the host `util: [garage]`.
- **Disk:** on a host with a dedicated data disk (`data_disk_device` in the host's vars, see the `data_disk` role) set
  `garage_data_dir: /srv/bulk/garage` so the data blocks live there. A blank disk gets a filesystem; one that already holds a
  filesystem is never touched (the run fails instead). Metadata (`garage_meta_dir`, a small database) stays on the root disk.
- **First run** puts the node into the cluster layout with `garage_capacity` (set it a little under the disk size) and zone
  `garage_zone`. Changing the capacity later is done by hand: `docker exec garage /garage layout assign -c <size> <node id>`
  then `layout apply --version <n+1>`.
- **Buckets and keys:** declare `garage_buckets` (name, optional `max_size` / `max_objects`, and keys with `read`/`write`/`owner`);
  the role creates what is missing and never deletes anything. Garage generates the keys. Read one with

      docker exec garage /garage key info <key-name> --show-secret

  and give the app: endpoint `http://<tailscale-ip>:3900` (or `http://garage:3900` on a shared Docker network, `garage_network`),
  region `garage`, **path-style** addressing, the key id and secret.
- **Web UI:** the community [garage-webui](https://github.com/khairul169/garage-webui) (MIT, pinned `garage_webui_version`) runs next to Garage in the same
  compose project and talks to Garage's admin API, which is enabled inside the compose network only (port 3903 is never published). It shows cluster
  status, buckets and keys, and lets you browse objects. It is published on the Tailscale address (`garage_webui_port`, default 3909) for a reverse
  proxy to front. Its only sign-in is basic (user and bcrypt hash), so keep it off the open internet: restrict the route to the tailnet. Both the
  admin API and the UI need values in the secret `garage.server`: `garage_admin_token` and `garage_webui_auth` (`user:bcrypt hash`, from
  `htpasswd -nbBC 10 admin 'password'`); `scripts/garage.sh webui` in the fleet repo adds them to an existing secret.
  Set `garage_webui_enabled: false` and/or `garage_admin_enabled: false` to run without them.
- **Snapshots:** `metadata_auto_snapshot_interval` (default 6h) makes consistent copies of the metadata database under
  `garage_meta_dir/snapshots`. Back those up (and the data directory) with Arkeep; copying live files alone is not consistent.
- **Not public:** nothing is published beyond the Tailscale address. To expose S3 publicly, add a Traefik route to the host.

Tested against Garage 2.4.1 and web UI 1.1.0 (login, a wrong password refused, cluster and bucket data read through it): check, apply, check, apply (the last two change nothing), a write and read with a generated key,
and a second bucket refused to that key.
