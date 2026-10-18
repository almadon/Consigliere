#!/usr/bin/env bash
# Replaces a bare `ansible-pull` with a two-repo reconciliation:
#
#   1. This framework repo (public, generic): the role library, a default
#      playbook, and a one-host inventory script. No secrets, no taxonomy,
#      nothing site-specific -- usable by anyone running their own fleet.
#   2. A private "fleet-config" repo (yours) that says what *you* want out of
#      the framework and holds your secrets. Under config/ it provides:
#        inventory/hosts.yml    REQUIRED  your host table: each host (by its
#                                         Tailscale hostname) and its values
#        inventory/groups.yml   REQUIRED  turns those values into groups
#        tags/<dim>/<value>.yml optional  what each util:/feat: tag runs (roles,
#                                         task files); overrides hosts/tags/
#        vars/group/, vars/host/ REQUIRED  variables; secrets are sops-encrypted
#        site.yml               optional  which roles run where (default: the
#                                         framework's hosts/site.yml)
#        roles/                 optional  your own site-specific roles/apps
#      (runbooks, stacks and the like also live there, but need no logic here.)
#      See consigliere-fleet-template/ for the expected shape.
#
# This script clones/updates both, assembles a throwaway run directory from
# them, and runs the playbook against *this host only* (each host reconciles
# itself). Run on a schedule via fleet-reconcile.timer, installed by
# bootstrap.sh. Every apply is preceded by a check pass that must succeed
# (RECONCILE_MODE=check for report-only; see below). Extra ansible-playbook flags
# can be passed through ANSIBLE_EXTRA_ARGS.
set -euo pipefail

# Unattended runs must never wait on a credentials prompt: the framework is public and
# the private repo uses a deploy key.
export GIT_TERMINAL_PROMPT=0

: "${FRAMEWORK_REPO_URL:?Set FRAMEWORK_REPO_URL to the git remote for this repo}"
FRAMEWORK_REPO_BRANCH="${FRAMEWORK_REPO_BRANCH:-}"   # empty = the remote default branch

: "${FLEET_CONFIG_REPO_URL:?Set FLEET_CONFIG_REPO_URL to your PRIVATE fleet-config repo}"
FLEET_CONFIG_REPO_BRANCH="${FLEET_CONFIG_REPO_BRANCH:-}"   # empty = the remote default branch

# Optional heartbeat so a host that fails or silently stops reconciling is
# noticed. HEARTBEAT_URL is pinged on success; HEARTBEAT_FAIL_URL on failure
# (defaults to "$HEARTBEAT_URL/fail", the healthchecks.io convention; for
# Uptime Kuma push monitors set both explicitly, e.g. ...?status=up and
# ...?status=down). Failures to ping never fail the run itself.
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
HEARTBEAT_FAIL_URL="${HEARTBEAT_FAIL_URL:-${HEARTBEAT_URL:+$HEARTBEAT_URL/fail}}"
heartbeat() {
  [ -n "$1" ] || return 0
  curl -fsS -m 10 --retry 2 -o /dev/null "$1" || true
}
trap 'rc=$?; if [ "$rc" -eq 0 ]; then heartbeat "$HEARTBEAT_URL"; else heartbeat "$HEARTBEAT_FAIL_URL"; fi' EXIT

WORKDIR="${RECONCILE_WORKDIR:-/opt/fleet-reconcile}"
FRAMEWORK_DIR="$WORKDIR/framework"
FLEET_CONFIG_DIR="$WORKDIR/fleet-config"
# Where, inside the private repo, the vars live: <subdir>/vars/group and
# <subdir>/vars/host (see consigliere-fleet-template/).
FLEET_CONFIG_SUBDIR="${FLEET_CONFIG_SUBDIR:-config}"

# Host-local credentials, installed once by bootstrap.sh -- never inside
# either repo. The deploy key is read-only access to the fleet-config repo
# only; age.key is this host's private key for decrypting its sops secrets.
CRED_DIR="${RECONCILE_CRED_DIR:-/etc/fleet-reconcile}"
DEPLOY_KEY="$CRED_DIR/deploy_key"
AGE_KEY_FILE="$CRED_DIR/age.key"

mkdir -p "$WORKDIR"

# An empty branch means "whatever the remote's default branch is", so a repo
# whose default is master or main works without configuration.
sync_repo() {
  local url="$1" branch="$2" dir="$3"
  if [ -d "$dir/.git" ]; then
    # Follow the configured URL (fixes a repo that was cloned from a wrong or old one).
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch origin
    if [ -n "$branch" ]; then
      git -C "$dir" checkout "$branch"
      git -C "$dir" reset --hard "origin/$branch"
    else
      git -C "$dir" remote set-head origin --auto >/dev/null
      git -C "$dir" reset --hard origin/HEAD
    fi
  elif [ -n "$branch" ]; then
    git clone --branch "$branch" "$url" "$dir"
  else
    git clone "$url" "$dir"
  fi
}

echo "==> Syncing framework repo"
sync_repo "$FRAMEWORK_REPO_URL" "$FRAMEWORK_REPO_BRANCH" "$FRAMEWORK_DIR"

echo "==> Syncing private fleet-config repo"
# Uses the host-local deploy key if present (see bootstrap.sh); otherwise
# falls back to whatever git credentials the host already has.
if [ -f "$DEPLOY_KEY" ]; then
  # IdentitiesOnly so this key is used for nothing but this clone/fetch.
  export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi
sync_repo "$FLEET_CONFIG_REPO_URL" "$FLEET_CONFIG_REPO_BRANCH" "$FLEET_CONFIG_DIR"
unset GIT_SSH_COMMAND

CONF="$FLEET_CONFIG_DIR/$FLEET_CONFIG_SUBDIR"
fail() { echo "ERROR: $1 (see consigliere-fleet-template/)" >&2; exit 1; }
[ -f "$CONF/inventory/hosts.yml" ] || fail "$CONF/inventory/hosts.yml not found -- the host table is required, otherwise no role beyond the baseline would ever match"
[ -f "$CONF/inventory/groups.yml" ] || fail "$CONF/inventory/groups.yml not found -- it turns the host table's values into groups and is required"
# Group vars are required (without them every role would run with no config).
# Per-host vars are optional: git can't track an empty directory, and a fleet
# with no per-host overrides is perfectly valid.
[ -d "$CONF/vars/group" ] || fail "$CONF/vars/group not found in the fleet-config repo"

echo "==> Assembling run directory"
RUN_DIR="$WORKDIR/run"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
ln -s "$CONF/vars/group" "$RUN_DIR/group_vars"
# Host names are case-insensitive: the inventory name is lowercase, so the host table's
# keys and the host_vars file names are lowercased into the run directory.
if [ -d "$CONF/vars/host" ]; then
  mkdir "$RUN_DIR/host_vars"
  for f in "$CONF/vars/host"/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    ln -s "$f" "$RUN_DIR/host_vars/$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  done
fi
python3 - "$CONF/inventory/hosts.yml" "$RUN_DIR/hosts.yml" <<'PY'
import sys, yaml
src, dst = sys.argv[1:3]
data = yaml.safe_load(open(src)) or {}
def lower_hosts(node):
    if isinstance(node, dict):
        for k, v in list(node.items()):
            if k == "hosts" and isinstance(v, dict):
                seen = {}
                for h in list(v):
                    lh = str(h).lower()
                    if lh in seen:
                        sys.exit(f"ERROR: hosts.yml lists '{h}' and '{seen[lh]}', the same name ignoring case")
                    seen[lh] = h
                node[k] = {str(h).lower(): v[h] for h in v}
            else:
                lower_hosts(v)
lower_hosts(data)
yaml.safe_dump(data, open(dst, "w"), sort_keys=False)
PY
# Per-host secrets (e.g. secrets/cw/<certificate>.yml): not loaded automatically;
# roles read only the files a host asked for, and can decrypt only its own.
EXTRA_VARS=()
if [ -d "$CONF/secrets" ]; then
  ln -s "$CONF/secrets" "$RUN_DIR/secrets"
  EXTRA_VARS=(-e "fleet_secrets_dir=$RUN_DIR/secrets")
fi
# Tag manifests (what each util:/feat: tag runs): your config/tags/ first, then the
# framework's hosts/tags/.
EXTRA_VARS+=(-e "{\"fleet_tags_dirs\": [\"$CONF/tags\", \"$FRAMEWORK_DIR/hosts/tags\"]}")
# RECONCILE_PLAYBOOK picks the entry playbook (default site.yml; Unraid uses site-unraid.yml). The
# fleet's own file of that name, if it has one, wins over the framework's.
PLAYBOOK_FILE="${RECONCILE_PLAYBOOK:-site.yml}"
if [ -f "$CONF/$PLAYBOOK_FILE" ]; then
  cp "$CONF/$PLAYBOOK_FILE" "$RUN_DIR/site.yml"
else
  cp "$FRAMEWORK_DIR/hosts/$PLAYBOOK_FILE" "$RUN_DIR/site.yml"
fi

# Framework roles first; the fleet's own roles (if any) are also available.
export ANSIBLE_ROLES_PATH="$FRAMEWORK_DIR/hosts/roles${CONF:+:$CONF/roles}"
export ANSIBLE_CONFIG="$FRAMEWORK_DIR/hosts/ansible.cfg"

# Secrets live in config/secrets/<kind>/<name>.yml, encrypted with sops to the age
# public keys of the hosts allowed to read them. This host can decrypt only the
# files it is a recipient of, using the private key in $AGE_KEY_FILE; the roles
# read just the ones they need (see the load_secrets role).
EXTRA_VARS+=(-e "fleet_age_key_file=$AGE_KEY_FILE")

# Inventory: this host (Tailscale name), the fleet's host table, then the rules
# that turn table values into groups. The table lists every host but the run is
# limited to this one.
SELF="$(python3 "$FRAMEWORK_DIR/hosts/inventory/tailscale_self.py" --name)"
INV_ARGS=(
  -i "$FRAMEWORK_DIR/hosts/inventory/tailscale_self.py"
  -i "$RUN_DIR/hosts.yml"
  -i "$CONF/inventory/groups.yml"
)
SELF_VARS="$(ansible-inventory "${INV_ARGS[@]}" --host "$SELF" 2>/dev/null || true)"
if ! grep -qE '"(util|feat)"' <<<"$SELF_VARS"; then
  echo "WARNING: '$SELF' has no entry (with util: or feat:) in inventory/hosts.yml -- only the baseline will run. The key must equal this host's Tailscale hostname." >&2
fi

echo "==> Running playbook"
cd "$RUN_DIR"
run_playbook() {
  # shellcheck disable=SC2086  # ANSIBLE_EXTRA_ARGS is intentionally word-split
  ansible-playbook \
    "${INV_ARGS[@]}" --limit "$SELF" \
    ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"} \
    ${ANSIBLE_EXTRA_ARGS:-} \
    "$@" site.yml
}

# RECONCILE_MODE=check  report drift only (--check --diff), change nothing.
# RECONCILE_MODE=apply  (default) check first, and only if that pass succeeds,
#                       apply. RECONCILE_PRECHECK=0 skips the check pass (bootstrap
#                       does, after you approved the first check by hand).
case "${RECONCILE_MODE:-apply}" in
  check) echo "==> Check only"; run_playbook --check --diff ;;
  apply)
    if [ "${RECONCILE_PRECHECK:-1}" = 1 ]; then
      echo "==> Pre-check (nothing is changed)"
      run_playbook --check --diff || { echo "ERROR: the pre-check failed; not applying" >&2; exit 1; }
    fi
    echo "==> Applying"
    run_playbook
    ;;
  *) echo "ERROR: RECONCILE_MODE must be check or apply" >&2; exit 2 ;;
esac
