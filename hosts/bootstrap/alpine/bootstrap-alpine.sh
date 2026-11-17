#!/bin/sh
# Alpine Linux (a Proxmox LXC, a small VM): get Docker and Tailscale in place, then hand over to the container-based
# reconciler that Unraid uses (hosts/bootstrap/unraid/). Alpine has neither apt nor systemd, so the normal bootstrap.sh
# cannot run here; see README.md in this folder for what that means for the roles.
#
# POSIX sh on purpose: a fresh Alpine has no bash. Run as root:
#   apk add --no-cache curl
#   curl -fsSLO https://raw.githubusercontent.com/almadon/Consigliere/main/hosts/bootstrap/alpine/bootstrap-alpine.sh
#   NODE_NAME=<name in hosts.yml> \
#   FRAMEWORK_REPO_URL=https://github.com/almadon/Consigliere.git \
#   FLEET_CONFIG_REPO_URL=git@github.com:you/fleet.git \
#   sh bootstrap-alpine.sh
#
# Safe to run again. It installs packages, turns the Docker and Tailscale services on at boot, and stops with instructions if the
# host is not on the tailnet yet (joining is yours: an auth key is a credential, so this script never asks for one). The rest
# (deploy key, age key, a check-only first run, then starting the reconciler) is bootstrap-unraid.sh.
# Optional: CONSIGLIERE_DIR (default /opt/consigliere).
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -f /etc/alpine-release ] || die "this is not Alpine (no /etc/alpine-release)"

# ---- Packages -----------------------------------------------------------------------------------------------
# docker and tailscale live in Alpine's community repository: it must be enabled in /etc/apk/repositories.
echo "==> Installing packages"
apk add --no-cache bash git curl jq openssh-client ca-certificates tzdata docker docker-cli-compose tailscale >/dev/null ||
  die "apk could not install the packages. Is the community repository enabled? (/etc/apk/repositories needs a line ending in /community)"
# A bind mount of a missing file would make Docker create a directory in its place; the reconciler mounts /etc/localtime.
[ -e /etc/localtime ] || ln -s /usr/share/zoneinfo/UTC /etc/localtime

# ---- Host name ----------------------------------------------------------------------------------------------
# Until the host is on the tailnet, the fleet identifies it by this name (it must equal the key in hosts.yml).
if [ -n "${NODE_NAME:-}" ]; then
  echo "$NODE_NAME" > /etc/hostname
  hostname "$NODE_NAME"
fi

# ---- Tailscale ----------------------------------------------------------------------------------------------
# An LXC needs the TUN device passed in. This is set on the Proxmox node, not here.
if [ ! -c /dev/net/tun ]; then
  cat >&2 <<'EOF'
ERROR: /dev/net/tun is missing, so Tailscale cannot run in this container. On the Proxmox node, stop the container,
add these two lines to /etc/pve/lxc/<id>.conf, start it again, and re-run this script:

  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  exit 1
fi
rc-update add tailscale default >/dev/null 2>&1 || true
rc-service tailscale start >/dev/null 2>&1 || rc-service tailscale restart >/dev/null 2>&1 || true

# ---- Docker -------------------------------------------------------------------------------------------------
rc-update add docker boot >/dev/null 2>&1 || true
rc-service docker start >/dev/null 2>&1 || true
i=0
while ! docker info >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 15 ]; then
    cat >&2 <<'EOF'
ERROR: the Docker daemon did not start. In a Proxmox LXC Docker needs nesting: on the node, run
  pct set <id> --features nesting=1,keyctl=1
then restart the container and run this script again. (rc-service docker status and /var/log/docker.log say more.)
EOF
    exit 1
  fi
  sleep 2
done

# ---- On the tailnet? ----------------------------------------------------------------------------------------
if ! tailscale status >/dev/null 2>&1; then
  cat >&2 <<EOF
This host is not on the tailnet yet. Join it (with a tagged auth key from your Tailscale admin console), then run this script again:

  tailscale up --hostname=${NODE_NAME:-$(hostname)} --auth-key=<key>

EOF
  exit 1
fi

# ---- Hand over to the container-based reconciler ------------------------------------------------------------
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
target="unraid/bootstrap-unraid.sh"
export CONSIGLIERE_DIR="${CONSIGLIERE_DIR:-/opt/consigliere}"
export CONSIGLIERE_GENERIC=alpine
if [ -n "$here" ] && [ -f "$here/../$target" ]; then exec bash "$here/../$target"; fi
tmp="$(mktemp -d)"
git clone --depth 1 "${FRAMEWORK_REPO_URL:-https://github.com/almadon/Consigliere.git}" "$tmp/framework" >&2 ||
  die "could not fetch the framework repo"
exec bash "$tmp/framework/hosts/bootstrap/$target"
