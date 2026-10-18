# Consigliere on Unraid

Unraid is not Debian: no apt, no systemd, and a root filesystem that lives in RAM and resets at every
reboot. So the normal `bootstrap.sh` cannot run here, and nothing is installed on the server. Instead:

- one container image (`consigliere-reconcile`) carries Ansible, git, sops, age and the Docker CLI;
- one long-lived container runs `reconcile.sh` every ~20 minutes (`RECONCILE_INTERVAL`, `RECONCILE_JITTER`),
  using the host's Docker socket;
- its state lives in a normal appdata folder (`/mnt/user/appdata/consigliere`), which persists.

`restart: always` brings the container back after a reboot, so there is no cron entry and no edit to
`/boot/config/go`. That is on purpose: Unraid 8 changes the base OS to Fedora (Universal Blue's uCore) and
the announcement says nothing about `go`, systemd or which paths persist. A container needs only a Docker
socket and a folder.

## What runs

`hosts/site-unraid.yml` runs only what the host's tags select (`feat: [arkeep]` is the Arkeep agent,
`prop: [beszel]` the Beszel agent), and only container-based roles are suitable. These are NOT run here, on
purpose: baseline, tailscale, sops, docker and firewall (Unraid manages its own packages, Docker and
network; the Tailscale plugin joins the tailnet). Roles that use systemd or apt (for example
`certwarden_agent`, `restic_mirror`) do not work on Unraid. The docker guard (nftables) is not applied either:
keep ports unpublished or bound to the Tailscale address.

## Set up (as root on the server)

1. Install and connect Unraid's **Tailscale plugin** (use a tagged auth key). Its CLI and socket are read by the
   container to learn the host's tailnet name, which must equal the key in `hosts.yml`.
2. Add the host to your fleet's `config/inventory/hosts.yml` (`feat: [arkeep]`, `type: unraid`) and push.
3. Run:

       curl -fsSLO https://raw.githubusercontent.com/almadon/Consigliere/main/hosts/bootstrap/unraid/bootstrap-unraid.sh
       FRAMEWORK_REPO_URL=https://github.com/almadon/Consigliere.git \
       FLEET_CONFIG_REPO_URL=git@github.com:you/fleet.git \
       bash bootstrap-unraid.sh

   It builds the image, gives the host a read-only deploy key and its own age key (it prints both and waits
   for you), does a check-only first run, and asks before starting the container.
4. On your admin machine: `scripts/access.sh add-host <name> <age-public-key>`, `sync`, commit, push.

## Day to day

    docker logs -f consigliere-reconcile                 # what it is doing
    docker restart consigliere-reconcile                 # run now
    docker run --rm -it ... -e RECONCILE_MODE=check consigliere-reconcile once   # report-only (see bootstrap-unraid.sh)

The framework and fleet repos update themselves on every run. The image changes rarely: to rebuild it (new
Ansible, a new sops pin), re-run `bootstrap-unraid.sh`; it keeps your keys and settings.

Host-only settings go in `/mnt/user/appdata/consigliere/vars.yml` (directories for compose files and data,
`firewall_manage: false`); they are passed to Ansible as extra variables.

## Notes

- A container started by the roles shows up in Unraid's Docker tab but is managed by Ansible: change it in the
  fleet repo, not in the Unraid UI.
- `restart: unless-stopped` containers may not return after an Unraid reboot (shutdown counts as a stop), so the
  reconciler itself uses `--restart always`. Containers that the roles start follow the role's own policy.
- A container with a name a role wants (for example an old `arkeep-agent`) blocks the first run with
  instructions; `docker_adopt_existing: true` in the host's vars removes it (its volumes are kept).
- Untested on Unraid 8. The design depends only on Docker, the Tailscale CLI/socket and a persistent folder.
