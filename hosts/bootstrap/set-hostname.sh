#!/usr/bin/env bash
# Sets the host's OS hostname to NODE_NAME (the short name the fleet knows it by), before it joins the tailnet. Used by bootstrap.sh.
# Until a host is on the tailnet the fleet identifies it by this hostname, and it has to equal the key in the fleet repo's hosts.yml; cloud images
# often name the machine after the instance (instance-2026...). Does nothing when NODE_NAME is empty or the host already has that name.
set -euo pipefail

name="${NODE_NAME:-}"
[ -n "$name" ] || exit 0
name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
printf '%s' "$name" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' ||
  { echo "ERROR: NODE_NAME must be a short host name (letters, digits, dashes), got '$NODE_NAME'" >&2; exit 1; }

current="$(hostnamectl --static 2>/dev/null || hostname)"
if [ "${current,,}" = "$name" ]; then
  echo "OK hostname is already $name"
else
  echo "==> Setting the hostname to $name (was $current)"
  hostnamectl set-hostname "$name"
fi
# 127.0.1.1 should name this host, not the old name
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E "s/^(127\.0\.1\.1)[[:space:]].*/\1 $name/" /etc/hosts
else
  printf '127.0.1.1 %s\n' "$name" >> /etc/hosts
fi
# cloud-init would otherwise put the instance's name back at the next boot
if [ -d /etc/cloud/cloud.cfg.d ]; then
  printf '# Managed by Consigliere: the fleet keeps the name it chose.\npreserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-consigliere-hostname.cfg
fi
