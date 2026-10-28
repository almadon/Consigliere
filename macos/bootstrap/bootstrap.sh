#!/usr/bin/env bash
# One-time setup for a new Mac: clones this (public) framework repo,
# installs Ansible via Homebrew if needed, runs one immediate apply, then
# installs the launchd agent so future runs happen on schedule (macOS has
# no systemd - this is the closest equivalent, see com.fleet.reconcile.plist).
#
# No private fleet-config repo is wired in on macOS yet -- the `baseline`
# role doesn't need secrets or site-specific vars today. If that changes,
# follow the two-repo pattern in hosts/bootstrap/reconcile.sh instead of
# bolting something ad hoc on here.
#
# Usage: FRAMEWORK_REPO_URL=... ./bootstrap.sh
set -euo pipefail

: "${FRAMEWORK_REPO_URL:?Set FRAMEWORK_REPO_URL to the git remote for this repo}"
FRAMEWORK_REPO_DIR="${FRAMEWORK_REPO_DIR:-$HOME/.fleet-framework}"

if ! command -v brew &>/dev/null; then
  echo "==> Homebrew not found - install it first: https://brew.sh"
  exit 1
fi

echo "==> Installing ansible"
brew install ansible git

echo "==> Cloning framework repo to $FRAMEWORK_REPO_DIR"
if [ -d "$FRAMEWORK_REPO_DIR/.git" ]; then
  git -C "$FRAMEWORK_REPO_DIR" pull --ff-only
else
  git clone "$FRAMEWORK_REPO_URL" "$FRAMEWORK_REPO_DIR"
fi

echo "==> Running first apply"
(cd "$FRAMEWORK_REPO_DIR" && ansible-playbook -i localhost, macos/site.yml)

echo "==> Installing launchd agent for future reconciliation runs"
sed "s|%FRAMEWORK_REPO_DIR%|$FRAMEWORK_REPO_DIR|" \
  "$(dirname "$0")/com.fleet.reconcile.plist" > "$HOME/Library/LaunchAgents/com.fleet.reconcile.plist"

launchctl unload "$HOME/Library/LaunchAgents/com.fleet.reconcile.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.fleet.reconcile.plist"

echo "==> Done. Reconciliation now runs automatically every ~20min."
echo "    Logs: /tmp/fleet-reconcile.log"
