# apprise_server

[Apprise API](https://github.com/caronc/apprise-api), the fleet's one notification service. Anything that needs to tell a person something POSTs to it; it forwards
to the real channels (Pushover, ntfy, e-mail, Telegram, ~100 others). The channel tokens live in its own configuration (edited in its admin panel), not in every host
and not in the fleet repository.

## How it is exposed

| What | Where | Who can reach it |
|---|---|---|
| Admin panel (web UI: channels, tags, test sends) | an internal name, for example `ntfy.sp.a64.one` (a Liaison route; `sp.a64.one` is LAN and tailnet only) | LAN and tailnet, **and** the admin login |
| Notify endpoint | a public name on a proxy host, for example `notify.a64.one`, route rule `Host(...) && Method(POST) && PathPrefix(/notify/)` plus a rate limit | the internet, but only that one call; any other path or method gets 404 |
| Grafana and other containers on the host | `http://apprise:8000` on the shared `observability` network | that host |

- **Stateless notify is off** (`APPRISE_STATELESS_MODE=disabled`): a caller cannot hand in its own target URLs, so the endpoint cannot be used as a relay. A call can only name a
  saved configuration key and its tags.
- **The key is a secret.** `/notify/<key>`: use a long random key (32+ characters) when you create the configuration in the panel. Give a different key to anything you may want to cut off on its own.
- Admin login is Apprise's basic auth (`apprise_server_admin_user`, the password is in the secret). Set each saved configuration to the **public** access mode in the panel, so a notify
  call with its key and a tag needs no login while the panel does. `tag=all` is refused for such configurations, so callers must name a tag (`alert`, `info`, ...).
- Container: unprivileged, read-only root, no capabilities, no attachments, memory-capped, published on the tailnet address (the proxy hosts reach it there).
- `ALLOWED_HOSTS` lists only the names above, the bind address and `apprise`.

## Setup

1. Fleet repo: `scripts/apprise.sh init` (asks for the admin password, generates the session secret, tags the host `util: [notify]`).
2. Routes in the fleet repo: the internal admin name on Liaison and the public notify name on the proxy host (see `config/vars/routes/liaison.yml` and `constant.yml`).
3. Reconcile the host, open the admin panel, sign in, add your channels (for Pushover: `pover://<user key>@<app token>`) with tags `alert` and `info`, save under a long random key, and set the key's access mode to public.
4. Test: `curl -X POST https://<public name>/notify/<key> -d tag=info -d title=test -d body=hello`.

Hosts then use it through `fleet-notify` (the `apprise` role): set `apprise_server_endpoint` and the key (secret `apprise.notify`), and no host holds any channel token.
