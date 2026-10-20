#!/usr/bin/env bash
# Makes sure `ansible-playbook` on this host is the version the framework is built and tested against: the "ansible" 12 bundle = ansible-core 2.19
# with its collections (what Debian 13 ships). Used by bootstrap.sh. Idempotent.
#   1. ansible-core 2.19 or newer already on the PATH: nothing to do
#   2. the distro's own package is new enough (Debian 13): install it with apt
#   3. otherwise (Ubuntu 24.04 ships core 2.16, which lacks `meta: end_role` and more): install the pinned bundle into a virtualenv at
#      /opt/fleet-ansible (with the system packages visible, so the apt module finds python3-apt) and link it into /usr/local/bin,
#      which comes before /usr/bin on the PATH of the reconcile service
# To upgrade: change ANSIBLE_BUNDLE_VERSION (a PyPI "ansible" release) and re-run bootstrap.sh, or run this script by hand.
set -euo pipefail

BUNDLE="${ANSIBLE_BUNDLE_VERSION:-12.0.0}"
VENV=/opt/fleet-ansible
MIN_MINOR=19   # ansible-core 2.<MIN_MINOR> and newer

core_minor() { "${1:-ansible}" --version 2>/dev/null | sed -n '1s/.*core 2\.\([0-9]*\).*/\1/p'; }

m="$(core_minor || true)"
if [ -n "$m" ] && [ "$m" -ge "$MIN_MINOR" ]; then
  echo "OK ansible-core 2.$m is new enough"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
cand="$(apt-cache policy ansible-core 2>/dev/null | awk '/Candidate:/ {print $2}' | sed -n 's/^[0-9]*:\{0,1\}2\.\([0-9]*\)\..*/\1/p')"
if [ -n "$cand" ] && [ "$cand" -ge "$MIN_MINOR" ]; then
  echo "==> Installing ansible from the distribution (core 2.$cand)"
  apt-get install -y ansible
  exit 0
fi

echo "==> The distribution's ansible is too old (core 2.${cand:-?}); installing ansible $BUNDLE into $VENV"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' ||
  { echo "ERROR: ansible-core 2.19 needs Python 3.11 or newer on the host; this is $(python3 --version 2>&1). Use Debian 13 or Ubuntu 24.04 or newer." >&2; exit 1; }
apt-get install -y python3-venv python3-apt
python3 -m venv --system-site-packages "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet "ansible==$BUNDLE"
for tool in ansible ansible-playbook ansible-inventory ansible-galaxy ansible-config ansible-doc; do
  ln -sf "$VENV/bin/$tool" "/usr/local/bin/$tool"
done
m="$(core_minor /usr/local/bin/ansible || true)"
[ -n "$m" ] && [ "$m" -ge "$MIN_MINOR" ] || { echo "ERROR: the virtualenv's ansible-core is not 2.$MIN_MINOR or newer" >&2; exit 1; }
echo "INSTALLED ansible $BUNDLE (core 2.$m) in $VENV"
