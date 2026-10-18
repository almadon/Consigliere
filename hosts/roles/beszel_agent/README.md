# beszel_agent

The [Beszel](https://www.beszel.dev) agent in Docker, run by the `prop: [beszel]` tag. It reads
host and container stats (Docker socket, read-only) and reports them to the hub over an
outbound WebSocket (`HUB_URL`), so the hub needs no route to the node.

- Secret `beszel.agent`: `beszel_agent_key` (the hub's public key) and `beszel_agent_token`
  (a universal token from the hub's Settings > Tokens), shared by all agents.
- Var `beszel_hub_url`: the hub's address, in `config/vars/group/all.yml`.
- The image is pinned (`beszel_agent_version`); bump it with the hub.
- Runs with host networking (needed for host network stats), listening on 45876.
- Not tested against a live host.
