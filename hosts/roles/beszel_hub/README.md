# beszel_hub

The [Beszel](https://www.beszel.dev) hub in Docker: the dashboard the agents report to.
Run it on one host (`util: [beszel]`), behind Traefik (`beszel_hub_network: proxynet` plus a
`traefik_server_routes_beszel` route) so agents anywhere reach it over HTTPS at `beszel_hub_url`.

Set up once: open the URL, register the first (admin) account, then copy the public key
(Add system) and a universal token (Settings > Tokens) into the `beszel.agent` secret and add
`prop: [beszel]` to the hosts. Data is in `<dir>/data`: back it up (Arkeep).
Not tested against a live host.
