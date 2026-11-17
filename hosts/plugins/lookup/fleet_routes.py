"""Lookup: the Traefik routes a host serves, from the fleet's per-domain route files.

Each file in a routes directory (the fleet repo's config/routes/) is one domain or zone; its name without .yml is the zone (a64.one.yml, rmrg.casa.yml):

    cert: a64.one            # optional: the certificate that covers these names (a name from the host's cert: tags)
    via: constant            # optional default: the host(s) whose Traefik serves the routes; a route can say its own `via`
    routes:
      - {name: mail, host: mail.a64.one, backend: "http://mailflow-frontend:80", profile: relaxed}
      - {name: arc, host: arc.ctrl.a64.one, backend: "http://arcane:3552", via: [constant, liaison], internal: true}

A route is served by the hosts its `via` names (a name, or a list of names; the file's `via` when the route has none). Every other key of the route is the same as in a
traefik_server_routes* variable and is passed on unchanged, except `via`.

    lookup('fleet_routes', inventory_hostname, dirs=fleet_routes_dirs)

returns {"zones": [{"name", "cert", "routes"}, ...]}: only the zones with at least one route for the host, in name order, each with just that host's routes.
A file that is not valid stops the run with every problem listed (a bad file must not silently drop routes).
"""
import os
import re

try:
    from ansible.errors import AnsibleError
    from ansible.plugins.lookup import LookupBase
except ImportError:  # the parsing functions are also tested without ansible installed
    class AnsibleError(Exception):
        pass

    class LookupBase(object):
        pass

DOCUMENTATION = r"""
  name: fleet_routes
  short_description: the Traefik routes a host serves, from per-domain route files
  description:
    - Reads the fleet's per-domain route files and returns the routes whose C(via) names the given host.
  options:
    _terms:
      description: The host name (inventory_hostname).
      required: true
    dirs:
      description: Directories holding the route files (one C(<zone>.yml) per domain). Missing directories are skipped.
      type: list
      elements: str
      default: []
"""

_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_FILE_KEYS = {"cert", "via", "routes", "description"}


def _as_list(v):
    if v is None:
        return []
    return list(v) if isinstance(v, (list, tuple)) else [v]


def load_zones(dirs, yaml_load):
    """All zones in the directories as a list of {name, cert, via, routes, path}, plus a list of problems."""
    zones, problems, seen = [], [], {}
    for d in dirs or []:
        if not d or not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith((".yml", ".yaml")):
                continue
            path = os.path.join(d, fn)
            zone = re.sub(r"\.ya?ml$", "", fn)
            if zone in seen:
                problems.append("%s: zone %s is also defined in %s" % (path, zone, seen[zone]))
                continue
            seen[zone] = path
            try:
                with open(path) as fh:
                    doc = yaml_load(fh.read()) or {}
            except Exception as e:  # noqa: BLE001
                problems.append("%s: not valid YAML: %s" % (path, e))
                continue
            if not isinstance(doc, dict):
                problems.append("%s: must be a mapping with a `routes:` list" % path)
                continue
            for k in doc:
                if k not in _FILE_KEYS:
                    problems.append("%s: unknown key %r (allowed: %s)" % (path, k, ", ".join(sorted(_FILE_KEYS))))
            routes = doc.get("routes")
            if not isinstance(routes, list):
                problems.append("%s: `routes:` must be a list" % path)
                continue
            default_via = [str(x).lower() for x in _as_list(doc.get("via"))]
            cert = doc.get("cert")
            if cert is not None and not isinstance(cert, str):
                problems.append("%s: `cert:` must be one certificate name" % path)
                cert = None
            out = []
            for i, r in enumerate(routes):
                label = "%s: route #%d" % (path, i + 1)
                if not isinstance(r, dict):
                    problems.append("%s is not a mapping" % label)
                    continue
                name = r.get("name")
                if not isinstance(name, str) or not _NAME.match(name):
                    problems.append("%s: name %r must be a-z, 0-9 and dashes" % (label, name))
                    continue
                label = "%s: route %s" % (path, name)
                via = [str(x).lower() for x in _as_list(r["via"])] if "via" in r else default_via
                if not via:
                    problems.append("%s has no `via` (name the host that serves it, here or at the top of the file)" % label)
                    continue
                if any(not isinstance(x, str) or not x for x in via):
                    problems.append("%s: `via` must be a host name or a list of them" % label)
                    continue
                if "host" not in r and "rule" not in r:
                    problems.append("%s needs a `host` or a `rule`" % label)
                    continue
                route = {k: v for k, v in r.items() if k != "via"}
                out.append({"route": route, "via": via})
            zones.append({"name": zone, "cert": cert, "routes": out, "path": path})
    return zones, problems


def routes_for_host(zones, host):
    """The zones (name order) with the routes served by `host`; also the problems that only show up per host (a name used twice)."""
    host = str(host).lower()
    result, problems, names = [], [], {}
    for z in sorted(zones, key=lambda z: z["name"]):
        mine = [e["route"] for e in z["routes"] if host in e["via"]]
        if not mine:
            continue
        for r in mine:
            if r["name"] in names:
                problems.append("route name %s is used in %s and in %s: names must be unique on a host" % (r["name"], names[r["name"]], z["name"]))
            names[r["name"]] = z["name"]
        result.append({"name": z["name"], "cert": z["cert"], "routes": mine})
    return result, problems


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        import yaml
        if len(terms) != 1:
            raise AnsibleError("fleet_routes takes one term: the host name")
        dirs = kwargs.get("dirs") or []
        zones, problems = load_zones(dirs, yaml.safe_load)
        mine, more = routes_for_host(zones, terms[0])
        problems += more
        if problems:
            raise AnsibleError("the route files have problems:\n  - " + "\n  - ".join(problems))
        return [{"zones": mine}]
