# arkeep_server

Deploys the central [Arkeep](https://github.com/arkeep-io/arkeep) backup
console to the `arkeep_server` group (one host). Agents (`hosts/roles/arkeep_agent`,
applied to every other host) connect outbound to this over gRPC.

## Fronting this with Traefik (geotraefik)

If this node also runs Traefik (from the separate `geotraefik` repo - see
[VISION.md](../../../VISION.md)'s roadmap), the GUI/REST port (8080) should
go through it for public TLS, while the gRPC port (9090) stays directly
exposed (Arkeep's own auto-PKI handles mTLS for agent connections - see
Arkeep's docs on "Option B" reverse-proxy setups).

To wire this up:
1. Pick a name for a Docker network both stacks will share, e.g.
   `arkeep-edge` (matches `arkeep_server_network` below). This role creates it
   for you when it's set.
2. Set `arkeep_server_network: arkeep-edge` in your fleet-config repo's
   config/vars/group/ file for this host. This role then binds port 8080 to
   `127.0.0.1` only and joins the container to that network instead.
3. In geotraefik's `stacks/traefik/dynamic/routes.yml`, add a router +
   service pointing at `http://server:8080` (Arkeep's container is named
   `server` inside the compose project) - join Traefik's own compose stack
   to the same `arkeep-edge` network for the name to resolve.
4. Set `arkeep_server_base_url` (this role) to the public HTTPS URL, and tell
   every `arkeep_agent` host to set `arkeep_agent_server_http_addr` to the same
   URL - both are required for enrollment/email links to work through a
   proxy. See Arkeep's own `.env.example` comments (fetched verbatim into
   this role's templates/task comments) for exactly why.

Without a reverse proxy, leave `arkeep_server_network` empty - port 8080
gets exposed directly and none of the above applies.

## Status

Scaffolded 2026-10-01, matches Arkeep's own `deploy/docker/docker-compose.yml`
as verified against the live repo that day. Not yet deployed to a real host.
