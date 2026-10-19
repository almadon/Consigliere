# grafana_server

[Grafana](https://grafana.com/oss/grafana/) OSS, bound to this host's Tailscale address (`grafana_server_port`, default 3105) for a
reverse proxy to front. Loki is provisioned as the default data source (`http://loki:3100` on the shared `observability` Docker
network); `grafana_server_datasources_extra` adds more.

- **Sign-in:** OIDC (`grafana_server_oidc_issuer_url`; the default paths fit Pocket ID). Create a confidential client whose
  callback is `<grafana_server_url>/login/generic_oauth`, scopes `openid profile email groups`. Members of
  `grafana_server_oidc_admin_groups` (default `Grafana-Admins`) become Admin, `grafana_server_oidc_editor_groups` Editor, everyone
  else the client lets in a Viewer. PKCE is on.
- **Secret** `grafana.server` (`config/secrets/grafana/server.yml`): `grafana_server_oidc_client_id`,
  `grafana_server_oidc_client_secret`, `grafana_server_admin_password`. `scripts/observability.sh init` in the fleet repo writes it.
  The local `admin` login stays as a way in if the identity provider is down (`grafana_server_local_login: false` removes it). The
  admin password is applied only when Grafana first creates its database; to change it later use
  `docker exec grafana grafana cli admin reset-admin-password <new>`.
- **Dashboards:** `grafana_server_dashboards` writes inline JSON to `/opt/grafana/dashboards` (read-only, provisioned); dashboards
  saved in the UI live in Grafana's database.
- The compose file (mode 0600) holds the client secret and the admin password.

Tested against Grafana 13.2.4 with Loki 3.7.8: check, apply, check, apply (the last two change nothing); the Loki data source reports
"successfully connected"; an inline dashboard is provisioned; the login redirects to the identity provider with PKCE.
