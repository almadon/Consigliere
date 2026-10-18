#!/usr/bin/env bash
# Entrypoint of the Unraid reconciler container: runs reconcile.sh now and then every
# RECONCILE_INTERVAL seconds (plus up to RECONCILE_JITTER), forever. The container is started with
# `--restart always`, so Docker brings it back with the daemon after a reboot and no cron or boot
# script is needed on the host.
#
# One run only (used by bootstrap for the first check):  consigliere-loop once
set -uo pipefail

: "${RECONCILE_WORKDIR:?RECONCILE_WORKDIR is required (the persistent work directory)}"
: "${FRAMEWORK_REPO_URL:?FRAMEWORK_REPO_URL is required}"
INTERVAL="${RECONCILE_INTERVAL:-1200}"
JITTER="${RECONCILE_JITTER:-180}"
FRAMEWORK_DIR="$RECONCILE_WORKDIR/framework"
export GIT_TERMINAL_PROMPT=0

run_once() {
  # The framework repo is public: fetch it first so reconcile.sh itself is current.
  if [ ! -d "$FRAMEWORK_DIR/.git" ]; then
    mkdir -p "$RECONCILE_WORKDIR"
    git clone ${FRAMEWORK_REPO_BRANCH:+--branch "$FRAMEWORK_REPO_BRANCH"} "$FRAMEWORK_REPO_URL" "$FRAMEWORK_DIR" || return 1
  fi
  bash "$FRAMEWORK_DIR/hosts/bootstrap/reconcile.sh"
}

if [ "${1:-}" = once ]; then
  run_once
  exit $?
fi

echo "consigliere reconciler started: every ${INTERVAL}s (+0-${JITTER}s), mode ${RECONCILE_MODE:-apply}"
while true; do
  echo "==> run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if run_once; then echo "==> run finished OK"; else echo "==> run FAILED (exit $?); retrying next cycle"; fi
  sleep $(( INTERVAL + RANDOM % (JITTER + 1) ))
done
