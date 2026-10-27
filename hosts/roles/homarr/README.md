# homarr

A [Homarr](https://homarr.dev) dashboard behind Traefik, signed in through your identity provider (OIDC; Homarr has no trusted-proxy-header sign-in).
Variables are documented in `defaults/main.yml`; the client id and secret and the encryption key are the secret `homarr.server`.

- **Pop-up sign-in** (`homarr_popup_login`, default on): for a dashboard shown inside a frame (for example a Muximux tile). Identity providers refuse to be framed, so a small
  nginx (`homarr-gate`, the Traefik backend `http://homarr-gate:8080`) injects a script that opens the sign-in in its own window, and reloads the frame when the session works.
  The frame and the dashboard must be on the same site (for example `cz.example.org` and `ds.example.org`) so the session cookie reaches the frame. Allow the framing parent
  with `frame_ancestors` on the route.
- Pin `homarr_image` by digest. The Docker socket is not mounted (Homarr's container integration is not used here).
