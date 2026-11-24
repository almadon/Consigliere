# cmdr

The fleet's control page: every host, whether it is healthy, and the way to each admin tool, on one screen.

- **Does:** shows each host and route declared in the fleet repo, with live status from Loki and host numbers from VictoriaMetrics, and links to the admin tools. It changes nothing on any host.
- **Owns settings:** this repo. Everything on the page comes from the fleet repo's host table and route files and from this role's variables. Nothing is edited in the page.
- **Keeps state:** nothing worth backing up. The role writes `inventory.json` into `/opt/cmdr/data` on every run, live status is held in memory and rebuilt from Loki, and sessions live in signed cookies.
- **Rolls back by:** nothing yet. The role is not on `safe_apply`, so a bad change recreates the container and a failed start stays failed until a fix is pushed.
- **Exposes:** port `8083` on the tailnet address (`cmdr_port`, `cmdr_bind_address`), reached through Traefik at the name in `cmdr_url`. The paths are listed under [What it serves](#what-it-serves).

## What it is for

cmdr answers three questions quickly: what do I have, is it healthy, and where do I click to deal with it. The engines stay where they are. Arcane runs the containers, Arkeep the backups, Grafana and Loki hold the logs, and Beszel watches host metrics. cmdr links to them and puts their headline status next to the hosts they watch.

A typical use is opening it first thing, seeing whether any tile is red, and going straight from that host's card to the right tool.

## Where its data comes from

| What | Source | If it is missing |
|---|---|---|
| Hosts, tags, routes | The fleet repo's checkout on this host: `inventory/hosts.yml`, the route files under `routes/` and any per-host `vars/routes/*.yml`. Tag descriptions come from the tag manifests. | The page cannot build its inventory, so the role stops. |
| Live status | Loki, which already receives every host's journal. A host counts as reporting if it sent logs in the last 10 minutes. Its last reconcile is the `ok= changed= failed=` recap of `fleet-reconcile.service`. The exposure table is the latest `fleet-exposure-watch` scan. | A banner says status is unavailable, and the page keeps showing what the repo declares. |
| CPU, memory, disk, load | VictoriaMetrics, from hosts that run `otel_agent_hostmetrics`. | With `cmdr_victoria_url` empty, or for a host that sends nothing, no bars are shown. |
| Map positions | The fleet's `inventory/locations.yml`. A host names its `location:` and the file maps that name to `geo: [latitude, longitude]`. A host's own `geo:` overrides it. | A host without coordinates is left off the map. |

## The page

### The status strip

Four tiles across the top count the hosts, how many are reporting, how many reconciles failed on their last run, and how many public-exposure alerts are open. The red tiles are buttons: clicking one filters the host list to the problems. A host that needs attention also gets its own card in a "Needs attention" row.

### The launchpad

One tile per admin tool, grouped as `cmdr_tools` says. A tile can carry a "tailnet" label when its name only opens from the LAN or the tailnet, and a badge showing who owns the tool's settings (`mgmt`: the repo, the user, or both). A tile with an `icon` shows that image, and one without shows its initials.

### Host cards

Each card starts with a status line (is it reporting, when did it last reconcile), then CPU, memory and disk bars where numbers exist. Below that come the host's tags grouped by kind, each kind with its own colour: Provides for `util` tags, Runs for `feat` tags and Settings for `prop` tags. The last section lists the hostnames the host serves, one per line, each marked `public` or `tailnet`. A long card scrolls inside itself instead of growing.

A host that declares `os:`, `arch:`, `node:` (for an LXC or VM), `location:` or `site:` in the host table shows them as chips. Clicking a chip filters to every host that shares it, and hovering a location lights the matching map marker and cards. Hosts without those fields show nothing extra.

Cards can be switched to rows, sorted by what needs attention first or by name, and filtered by type and by search text. A "How to read a host card" key under the Hosts heading explains the colours and labels. Kind names, meanings and colours are `cmdr_tag_kinds`, and any single tag can be renamed, described or recoloured in `cmdr_tag_overrides`.

### The host drawer

Clicking a card opens a drawer with everything about that host: its details, its routes with their backends, its exposure scan result, the commands for it, and six-hour CPU and memory charts when VictoriaMetrics has the data.

### Domains

Every route the fleet serves is also grouped by domain, following the files under `routes/`. Each group shows the certificate that covers its names and how many routes it has. Opening a group gives a table of its hostnames (as links), route names and backends, the host that serves each (click to open it), and whether the name is public or tailnet-only. The same search, type chips and attribute filters apply.

### The map

Hosts with coordinates appear on a world map drawn from an offline outline, so no tile server is involved. Markers are coloured by status, and hosts at the same place share one. Hovering a marker lists its hosts, clicking opens one, and dragging and scrolling move around. Optional arcs show where telemetry (the otel agents to the Loki host) and backups (the Arkeep agents to the server) flow.

### Commands and the palette

Ctrl or Cmd plus K opens a palette that finds hosts, services, tools and commands, and `/` jumps to the host filter. The command buttons copy a ready-to-paste command with the host's name filled in (`cmdr_host_commands`, `cmdr_commands`). cmdr never runs anything on a host itself. The one thing the page can do is Refresh, which asks cmdr to re-read Loki now.

The header button switches between the system, dark and light themes, and the choice is remembered per browser.

## Sign-in

Sign-in is OpenID Connect (authorization code with PKCE) against your identity provider, which is documented for Pocket ID, followed by a signed, HttpOnly session cookie that lasts eight hours. Members of `cmdr_admin_groups` are admins, members of `cmdr_viewer_groups` are viewers, and anyone else is turned away. In the provider, create a confidential client with the callback `<cmdr_url>/auth/callback`, the scopes `openid profile email groups`, and the groups above. `cmdr_idp_name` names the provider on the sign-in panel ("Sign in with Inti").

**Identity providers refuse to be shown in a frame, so a frame without a session cannot sign in.** When cmdr is embedded (allow the embedding site with `cmdr_frame_ancestors`), the frame shows a small branded sign-in panel instead. Its button opens the real sign-in in a small window, which tells the frame the moment it is done and closes itself after three seconds. The frame then reloads, and from then on it works until the session expires.

The `picture` claim is shown as your avatar in the header. It is read at every sign-in, so a changed picture appears the next time you sign in. Only an https address on the identity provider's own host is accepted, and the page's content security policy allows images from that host only.

A trusted proxy may pass the identity in `Remote-User` and `Remote-Groups` headers instead, but only together with the shared secret `cmdr_proxy_secret` in an `X-Cmdr-Proxy` header that the proxy adds. Headers without it are ignored, so a client on the tailnet cannot forge them.

## Settings

The secret `cmdr.server` (`config/secrets/cmdr/server.yml` in the fleet repo) holds `cmdr_oidc_client_id`, `cmdr_oidc_client_secret`, a generated `cmdr_session_secret` of 32 or more characters and, optionally, `cmdr_proxy_secret`. The rest are ordinary variables with defaults in `defaults/main.yml`.

| Variable | Default | What it does |
|---|---|---|
| `cmdr_url` | none, required | The public https address. The identity provider sends the browser back to it. |
| `cmdr_oidc_issuer_url` | none, required | The identity provider's address. |
| `cmdr_admin_groups`, `cmdr_viewer_groups` | `[Muximux-Admins]`, `[]` | Who may use the page, and who may only look. |
| `cmdr_port`, `cmdr_bind_address` | `8083`, the tailnet address | Where the container publishes. Traefik reaches it there. |
| `cmdr_network` | empty | A shared Docker network to join instead of publishing a port. |
| `cmdr_frame_ancestors` | `[]` | Sites that may embed the page. `none` allows nobody. |
| `cmdr_cookie_samesite` | `Lax` | `None` is needed when the page is shown inside another site's frame, such as a browser extension's new-tab page. It is safe here because cmdr changes nothing on the fleet and its one POST needs a custom header. |
| `cmdr_loki_url`, `cmdr_status_interval` | none, `60` | Where live status is read from, and how often in seconds. |
| `cmdr_victoria_url` | empty | Where host numbers are read from. Empty means no bars. |
| `cmdr_conf_dir` | derived from the secrets directory | Where the fleet repo's config directory is on this host. |
| `cmdr_internal_domains` | `[]` | Domains whose routes only answer on the LAN and tailnet. They are shown with a dashed border. |
| `cmdr_tools`, `cmdr_host_links` | `[]` | Launchpad tiles, and per-host buttons that use `{host}` and `{host_q}`. |
| `cmdr_host_commands`, `cmdr_commands` | a starter set | The copy-to-clipboard command buttons. The first host command is the quick button on every card. |
| `cmdr_tag_kinds`, `cmdr_tag_overrides` | the three kinds, none | Names, meanings and colours of the tag kinds, and per-tag overrides. |
| `cmdr_mgmt_kinds` | repo, both, user | The ownership badges on launchpad tiles. |
| `cmdr_icons` | `[]` | Image files already on this host, copied next to the page for launchpad tiles. |
| `cmdr_idp_name` | empty | What the sign-in panel calls the identity provider. |

## Running it

In the fleet repo, `scripts/cmdr.sh init` stores the client id and secret and a generated session secret in `cmdr.server`, and tags the host `util: [cmdr]`. The container is a stock `python` image running a standard-library script from `/opt/cmdr/app`, with a read-only root, no capabilities and no build step.

## What it serves

| Path | Needs sign-in | What it is |
|---|---|---|
| `/` and `/static/...` | yes | The page and its files. A few of them (the sign-in panel, the stylesheet, the logo) are public so the panel can render before sign-in. |
| `/api/fleet` | yes | The hosts, routes, status, tools and settings the page draws. |
| `/api/stats?host=<name>` | yes | Six hours of CPU and memory for one host. |
| `/api/me` | yes | Who is signed in. |
| `POST /api/refresh` | yes | Reads Loki now. It needs a custom `X-Cmdr` header, so another site cannot trigger it, and it answers 429 if called again within ten seconds. |
| `/auth/login`, `/auth/callback`, `/auth/logout`, `/auth/done` | no | The sign-in flow. |
| `/healthz` | no | Answers `ok`. |

## What was tested

When the sign-in flow was first written it was tested against a mock identity provider and a mock Loki: a wrong group, a tampered cookie, forged proxy headers, an open redirect and a path traversal were all refused. Those tests are not in the repository, and they have not been re-run since the page was rebuilt, so treat that as `VERIFY`. The page has run on the fleet since October 2026. The map, the domains view and the host drawer were added by later sessions and were checked by reading the code and by use, not by an automated test.
