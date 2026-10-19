# muximux

The fleet console: a [Muximux](https://github.com/mescon/Muximux) dashboard whose tiles come from the fleet repo
(`muximux_groups`, `muximux_apps`). Run it on one host (`util: [muximux]`), behind Traefik
(`muximux_network: proxynet` and a route to `http://muximux:8080`).

- Sign-in is OIDC (Pocket ID is documented): `scripts/console.sh init` in the fleet repo stores the client id and secret as
  `muximux.server` and tags the host in one step. The client secret sits only in the compose file (mode 0600).
- The config file is mounted read-only. The fleet repo is the source of truth; edit tiles there.
- Tiles open in a new tab by default: admin tools have their own sign-in, which cannot complete inside a frame.
- Health dots come from Muximux's own checks (`health_url` when the public address is not what should be checked).
- `muximux_auth: none` is refused unless `muximux_allow_no_auth: true`.
- The container drops all capabilities except `CHOWN`, `SETUID` and `SETGID`, which its entrypoint needs to start as root and then run as uid 1000. Verified: anonymous requests to `/api/apps` get 401.
