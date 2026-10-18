# -*- coding: utf-8 -*-
"""Lookup: which roles (and task files) should this host run, according to the
tag manifests?

A host's table entry holds tag values per dimension, e.g.
    util: [traefik, docker]      feat: [arkeep]
Each (dimension, value) may have a manifest file  <dir>/<dimension>/<value>.yml:
    description: ...
    order: 50                     # lower runs earlier (default 50)
    requires: [util/docker]       # other tags this one implies (optional)
    conflicts: [prop/dns_other]   # tags that may not be combined with this one (optional)
    roles: [traefik_server]       # roles to run
    tasks: [files/extra.yml]      # task files, relative to the manifest (optional)
    vars: {timezone_name: UTC}    # variables given to those roles/tasks (optional)
    firewall: [{port: 443, proto: tcp}]   # ports to open to the world (optional; an optional
                                  # `from:` CIDR limits who; see the firewall role)
    secrets: [arkeep.agent]       # secrets (config/secrets/<kind>/<name>.yml) the host needs;
                                  # in <dimension>/_default.yml "{value}" expands per tag value
The search dirs come first-wins, so your fleet repo's config/tags/ can add tags
or override the framework's. Returns an ordered, de-duplicated plan:
    [{"kind": "role", "name": ..., "tag": "util/traefik"}, {"kind": "tasks", "file": ..., "tag": ...}]

A dimension may also have <dimension>/_default.yml, applied once when the host has
any value in that dimension (e.g. cert/_default.yml requires feat/certwarden).
Values of such a dimension need no manifest of their own.

Variables read: fleet_tag_dimensions (default [util, feat, cert, prop, fw]), fleet_tags_dirs
(default: the framework's hosts/tags), fleet_tags_strict (fail on a tag with no
manifest; default false: such tags are just classes).
"""
from __future__ import annotations

import os

import yaml
from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase

DOCUMENTATION = """
  name: fleet_roles
  short_description: roles and task files selected by tag manifests
  description: See the module header.
"""


def _as_list(v):
    if v is None:
        return []
    return list(v) if isinstance(v, (list, tuple)) else [v]


def resolve(values, dims, dirs, strict=False):
    """values: {dimension: value or list}. Returns {"plan", "tags", "unknown", "secrets", "firewall"}.
    Also used by the fleet repo's scripts/access.sh to work out who may read which secret."""

    def find(tag):
        dim, _, val = tag.partition("/")
        for d in dirs:
            p = os.path.join(d, dim, f"{val}.yml")
            if os.path.isfile(p):
                return p
        return None

    wanted, seen, plan, unknown = [], set(), [], []
    defaults = set()
    for dim in dims:
        vals = _as_list(values.get(dim))
        for val in vals:
            wanted.append(f"{dim}/{val}")
        if vals and find(f"{dim}/_default"):
            defaults.add(dim)
            wanted.append(f"{dim}/_default")

    queue = list(wanted)
    manifests = {}
    while queue:
        tag = queue.pop(0)
        if tag in seen:
            continue
        seen.add(tag)
        path = find(tag)
        if not path:
            if tag.partition("/")[0] not in defaults:
                unknown.append(tag)
            continue
        with open(path) as fh:
            m = yaml.safe_load(fh) or {}
        if not isinstance(m, dict):
            raise AnsibleError(f"tag manifest {path} must be a YAML mapping")
        manifests[tag] = (m, path)
        queue.extend(_as_list(m.get("requires")))

    if unknown and strict:
        raise AnsibleError("tags with no manifest (fleet_tags_strict is on): " + ", ".join(sorted(unknown)))

    for tag, (m, path) in manifests.items():
        for c in _as_list(m.get("conflicts")):
            if c in manifests:
                raise AnsibleError(f"tags {tag} and {c} cannot be combined (see {path})")

    secrets = set()
    for tag, (m, path) in manifests.items():
        dim, _, val = tag.partition("/")
        for sc in _as_list(m.get("secrets")):
            if val == "_default":
                for v in _as_list(values.get(dim)):
                    secrets.add(sc.replace("{value}", str(v)))
            else:
                secrets.add(sc)

    order = sorted(manifests, key=lambda t: (int(manifests[t][0].get("order", 50)), t))
    done = set()
    for tag in order:
        m, path = manifests[tag]
        for r in _as_list(m.get("roles")):
            if ("role", r) not in done:
                done.add(("role", r))
                plan.append({"kind": "role", "name": r, "tag": tag, "vars": m.get("vars") or {}})
        for t in _as_list(m.get("tasks")):
            f = t if os.path.isabs(t) else os.path.normpath(os.path.join(os.path.dirname(path), t))
            if ("tasks", f) not in done:
                done.add(("tasks", f))
                plan.append({"kind": "tasks", "file": f, "tag": tag, "vars": m.get("vars") or {}})
    firewall, seen_fw = [], set()
    for tag in order:
        for rule in _as_list(manifests[tag][0].get("firewall")):
            key = (str(rule.get("port")), str(rule.get("proto", "tcp")), str(rule.get("from", "")))
            if key not in seen_fw:
                seen_fw.add(key)
                firewall.append({"port": rule.get("port"), "proto": rule.get("proto", "tcp"), "from": rule.get("from", "")})
    return {"plan": plan, "tags": sorted(manifests), "unknown": sorted(unknown), "secrets": sorted(secrets),
            "firewall": firewall}


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        v = variables or {}
        dims = _as_list(kwargs.get("dimensions", v.get("fleet_tag_dimensions", ["util", "feat", "cert", "prop", "fw"])))
        default_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "tags"))
        dirs = _as_list(kwargs.get("dirs", v.get("fleet_tags_dirs"))) or [default_dir]
        strict = bool(kwargs.get("strict", v.get("fleet_tags_strict", False)))
        return [resolve({d: v.get(d) for d in dims}, dims, dirs, strict)]
