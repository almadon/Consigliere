#!/bin/sh
# Runs inside an Alpine container with the host's Docker socket and a work directory mounted at the same path as on the host (see ci/otel-container.sh).
set -eu
cd /repo
echo "==> Installing Ansible and the Docker client"
apk add --no-cache python3 py3-pip git curl docker-cli docker-cli-compose >/dev/null
python3 -m venv --system-site-packages /tmp/venv
/tmp/venv/bin/pip install -q "ansible-core~=2.19.0" PyYAML docker 2>&1 | grep -v notice || true
export PATH=/tmp/venv/bin:$PATH ANSIBLE_COLLECTIONS_PATH=/tmp/collections ANSIBLE_CONFIG=/repo/hosts/ansible.cfg ANSIBLE_ROLES_PATH=/repo/hosts/roles ANSIBLE_NOCOLOR=1
ansible-galaxy collection install -r hosts/requirements.yml -p /tmp/collections >/dev/null
DIR="$WORK/common/otel-agent"
# The files this container wrote into $WORK belong to root and are mode 0750: on a Linux runner the script that started this container (a different user) could not delete them,
# and its cleanup failed the job after the test had passed. Opening the modes lets it.
cleanup() { docker rm -f otel-agent >/dev/null 2>&1 || true; chmod -R a+rwX "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
run() { ansible-playbook -i localhost, ci/otel-container.yml "$@"; }

echo "==> First run: the collector comes up as a container"
run | grep -E "fatal|FAILED|ERROR|PLAY RECAP|localhost +:" | cut -c1-200
test "$(docker inspect -f '{{.State.Running}}' otel-agent)" = true || { echo "ERROR: otel-agent is not running" >&2; docker logs otel-agent 2>&1 | tail -5 >&2; exit 1; }
test -s "$DIR/config.yaml" && test -s "$DIR/docker-compose.yml" || { echo "ERROR: the configuration or the compose file is missing" >&2; exit 1; }
ID1="$(docker inspect -f '{{.Id}}' otel-agent)"
echo "==> What it was given: no capabilities but one, a read-only root, host networking, the config read-only"
docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.NetworkMode}} cap_drop={{.HostConfig.CapDrop}} cap_add={{.HostConfig.CapAdd}} user={{.Config.User}}' otel-agent
test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' otel-agent)" = true
test "$(docker inspect -f '{{.HostConfig.NetworkMode}}' otel-agent)" = host
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}' otel-agent | grep -q "config.yaml -> /etc/otelcol-contrib/config.yaml rw=false"
echo "==> It stays up (the Loki address is dead: it must queue and retry, not crash)"
sleep 15
test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' otel-agent)" = "true 0" || { echo "ERROR: it restarted or stopped" >&2; docker logs otel-agent 2>&1 | tail -5 >&2; exit 1; }

# The collector's configuration holds a table of container names from `docker ps`. The agent's own container is left out of it (each apply recreates the container with a new id, which
# would change the configuration, and so recreate it, on every run), so a second run must change nothing and leave the container alone.
echo "==> Second run: nothing changes and the container is not recreated"
run > /tmp/second.log 2>&1 || { echo "ERROR: the second run failed" >&2; tail -8 /tmp/second.log >&2; exit 1; }
out="$(grep -E "fatal|FAILED|ERROR|localhost +:" /tmp/second.log)"; echo "$out"
echo "$out" | grep -Eq 'changed=0 ' || { echo "ERROR: the second run changed something:" >&2; awk '/^TASK \[/{t=$0} /^changed:/{print "  " t}' /tmp/second.log | sed 's/ \*\+$//' >&2; exit 1; }
ID2="$(docker inspect -f '{{.Id}}' otel-agent)"
test "$ID2" = "$ID1" || { echo "ERROR: the container was recreated" >&2; exit 1; }

# safe_apply puts the last-good files back and restarts the service when a change fails, so the container may be recreated: what must hold is that it is running on the
# configuration it had before, and that the bad one never reached the file.
echo "==> A configuration the collector rejects is refused, and the collector is left running on the good one"
SUM="$(sha256sum "$DIR/config.yaml" | cut -d' ' -f1)"
if run -e '{"otel_agent_system_log_files": ["/var/log/[unclosed"]}' > /tmp/bad.log 2>&1; then echo "ERROR: a bad configuration was accepted" >&2; exit 1; fi
grep -E "include: parse glob" /tmp/bad.log | head -1 | cut -c1-200 || true
sleep 5
test "$(docker inspect -f '{{.State.Running}}' otel-agent 2>/dev/null)" = true || { echo "ERROR: the collector is not running after the rejected change" >&2; docker ps -a >&2; exit 1; }
test "$(sha256sum "$DIR/config.yaml" | cut -d' ' -f1)" = "$SUM" || { echo "ERROR: the configuration file changed" >&2; exit 1; }
! grep -q unclosed "$DIR/config.yaml" || { echo "ERROR: the bad configuration reached the file" >&2; exit 1; }
# A host whose Docker cannot set a memory limit (an LXC without the memory controller) must still get a running collector: the role tries the limit and leaves it out. A `docker`
# that fails that probe stands in for such a host.
echo "==> A Docker that refuses a memory limit: the collector still comes up, without one"
docker rm -f otel-agent >/dev/null
mkdir -p /tmp/shim
cat > /tmp/shim/docker <<'SHIM'
#!/bin/sh
if [ "${1:-}" = info ] && [ -n "${FAKE_LXC:-}" ]; then echo 1073741824; exit 0; fi
if [ "${1:-}" = run ]; then
  case " $* " in
    *" --memory "*) echo "docker: Error response from daemon: OCI runtime create failed: openat2 memory.max: no such file or directory (simulated)" >&2; exit 125 ;;
  esac
fi
exec /usr/bin/docker "$@"
SHIM
chmod +x /tmp/shim/docker
PATH=/tmp/shim:$PATH run -e otel_agent_hostmetrics=true -e otel_agent_metrics_url=http://127.0.0.1:9/otlp > /tmp/limits.log 2>&1 || { echo "ERROR: the run failed on a host without those features" >&2; tail -12 /tmp/limits.log >&2; exit 1; }
grep -E "no memory limit" /tmp/limits.log | head -2 | cut -c1-200
sleep 5
test "$(docker inspect -f '{{.State.Running}}' otel-agent)" = true || { echo "ERROR: the collector is not running" >&2; docker logs otel-agent 2>&1 | tail -5 >&2; exit 1; }
test "$(docker inspect -f '{{.HostConfig.Memory}}' otel-agent)" = 0 || { echo "ERROR: a memory limit was set anyway" >&2; exit 1; }
! grep -q "mem_limit" "$DIR/docker-compose.yml" || { echo "ERROR: mem_limit is in the compose file" >&2; exit 1; }
grep -q ":/hostfs:ro$" "$DIR/docker-compose.yml" || { echo "ERROR: the host mount is missing" >&2; exit 1; }
echo "==> And on a host that can set one, the limit is used"
run -e otel_agent_hostmetrics=true -e otel_agent_metrics_url=http://127.0.0.1:9/otlp > /tmp/full.log 2>&1 || { echo "ERROR: the run failed" >&2; tail -12 /tmp/full.log >&2; exit 1; }
sleep 5
test "$(docker inspect -f '{{.State.Running}}' otel-agent)" = true
grep -q "mem_limit: 256m" "$DIR/docker-compose.yml" || { echo "ERROR: the limit is missing on a host that supports it" >&2; cat "$DIR/docker-compose.yml" >&2; exit 1; }
# A first install whose start failed leaves the files in place: the next run must still bring the collector up, not report success with nothing running.
echo "==> A collector that is not running is started by the next run, although no file changed"
docker stop otel-agent >/dev/null
run -e otel_agent_hostmetrics=true -e otel_agent_metrics_url=http://127.0.0.1:9/otlp > /tmp/restart.log 2>&1 || { echo "ERROR: the run failed" >&2; tail -12 /tmp/restart.log >&2; exit 1; }
sleep 3
test "$(docker inspect -f '{{.State.Running}}' otel-agent)" = true || { echo "ERROR: the stopped collector was not started" >&2; exit 1; }
# In an LXC the Docker daemon sees the container's memory (1 GiB here) while this container reads the kernel's: CPU, memory and load would be the neighbour's, so they are left out.
echo "==> An LXC-like host (Docker's memory far below the kernel's): CPU, memory and load are not collected, the filesystem still is"
FAKE_LXC=1 PATH=/tmp/shim:$PATH run -e otel_agent_hostmetrics=true -e otel_agent_metrics_url=http://127.0.0.1:9/otlp > /tmp/lxc.log 2>&1 || { echo "ERROR: the run failed" >&2; tail -12 /tmp/lxc.log >&2; exit 1; }
grep -E "virtualized" /tmp/lxc.log | head -1 | cut -c1-200
! grep -q "system.memory.utilization" "$DIR/config.yaml" && ! grep -qE "^      (cpu|load):" "$DIR/config.yaml" && grep -q "system.filesystem.utilization" "$DIR/config.yaml" || { echo "ERROR: wrong scrapers for a virtualized /proc" >&2; exit 1; }
echo "==> A normal host keeps them"
run -e otel_agent_hostmetrics=true -e otel_agent_metrics_url=http://127.0.0.1:9/otlp > /tmp/normal.log 2>&1 || { echo "ERROR: the run failed" >&2; tail -12 /tmp/normal.log >&2; exit 1; }
grep -q "system.memory.utilization" "$DIR/config.yaml" && grep -qE "^      cpu:" "$DIR/config.yaml" || { echo "ERROR: memory and CPU are missing on a normal host" >&2; exit 1; }
sleep 3
test "$(docker inspect -f '{{.State.Running}}' otel-agent)" = true
echo "==> OK"
