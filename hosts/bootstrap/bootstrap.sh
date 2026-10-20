#!/usr/bin/env bash
# One-time setup for a brand-new host: it has neither Ansible nor either
# repo yet, so reconcile.sh can't be the first step. Run this once, by hand
# or via cloud-init, then the systemd timer takes over (see reconcile.sh
# for what "either repo" means -- this framework repo + your own private
# fleet-config repo).
#
# Usage:
#   FRAMEWORK_REPO_URL=... FLEET_CONFIG_REPO_URL=git@github.com:you/fleet.git \
#   ./bootstrap.sh
#
# Access to the PRIVATE fleet-config repo is set up for you
# (ensure-access.sh): the host generates its own read-only deploy key and, if
# FLEET_CONFIG_REGISTER_TOKEN (a GitHub token allowed to manage that repo's
# deploy keys; used once, never stored) is set, registers it automatically --
# otherwise it prints the public key and waits for you to add it. To use a key
# you already have instead, pass FLEET_CONFIG_DEPLOY_KEY_FILE.
#
# Secrets are encrypted with sops to per-host age keys: this host generates its
# own key (ensure-age-key.sh), prints the public half, and you grant it its
# secrets from your admin machine (scripts/access.sh). No passwords are copied.
set -euo pipefail

# ---- Which kind of host is this? ------------------------------------------------------------------
# One entry point for every kind of host. Debian and Ubuntu continue below; the others hand over to
# their own setup, because they cannot run this one (no apt, no systemd, or a different init):
#   unraid  -> hosts/bootstrap/unraid/bootstrap-unraid.sh   (a self-scheduling container)
#   macos   -> macos/bootstrap/bootstrap.sh                 (launchd)
# CONSIGLIERE_PROFILE=debian|unraid|macos overrides the detection.
detect_profile() {
  if [ -n "${CONSIGLIERE_PROFILE:-}" ]; then echo "$CONSIGLIERE_PROFILE"; return; fi
  if [ -f /etc/unraid-version ]; then echo unraid
  elif [ "$(uname -s)" = Darwin ]; then echo macos
  elif [ -r /etc/os-release ] && grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then echo debian
  else echo unsupported
  fi
}
PROFILE="$(detect_profile)"
if [ "$PROFILE" != debian ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  # Hand over to the profile's script: the sibling file when run from a checkout, otherwise a fresh clone.
  handoff() {   # $1 = path of the script relative to the framework root
    if [ -n "$here" ] && [ -f "$here/../../$1" ]; then exec bash "$here/../../$1"; fi
    command -v git >/dev/null || { echo "ERROR: git is needed to fetch the $PROFILE setup" >&2; exit 1; }
    tmp="$(mktemp -d)"
    git clone --depth 1 "${FRAMEWORK_REPO_URL:-https://github.com/almadon/Consigliere.git}" "$tmp/framework" >&2 ||
      { echo "ERROR: could not fetch the framework repo" >&2; exit 1; }
    exec bash "$tmp/framework/$1"
  }
  case "$PROFILE" in
    unraid) echo "==> Unraid detected: using the container-based setup"; handoff hosts/bootstrap/unraid/bootstrap-unraid.sh ;;
    macos)  echo "==> macOS detected: using the launchd setup";          handoff macos/bootstrap/bootstrap.sh ;;
    *)
      echo "ERROR: this kind of host is not supported (profile: $PROFILE)." >&2
      [ -r /etc/os-release ] && echo "       OS: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")" >&2
      echo "       Supported: Debian and Ubuntu, Unraid, macOS. To force a profile: CONSIGLIERE_PROFILE=debian|unraid|macos" >&2
      exit 1 ;;
  esac
fi

# On a terminal, always show what will be used and let you change it (a value left
# exported in your shell would otherwise be used silently).
if [ -t 0 ]; then
  d="${FRAMEWORK_REPO_URL:-https://github.com/almadon/Consigliere.git}"
  read -r -p "Framework repo URL [$d]: " in; FRAMEWORK_REPO_URL="${in:-$d}"
  d="${FLEET_CONFIG_REPO_URL:-}"
  read -r -p "Your PRIVATE fleet repo URL (git@github.com:you/fleet.git)${d:+ [$d]}: " in; FLEET_CONFIG_REPO_URL="${in:-$d}"
fi
# Never let git ask for a username/password: the framework repo is public (no login),
# and the private fleet repo is read with a deploy key over SSH.
export GIT_TERMINAL_PROMPT=0
: "${FRAMEWORK_REPO_URL:?Set FRAMEWORK_REPO_URL to the git remote for this repo}"
FRAMEWORK_REPO_BRANCH="${FRAMEWORK_REPO_BRANCH:-}"   # empty = the remote default branch

: "${FLEET_CONFIG_REPO_URL:?Set FLEET_CONFIG_REPO_URL to your PRIVATE fleet-config repo}"
FLEET_CONFIG_REPO_BRANCH="${FLEET_CONFIG_REPO_BRANCH:-}"   # empty = the remote default branch

# The private repo is read with a per-host deploy key, which needs the SSH form. Accept
# the https URL you copy from GitHub and convert it.
case "$FLEET_CONFIG_REPO_URL" in
  https://github.com/*)
    FLEET_CONFIG_REPO_URL="git@github.com:${FLEET_CONFIG_REPO_URL#https://github.com/}"
    echo "Using the SSH form for the private repo: $FLEET_CONFIG_REPO_URL" ;;
esac

WORKDIR="/opt/fleet-reconcile"
CRED_DIR="/etc/fleet-reconcile"

# Paths (on this host, already copied over out-of-band) to the read-only
# deploy key for the fleet-config repo.
# Both get moved into $CRED_DIR with tight permissions; reconcile.sh reads
# them from there on every run.
FLEET_CONFIG_DEPLOY_KEY_FILE="${FLEET_CONFIG_DEPLOY_KEY_FILE:-}"

# Tailscale auth key: only needed if this host is not on the tailnet yet. Never
# stored; it lives in this process's environment for the first run only.
if [ -z "${TAILSCALE_AUTHKEY:-}" ] && [ -t 0 ] && ! (command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1); then
  read -rsp "Tailscale auth key (Enter to skip if this host is already on the tailnet): " TAILSCALE_AUTHKEY
  echo
fi
export TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

echo "==> Installing git and the base packages (ansible follows, once the framework is cloned)"
apt-get update
apt-get install -y git curl age sudo gnupg ca-certificates python3-apt

echo "==> Installing host-local credentials"
install -d -m 0700 "$CRED_DIR"
if [ -n "$FLEET_CONFIG_DEPLOY_KEY_FILE" ]; then
  install -m 0600 "$FLEET_CONFIG_DEPLOY_KEY_FILE" "$CRED_DIR/deploy_key"
fi

echo "==> Writing environment file for future reconciliation runs"
cat > /etc/fleet-reconcile.env <<EOF
FRAMEWORK_REPO_URL=$FRAMEWORK_REPO_URL
FRAMEWORK_REPO_BRANCH=$FRAMEWORK_REPO_BRANCH
FLEET_CONFIG_REPO_URL=$FLEET_CONFIG_REPO_URL
FLEET_CONFIG_REPO_BRANCH=$FLEET_CONFIG_REPO_BRANCH
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
HEARTBEAT_FAIL_URL="${HEARTBEAT_FAIL_URL:-}"
RECONCILE_MODE="${RECONCILE_MODE:-apply}"
EOF
chmod 600 /etc/fleet-reconcile.env

echo "==> Cloning framework repo (to get reconcile.sh)"
mkdir -p "$WORKDIR"
framework_fail() {
  echo "ERROR: could not get $FRAMEWORK_REPO_URL. The framework repo is public and needs no login, so this URL is wrong or unreachable (it lives at https://github.com/almadon/Consigliere.git). Fix it and re-run bootstrap.sh; nothing else needs cleaning up." >&2
  exit 1
}
if [ -d "$WORKDIR/framework/.git" ]; then
  # Re-run (e.g. after a wrong URL): point the existing checkout at the URL you gave now.
  git -C "$WORKDIR/framework" remote set-url origin "$FRAMEWORK_REPO_URL"
  git -C "$WORKDIR/framework" fetch origin || framework_fail
  git -C "$WORKDIR/framework" remote set-head origin --auto >/dev/null 2>&1 || true
  git -C "$WORKDIR/framework" reset --hard "origin/${FRAMEWORK_REPO_BRANCH:-HEAD}"
else
  rm -rf "$WORKDIR/framework"
  git clone ${FRAMEWORK_REPO_BRANCH:+--branch "$FRAMEWORK_REPO_BRANCH"} "$FRAMEWORK_REPO_URL" "$WORKDIR/framework" || framework_fail
fi

echo "==> Installing sops (pinned, checksum-verified)"
"$WORKDIR/framework/hosts/bootstrap/install-ansible.sh"
"$WORKDIR/framework/hosts/bootstrap/install-sops.sh"

echo "==> Making sure this host can read the private fleet-config repo"
CRED_DIR="$CRED_DIR" FLEET_CONFIG_REPO_URL="$FLEET_CONFIG_REPO_URL" \
  "$WORKDIR/framework/hosts/bootstrap/ensure-access.sh"

echo "==> This host's secrets identity (age key)"
CRED_DIR="$CRED_DIR" FRAMEWORK_DIR="$WORKDIR/framework" \
  "$WORKDIR/framework/hosts/bootstrap/ensure-age-key.sh"

set -a
source /etc/fleet-reconcile.env
set +a

# Nothing is applied until you have seen what would change: the first run is a
# check-only pass (--check --diff). Applying and enabling the timer are explicit.
echo "==> First run: CHECK ONLY (nothing on this host is changed)"
if ! RECONCILE_MODE=check "$WORKDIR/framework/hosts/bootstrap/reconcile.sh"; then
  echo "WARN: the check pass reported errors (on a brand-new host some are expected: e.g. Docker isn't installed yet, so container tasks can't be simulated). Read the output above." >&2
fi
if [ -t 0 ]; then
  read -r -p "Apply these changes for real and enable the timer? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing applied, timer not installed. Re-run bootstrap.sh when ready."; exit 0; }
elif [ "${BOOTSTRAP_APPLY:-}" != yes ]; then
  echo "Non-interactive run: nothing applied, timer not installed. Re-run with BOOTSTRAP_APPLY=yes to apply."
  exit 0
fi
echo "==> Applying"
RECONCILE_PRECHECK=0 "$WORKDIR/framework/hosts/bootstrap/reconcile.sh"

echo "==> Installing systemd timer for future reconciliation runs"
cp "$WORKDIR/framework/hosts/bootstrap/fleet-reconcile.service" /etc/systemd/system/fleet-reconcile.service
cp "$WORKDIR/framework/hosts/bootstrap/fleet-reconcile.timer" /etc/systemd/system/fleet-reconcile.timer

systemctl daemon-reload
systemctl enable --now fleet-reconcile.timer

echo "==> Done. Reconciliation now runs automatically every ~20min."
echo "    Check status with: systemctl status fleet-reconcile.timer"
