# cmdr

The fleet's control page: one place that shows every host, its status, and the way to every admin tool. It is the "what do I have, is it healthy, take me there"
layer; the engines stay where they are (Arcane for containers, Arkeep for backups, Grafana and Loki for logs, Beszel for host metrics, Wazuh later).

- **Hosts and routes come from the fleet repo**, read from the reconciler's checkout on this host (`inventory/hosts.yml` and `vars/routes/*.yml`), so the page
  can never disagree with what is declared. Tag descriptions come from the tag manifests.
- **Live status comes from Loki**, which already receives every host's journal: a host is *reporting* if it sent logs in the last 10 minutes; its last
  reconcile is the `ok= changed= failed=` recap of `fleet-reconcile.service`; the exposure table is the last `fleet-exposure-watch` scan. If Loki is
  unreachable the page says so and still shows the repo's data and the links.
- **Launch buttons**: `cmdr_tools` (fleet-wide, with a `tailnet` badge for names that only open on the LAN or tailnet) and `cmdr_host_links` (per host, with
  `{host}` / `{host_q}`), plus a one-click `ssh root@<host>` copy.
- **Read-only.** It shows and links; it runs nothing. Actions (reconcile now, a drift check) come later, narrow and audited.

## Sign-in

OpenID Connect (authorization code + PKCE) against your identity provider, documented for Pocket ID, then a signed, HttpOnly session cookie. Members of
`cmdr_admin_groups` are admins, `cmdr_viewer_groups` viewers; anyone else is turned away. In the provider: a confidential client with callback
`<cmdr_url>/auth/callback`, scopes `openid profile email groups`, and the groups above. The page can sit inside the Muximux console (allow it with `cmdr_frame_ancestors`). Identity providers refuse to be
shown in a frame (Pocket ID sends `X-Frame-Options: SAMEORIGIN`), so a frame without a session cannot sign in: it shows a small "Sign in" panel that opens the
sign-in in a real tab, and reloads itself the moment the session cookie exists (both pages are on the same site, so the cookie reaches the frame). After
that the frame just works until the session expires (8 hours).

A trusted proxy may instead pass the identity in `Remote-User` / `Remote-Groups` headers, but only together with the shared secret `cmdr_proxy_secret` in an
`X-Cmdr-Proxy` header that the proxy adds; headers without it are ignored, so a client on the tailnet cannot forge them.

## Run

`scripts/cmdr.sh init` (in the fleet repo) stores the client id and secret and a generated session secret in the secret `cmdr.server` and tags the host
`util: [cmdr]`. The container is a stock `python` image running a standard-library script from `/opt/cmdr/app` (read-only, no capabilities, no build step).
Tested against a mock identity provider and a mock Loki (sign-in flow, wrong group, tampered cookie, forged headers, open redirect, path traversal) and in a
browser against the real fleet repo; not yet on the fleet.

## The page

- **Look:** charcoal and brass, mono type for anything you could type; follows the system light/dark setting (button in the header overrides, remembered per browser).
- **Status strip:** hosts, who is reporting, last reconciles, public exposure; the red tiles filter the host list to the problems.
- **Launchpad:** `cmdr_tools`. **Hosts:** cards or rows, sorted by what needs attention, filterable.
- **Command palette** (Ctrl/Cmd+K, `/` filters hosts): hosts, services, tools and commands. **Command buttons** copy a ready-to-paste command
  (`cmdr_host_commands`, `cmdr_commands`, `{host}` filled in) - cmdr itself never runs anything on a host. **Refresh** (POST `/api/refresh`) re-reads live
  status from Loki now; it is the only thing the page can do.
- **Sign-in in a frame:** the identity provider cannot be framed, so the frame shows a branded panel; sign-in opens in a small window that tells the frame
  at once (BroadcastChannel; polling is the fallback) and closes itself after 3 seconds.
- **Host cards** are segmented: the status line, CPU / MEM / DISK bars (with `cmdr_victoria_url` and hosts running `otel_agent_hostmetrics`), then the tags grouped by kind
  (**Provides** = util, **Runs** = feat, **Settings** = prop), then **Serves** (the hostnames, as links; dashed = LAN and tailnet only). The page's "How to read a host
  card" key explains it. Kind names, meanings and colours are `cmdr_tag_kinds`; any single tag can be renamed, described or recoloured in `cmdr_tag_overrides`.
  The host drawer adds 6-hour CPU and memory charts.
- `cmdr_idp_name` names the identity provider on the sign-in panel ("Sign in with Inti").
- **Profile picture:** the `picture` claim from the identity provider is shown as your avatar in the header. It is read at every sign-in (the session is rebuilt then), so a changed picture appears the next time you sign in. Only an https URL on the identity provider's own host is accepted, and the page's CSP allows images from that host only.
