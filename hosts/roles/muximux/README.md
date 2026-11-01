# muximux

The fleet console: a [Muximux](https://github.com/mescon/Muximux) dashboard whose tiles come from the fleet repo
(`muximux_groups`, `muximux_apps`). Run it on one host (`util: [muximux]`), behind Traefik
(`muximux_network: proxynet` and a route to `http://muximux:8080`).

- Sign-in is OIDC (Pocket ID is documented): `scripts/console.sh init` in the fleet repo stores the client id and secret as
  `muximux.server` and tags the host in one step. The client secret sits only in the compose file (mode 0600).
- Two modes. Default: the config file is mounted read-only and the fleet repo is the only source of truth. With `muximux_user_editable: true`, the repo owns the tiles and
  groups it declares (restored if edited or deleted in the UI, removed when you remove them from the repo) and **everything else is yours**: tiles and groups you add, and after the first
  run the theme, navigation and other settings, all kept across runs. Sign-in settings and the listen address always follow the repo. The first merge keeps the old file as
  `config.yaml.pre-merge`; `managed.json` records which tiles the repo manages.
- Tiles open in a new tab by default: admin tools have their own sign-in, which cannot complete inside a frame.
- Health dots come from Muximux's own checks (`health_url` when the public address is not what should be checked).
- **Embedded apps can drive the console (Muximux 3.7.0 and later).** A dashboard such as Homarr, opened inside Muximux, can switch Muximux to another app, or to two apps side by side,
  with links to `https://<console>/#sonarr` or `#a+b`. This is off until `allow_navigation: true` is set on the app the click happens in (a tile's `allow_navigation` in `muximux_apps`, or the
  "Allow navigating Muximux" switch in the app's settings in the UI). **Turn it on only for apps you trust:** a `target="_top"` link inside such an app can send the whole tab to any website.
  The link's address before the `#` must be the address you have the console open on. Details: [Navigation from embedded apps](https://github.com/mescon/Muximux/wiki/apps#navigation-from-embedded-apps).
- `muximux_auth: none` is refused unless `muximux_allow_no_auth: true`.
- The container drops all capabilities except `CHOWN`, `SETUID` and `SETGID`, which its entrypoint needs to start as root and then run as uid 1000. Verified: anonymous requests to `/api/apps` get 401.

## Sign-in settings and what they become

| Variable | Muximux setting | Default |
|---|---|---|
| `muximux_oidc_admin_groups` | `MUXIMUX_OIDC_ADMIN_GROUPS` | `[Muximux-Admins]` |
| `muximux_oidc_groups_claim` | `MUXIMUX_OIDC_GROUPS_CLAIM` | `groups` |
| `muximux_oidc_scopes_extra` | added to `MUXIMUX_OIDC_SCOPES` (`openid,profile,email,groups` is always sent) | `[]` |
| `muximux_oidc_username_claim`, `_email_claim`, `_display_name_claim` | `MUXIMUX_OIDC_USERNAME_CLAIM`, `..._EMAIL_CLAIM`, `..._DISPLAY_NAME_CLAIM` | empty = Muximux's own defaults |

Muximux has no profile-picture support, so none is shown or imported. Settings that come from the environment are locked in Muximux's own settings page.
