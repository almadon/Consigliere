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
- `muximux_auth: none` is refused unless `muximux_allow_no_auth: true`.
- The container drops all capabilities except `CHOWN`, `SETUID` and `SETGID`, which its entrypoint needs to start as root and then run as uid 1000. Verified: anonymous requests to `/api/apps` get 401.
