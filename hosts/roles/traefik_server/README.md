# traefik_server

Runs Traefik (Docker, pinned `traefik_server_version`) as this host's reverse proxy and
renders its configuration: a static `traefik.yml`, and dynamic files (a shared base, this
host's own routes, the certificates available on the host). It also creates the shared proxy
network. The host holds no DNS API key: certificates are files from Cert Warden. Set
`traefik_server_deploy: false` to only render the config and run Traefik some other way.
The stack is the successor to the geotraefik compose, minus its ACME resolver.

## How a node knows which routes are its own

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

## Behind another proxy

If a proxy such as Caddy sits in front, list its address in `traefik_server_trusted_ips` so
Traefik trusts its `X-Forwarded-*` headers.

## Unverified

Not run against a live host. That Traefik reloads when a referenced certificate file changes is handled by
touching `20-tls.yml` after renewal (the fetch script does this); I haven't
confirmed it against a running Traefik.
