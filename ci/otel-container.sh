#!/bin/sh
# The otel_agent role as a container, end to end, on this machine's Docker: an Alpine container with Ansible drives the host's Docker socket, as the container reconciler does
# on Alpine and Unraid, and checks the collector comes up, stays up, is idempotent and refuses a bad configuration. Needs Docker. Leaves nothing behind.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/otel-ci.XXXXXX")" && pwd -P)"
trap 'rm -rf "$work"' EXIT
docker run --rm --init -v /var/run/docker.sock:/var/run/docker.sock -v "$here:/repo:ro" -v "$work:$work" -e WORK="$work" alpine:3.22 sh /repo/ci/otel-in-container.sh
