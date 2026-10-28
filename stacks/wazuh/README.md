# Wazuh - fleet security monitoring

Manager + indexer + dashboard, for the fleet-wide malware/rootkit
detection and file-integrity monitoring described in
[VISION.md](../../VISION.md) ("Security posture / malware detection -
moving to Wazuh"). Agents are enrolled separately by
`hosts/roles/wazuh_agent/` on every other host in the fleet.

## What's here

`vendor/` is the official [wazuh/wazuh-docker](https://github.com/wazuh/wazuh-docker)
repo, added as a **git submodule pinned to `v4.14.7`** (the current stable
tag as of 2026-08-21 - verify this is still current before deploying;
`main` was already tracking an unreleased 5.x line when this was pinned).
It's vendored rather than hand-transcribed here deliberately: this compose
setup involves TLS cert generation and several tightly version-coupled
config files (`config/wazuh_indexer/`, `config/wazuh_cluster/`), and
copying it by hand risks drifting from something upstream actively
maintains. Consigliere points at `vendor/single-node/` as-is rather than forcing
it into the `stacks/<service>/docker-compose.yml` convention the rest of
`stacks/` uses - see the exception noted in [stacks/README.md](../README.md).

## Deploying

Run all of this **on the host tagged the `wazuh_server` group** - that tag is
what makes `hosts/roles/wazuh_server` apply the `vm.max_map_count=262144`
sysctl the indexer requires (OpenSearch needs more virtual memory areas
than Linux's default 65530 allows). Tag the host in Tailscale first, run
`ansible-pull` (or wait for its scheduled run) so that prerequisite lands,
*then* do the following:

```bash
git submodule update --init stacks/wazuh/vendor
cd stacks/wazuh/vendor/single-node

# One-time: generates self-signed certs into config/wazuh_indexer_ssl_certs/
docker compose -f generate-indexer-certs.yml run --rm generator

docker compose up -d
```

The indexer takes about a minute to come up on first boot. Dashboard is
reachable at `https://<manager-tailscale-addr>` once it's healthy.

## Before this touches anything but localhost: rotate the default passwords

The vendored compose file ships Wazuh's documented **default** credentials
in plaintext (`admin` / `SecretPassword` for the indexer/dashboard,
`wazuh-wui` / `MyS3cr37P450r.*-` for the manager API) - fine for a first
boot to confirm it works, not fine to leave running. As of 2026-08-21,
Wazuh's documented procedure (single-node, [changing-default-password.html](https://documentation.wazuh.com/current/deployment-options/docker/changing-default-password.html)):

1. Log out of the dashboard (clears session cookies).
2. Edit `vendor/single-node/docker-compose.yml`: replace the password
   environment variables with new ones (escape literal `$` as `$$`).
3. Generate a password hash inside the indexer image:
   ```bash
   docker run --rm -ti wazuh/wazuh-indexer:4.14.7 \
     bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
   ```
4. Put that hash into `vendor/single-node/config/wazuh_indexer/internal_users.yml`
   for the relevant user.
5. `docker compose down && docker compose up -d`, then apply the security
   config from inside the indexer container via `securityadmin.sh` (see
   the linked doc for the exact invocation - it takes cert paths that are
   worth copying precisely rather than retyped from memory).
6. For the manager API (`wazuh-wui`) password specifically: also update
   `config/wazuh_dashboard/wazuh.yml`'s API password to match.

Password rule: 8–64 characters, at least one uppercase, one lowercase, one
number, one symbol.

## Wiring it into the console

No code changes needed - add the dashboard URL as one of the `Dashboards`
entries in this machine's Outline doc (see
[console/README.md](../../console/README.md)'s table convention) and it
shows up as a tile link like anything else. This is a nice small proof
that the provider abstraction and widget design pay off: a whole new
service didn't need a new widget.

## Status

Scaffolded, not deployed. `vm.max_map_count` prerequisite role
(`hosts/roles/wazuh_server`) and the `wazuh_server` inventory group are in
place; the submodule is pinned; the agent side
(`hosts/roles/wazuh_agent`) is rewritten to enroll against
`wazuh_server_addr`. None of this has been run against a live host yet.
