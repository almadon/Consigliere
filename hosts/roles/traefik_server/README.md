# traefik_server

Runs Traefik (Docker, pinned `traefik_server_version`) as this host's reverse proxy and
renders its configuration: a static `traefik.yml`, and dynamic files (a shared base, this
host's own routes, the certificates available on the host). It also creates the shared proxy
network. The host holds no DNS API key: certificates are files from Cert Warden. Set
`traefik_server_deploy: false` to only render the config and run Traefik some other way.
The stack is the successor to the geotraefik compose, minus its ACME resolver.

## Routes by domain (route files)

Routes can be kept one file per domain in the fleet repo, `config/routes/<domain>.yml` (`a64.one.yml`, `rmrg.casa.yml`), so a domain's routes are in one place and
moving a service to another proxy is one `via:` line. Each file may set a default `via` (the host or hosts whose Traefik serve its routes) and the `cert` that
covers its names; a route may override `via`:

    cert: a64.one
    via: constant
    routes:
      - {name: mail, host: mail.a64.one, backend: "http://mailflow-frontend:80", profile: relaxed}
      - {name: arc, host: arc.ctrl.a64.one, backend: "http://arcane:3552", via: [constant, liaison], internal: true}

A host takes the routes whose `via` names it; every other key is the same as in a `traefik_server_routes` variable. The two sources add up, so a host can move over route
by route. The check refuses a file that is not valid (every problem is listed), a route with no `via`, a name used twice on one host, and a host that does not serve the
certificate its file names. The reconciler passes the directory as `fleet_routes_dirs`; the reading is the `fleet_routes` lookup in `hosts/plugins/lookup/`.

## How a node knows which routes are its own (variables)

By ordinary Ansible variable scope. Define any variable named
`traefik_server_routes` or `traefik_server_routes_<anything>`, and put it where
it should apply:

- `config/vars/routes/web-host.yml`: only on that host. This is the recommended place for a host's routes: the
  reconciler hands Ansible `vars/host/<host>.yml` (settings) and `vars/routes/<host>.yml` (routes) as two files of the
  same host, so they stay separate in git. A directory `vars/routes/<host>/*.yml` also works (one file per site).
- `config/vars/host/web-host.yml`: also works, for settings and routes together (the older layout).
- `config/vars/group/util_arkeep.yml`: wherever that service runs, so the route
  follows the service.
- `config/vars/group/all.yml`: on every proxy.

The role gathers every such variable the host can see (its groups plus its own
host file) and renders them. Unlike normal Ansible variables, layers **add up**
instead of overriding each other, because each layer uses a different name.

    traefik_server_routes_vault:
      - name: vaultwarden
        host: vault.example.com
        backend: http://vaultwarden:80      # container on the shared network

## Two sites that embed each other (CSP additions per route)

The default `app` profile sends a Content-Security-Policy that allows scripts and frames from the page's own origin only, and `X-Frame-Options: SAMEORIGIN`. A page that loads a script
from, or shows an iframe of, another site of yours (an office suite inside a file manager, a dashboard) is blocked by it, and the embedded site refuses to be framed. Adjust both ends
on their routes instead of loosening a profile:

    - {name: files, host: files.example.org, backend: "http://files:8600",
       csp_extra: {script-src: ["https://office.example.org"], frame-src: ["https://office.example.org"]}}
    - {name: office, host: office.example.org, backend: "http://office:9940", profile: relaxed,
       frame_ancestors: ["https://files.example.org"]}

`csp_extra` is a map of CSP directive names to lists of sources, appended to the profile's directive of that name. `frame_ancestors` is a list of origins that may embed the page. Sources
may not contain spaces, commas or semicolons, and neither option can be used with `profile: none`; the run stops with the reason otherwise. Tested by rendering the templates and reading the headers
from a running Traefik.

## Conflicting routes are refused

Before writing any file the role asserts that route names are unique and that no two routes match the same request
(the same host, or the same rule). The failure names the duplicate and nothing is changed on the host, so the running
Traefik keeps its last good configuration. The fleet repo's `scripts/preflight.sh` makes the same check before a push.

## Behind another proxy

If a proxy such as Caddy sits in front, list its address in `traefik_server_trusted_ips` so
Traefik trusts its `X-Forwarded-*` headers.

## Unverified

Not run against a live host. That Traefik reloads when a referenced certificate file changes is handled by
touching `20-tls.yml` after renewal (the fetch script does this); I haven't
confirmed it against a running Traefik.

## Internal-only routes

A route with `internal: true`, and every route under a domain listed in `traefik_server_internal_domains`, is answered only to
`traefik_server_internal_sources` (the private ranges and the tailnet); anyone else gets a 403 from Traefik. The test is the
connection's own address, not a header the client sent, so a host that is also reachable from the internet (a NAT'd edge host) can
still serve names that must stay inside. Listing the domain means a route added later under it is protected without remembering the flag.
