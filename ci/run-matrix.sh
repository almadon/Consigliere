#!/bin/sh
# The platform matrix: the platform layer on Debian, Ubuntu and Alpine, each in a throwaway container (needs Docker; OrbStack, Colima or Docker Desktop on a Mac).
#   ci/run-matrix.sh                  all three
#   ci/run-matrix.sh debian:13        one image (also ubuntu:24.04, alpine:3.22)
# Nothing on the host changes: the repository is mounted read-only and the containers are removed afterwards.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
images="${*:-debian:13 ubuntu:24.04 alpine:3.22}"
fail=0
for image in $images; do
  case "$image" in
    alpine:*) family=alpine; pm=apk ;;
    *)        family=debian; pm=apt ;;
  esac
  echo "################ $image"
  docker run --rm -v "$here:/repo:ro" -e EXPECT_FAMILY="$family" -e EXPECT_PKG_MANAGER="$pm" "$image" sh /repo/ci/in-container.sh || { echo "FAILED: $image" >&2; fail=1; }
done
exit $fail
