#!/usr/bin/env bash
# One-time setup of the Consigliere reconciler on an Unraid server (safe to re-run).
#
# Unraid cannot run the normal bootstrap: no apt, no systemd, and a root filesystem in RAM that
# forgets everything at reboot (and Unraid 8 changes the base OS again). So nothing is installed on
# the host. This builds one container image, keeps its state in an appdata folder, and starts a single
# self-scheduling container (--restart always) that runs reconcile.sh every ~20 minutes using the
# host's Docker socket. Read README.md first.
#
# Usage (as root, on the Unraid server):
#   FRAMEWORK_REPO_URL=https://github.com/almadon/Consigliere.git \
#   FLEET_CONFIG_REPO_URL=git@github.com:you/fleet.git \
#   bash bootstrap-unraid.sh
# Optional: CONSIGLIERE_DIR (default /mnt/user/appdata/consigliere), FLEET_CONFIG_REGISTER_TOKEN
# (registers this host's read-only deploy key on GitHub for you, used once, never stored),
# RECONCILE_INTERVAL / RECONCILE_JITTER (seconds), HEARTBEAT_URL / HEARTBEAT_FAIL_URL.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
command -v docker >/dev/null || die "docker not found (is the Docker service enabled in Unraid's settings?)"
docker info >/dev/null 2>&1 || die "the Docker daemon is not running (start the array and enable Docker first)"
command -v git >/dev/null || die "git not found"
[ -f /etc/unraid-version ] || echo "NOTE: /etc/unraid-version not found; continuing, but this script is written for Unraid." >&2

# On a terminal, show what will be used and let you change it.
if [ -t 0 ]; then
  d="${FRAMEWORK_REPO_URL:-https://github.com/almadon/Consigliere.git}"
  read -r -p "Framework repo URL [$d]: " in; FRAMEWORK_REPO_URL="${in:-$d}"
  d="${FLEET_CONFIG_REPO_URL:-}"
  read -r -p "Your PRIVATE fleet repo URL (git@github.com:you/fleet.git)${d:+ [$d]}: " in; FLEET_CONFIG_REPO_URL="${in:-$d}"
fi
: "${FRAMEWORK_REPO_URL:?Set FRAMEWORK_REPO_URL}"
: "${FLEET_CONFIG_REPO_URL:?Set FLEET_CONFIG_REPO_URL to your PRIVATE fleet-config repo}"
case "$FLEET_CONFIG_REPO_URL" in
  https://github.com/*) FLEET_CONFIG_REPO_URL="git@github.com:${FLEET_CONFIG_REPO_URL#https://github.com/}"
                        echo "Using the SSH form for the private repo: $FLEET_CONFIG_REPO_URL" ;;
esac

DIR="${CONSIGLIERE_DIR:-/mnt/user/appdata/consigliere}"
IMAGE=consigliere-reconcile
NAME=consigliere-reconcile

# The Tailscale plugin provides the CLI and the daemon's socket; the container reads them to learn this
# host's tailnet name and address (its inventory key). Joining the tailnet stays the plugin's job.
TS_CLI="$(readlink -f "$(command -v tailscale 2>/dev/null || true)" 2>/dev/null || true)"
[ -x "$TS_CLI" ] && [ -S /var/run/tailscale/tailscaled.sock ] ||
  die "the Tailscale CLI/socket was not found. Install Unraid's Tailscale plugin and join the tailnet (with a tagged auth key) first."
tailscale status >/dev/null 2>&1 || die "this server is not connected to the tailnet yet (tailscale status fails)"
SELF="$(tailscale status --json | jq -r '.Self.HostName' | tr 'A-Z' 'a-z')"
echo "==> This host is '$SELF' on the tailnet; its entry in the fleet's hosts.yml must use that name."

echo "==> Preparing $DIR"
install -d -m 0755 "$DIR" "$DIR/work" "$DIR/data"
install -d -m 0700 "$DIR/cred"

if [ ! -d "$DIR/work/framework/.git" ]; then
  echo "==> Cloning the framework (public)"
  git clone "$FRAMEWORK_REPO_URL" "$DIR/work/framework"
else
  git -C "$DIR/work/framework" remote set-url origin "$FRAMEWORK_REPO_URL"
  git -C "$DIR/work/framework" fetch -q origin
  git -C "$DIR/work/framework" remote set-head origin --auto >/dev/null 2>&1 || true
  git -C "$DIR/work/framework" reset -q --hard origin/HEAD
fi

echo "==> Writing settings"
( umask 077
  cat > "$DIR/reconcile.env" <<ENV
FRAMEWORK_REPO_URL=$FRAMEWORK_REPO_URL
FLEET_CONFIG_REPO_URL=$FLEET_CONFIG_REPO_URL
FRAMEWORK_REPO_BRANCH=${FRAMEWORK_REPO_BRANCH:-}
FLEET_CONFIG_REPO_BRANCH=${FLEET_CONFIG_REPO_BRANCH:-}
RECONCILE_WORKDIR=$DIR/work
RECONCILE_CRED_DIR=$DIR/cred
RECONCILE_PLAYBOOK=site-unraid.yml
RECONCILE_MODE=apply
RECONCILE_INTERVAL=${RECONCILE_INTERVAL:-1200}
RECONCILE_JITTER=${RECONCILE_JITTER:-180}
ANSIBLE_EXTRA_ARGS=-e @$DIR/vars.yml
HEARTBEAT_URL=${HEARTBEAT_URL:-}
HEARTBEAT_FAIL_URL=${HEARTBEAT_FAIL_URL:-}
ENV
)
# Where the roles keep their compose files and data. The same path is mounted inside the container, so
# the paths in the generated compose files are valid for the host's Docker daemon too.
if [ ! -f "$DIR/vars.yml" ]; then
  cat > "$DIR/vars.yml" <<VARS
---
# Settings that only make sense on this Unraid host. Edit freely; this file is not overwritten.
common_dir: $DIR/data/common
arkeep_agent_dir: $DIR/data/arkeep-agent
firewall_manage: false
VARS
fi

echo "==> Building the reconciler image (first time takes a few minutes)"
docker build -q -t "$IMAGE" -f "$DIR/work/framework/hosts/bootstrap/unraid/Dockerfile" "$DIR/work/framework/hosts/bootstrap" >/dev/null
echo "    image $IMAGE built"

DOCKER_ARGS=(
  --network host --uts host
  -v /var/run/docker.sock:/var/run/docker.sock
  -v "$DIR:$DIR"
  -v "$TS_CLI:/usr/local/bin/tailscale:ro"
  -v /var/run/tailscale:/var/run/tailscale
  -v /etc/localtime:/etc/localtime:ro
  --env-file "$DIR/reconcile.env"
  -e CRED_DIR="$DIR/cred" -e FRAMEWORK_DIR="$DIR/work/framework"
)
[ -n "${FLEET_CONFIG_REGISTER_TOKEN:-}" ] && DOCKER_ARGS+=(-e FLEET_CONFIG_REGISTER_TOKEN)
TTY=(); [ -t 0 ] && TTY=(-it)

echo "==> Giving this host read access to your private fleet repo, and its own secrets identity"
docker run --rm "${TTY[@]}" "${DOCKER_ARGS[@]}" --entrypoint bash "$IMAGE" -c '
  set -e
  bash "$FRAMEWORK_DIR/hosts/bootstrap/ensure-access.sh"
  bash "$FRAMEWORK_DIR/hosts/bootstrap/ensure-age-key.sh"'

echo "==> First run: CHECK ONLY (nothing on this server is changed)"
docker run --rm "${TTY[@]}" "${DOCKER_ARGS[@]}" -e RECONCILE_MODE=check "$IMAGE" once ||
  echo "WARN: the check pass reported errors. Read the output above before starting the reconciler." >&2

start=n
if [ -t 0 ]; then
  read -r -p "Start the reconciler now (applies changes, then repeats every ~$(( ${RECONCILE_INTERVAL:-1200} / 60 )) min)? [y/N] " start
elif [ "${BOOTSTRAP_APPLY:-}" = yes ]; then
  start=y
fi
if [ "$start" = y ] || [ "$start" = Y ]; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --restart always "${DOCKER_ARGS[@]}" "$IMAGE" >/dev/null
  echo "==> Started container '$NAME' (restart policy: always, so it returns after a reboot)."
  echo "    Logs: docker logs -f $NAME"
else
  echo "Not started. Start it later by re-running this script."
fi
