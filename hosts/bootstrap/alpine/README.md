# Consigliere on Alpine Linux

Alpine has no apt and no systemd (it uses `apk` and OpenRC), so the normal `bootstrap.sh` cannot run here. This setup does what the Unraid one does
(see [../unraid/README.md](../unraid/README.md)): the host keeps only Docker and Tailscale, and one long-lived container runs the reconcile loop every
~20 minutes through the host's Docker socket. Everything the framework does on the host itself is not done here.

It is meant for a small Docker host, for example a Proxmox LXC.

## What runs, and what does not

Runs: the container-based roles that the host's tags select, through `hosts/site-unraid.yml` (the entry playbook for every host of this kind):
`prop: [beszel]` (the Beszel agent), `feat: [arkeep]` (the Arkeep agent), `feat: [arcane]` (the Arcane agent), and compose-based apps.

Does not run: `baseline`, `tailscale`, `sops`, `docker`, `firewall` (you set up Docker and Tailscale once, below), and anything that is a native systemd
service or needs apt, among them the OpenTelemetry agent (`feat: [otel]`: no host logs or metrics from this host), `certwarden_agent` and
`restic_mirror`. Updates are the host's own: `apk upgrade` (not scheduled here).

## Set up

1. **On the Proxmox node** (for an LXC): the container needs nesting for Docker and the TUN device for Tailscale.

       pct set <id> --features nesting=1,keyctl=1
       # add to /etc/pve/lxc/<id>.conf, then restart the container:
       lxc.cgroup2.devices.allow: c 10:200 rwm
       lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file

2. **In the fleet repo**: add the host to `config/inventory/hosts.yml` (the key is the host name, which must equal its Tailscale name) and push.
3. **On the Alpine host, as root** (Alpine has no bash or curl until installed; the script is plain `sh`):

       apk add --no-cache curl
       curl -fsSLO https://raw.githubusercontent.com/almadon/Consigliere/main/hosts/bootstrap/alpine/bootstrap-alpine.sh
       NODE_NAME=<name> FRAMEWORK_REPO_URL=https://github.com/almadon/Consigliere.git \
       FLEET_CONFIG_REPO_URL=git@github.com:you/fleet.git sh bootstrap-alpine.sh

   The script installs Docker, Tailscale and a few tools with `apk` (the `community` repository must be enabled in `/etc/apk/repositories`), turns both
   services on at boot, and **stops if the host is not on the tailnet yet** with the `tailscale up` line to run. It never asks for an auth key. Run it again
   after joining. It then continues as the Unraid setup does: a read-only deploy key and an age key (printed; it waits for you), a check-only first run,
   and a prompt before the reconciler starts.
4. **On your admin machine**: `scripts/access.sh add-host <name> <age-public-key>`, `sync`, commit, push.

State lives in `/opt/consigliere` (`CONSIGLIERE_DIR` to change it); host-only settings go in `/opt/consigliere/vars.yml`.

## Day to day

    docker logs -f consigliere-reconcile       # what it is doing
    docker restart consigliere-reconcile       # run now

The reconciler's Docker CLI is the image's (`docker:29-cli`, see `../unraid/Dockerfile`); keep its major version in step with Alpine's `docker` package
(`apk info docker`).

## Notes

- Everything here is untested on a real Alpine host at the time of writing; the first run is the test.
- A Debian or Ubuntu LXC gets the full framework instead: use `bootstrap.sh` there.
