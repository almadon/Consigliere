#!/bin/sh
# Runs inside a container of the distribution under test (see ci/run-matrix.sh). POSIX sh: Alpine has no bash until it is installed.
#   EXPECT_FAMILY (debian|alpine) and EXPECT_PKG_MANAGER (apt|apk) say what the platform layer must report.
set -eu
cd /repo

echo "==> $(. /etc/os-release; echo "$PRETTY_NAME") ($(uname -m)): installing what Ansible needs"
if [ -f /etc/alpine-release ]; then
  apk add --no-cache python3 py3-pip git curl ca-certificates >/dev/null
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq python3 python3-venv python3-apt git curl ca-certificates >/dev/null
fi
python3 -m venv --system-site-packages /tmp/venv
/tmp/venv/bin/pip install -q "ansible-core~=2.19.0" PyYAML
export PATH=/tmp/venv/bin:$PATH
ansible-galaxy collection install -q -r hosts/requirements.yml -p /tmp/collections
export ANSIBLE_COLLECTIONS_PATH=/tmp/collections ANSIBLE_CONFIG=/repo/hosts/ansible.cfg ANSIBLE_ROLES_PATH=/repo/hosts/roles ANSIBLE_NOCOLOR=1

echo "==> Python unit tests (version ordering, route files)"
python3 -m unittest discover -s hosts/tests

echo "==> Entry playbook syntax"
ansible-playbook --syntax-check -i localhost, hosts/site.yml >/dev/null

echo "==> Platform layer, first run"
ansible-playbook -i localhost, ci/platform-matrix.yml | tail -n 4
echo "==> Platform layer, second run: it must change nothing"
out="$(ansible-playbook -i localhost, ci/platform-matrix.yml | tail -n 3)"
echo "$out"
echo "$out" | grep -Eq 'changed=0 ' || { echo "ERROR: the second run changed something (not idempotent)" >&2; exit 1; }
echo "==> OK"
