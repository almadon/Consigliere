# Deploying the coordination server (node 1)

One host runs: Arkeep server, Arcane manager, Semaphore, the console, and
(from the separate geotraefik repo) Traefik. Nothing here has run on a real
host yet - expect to fix things. What *has* been tested: the console
(mock Outline, forged session; see commit 441d837), shell syntax, template
rendering, lint. **Not** tested: real Outline/Pocket ID/Tailscale, the
Docker image build, any role on a real host.

## 0. Before touching the host
- Cloud firewall: allow inbound 80/443 (Traefik) and nothing else public.
  **Docker-published ports bypass ufw**, so ufw alone will not protect
  Arkeep (9090/8080), Arcane (3552), Semaphore (3000). Tailscale traffic is
  unaffected by the cloud firewall. Where you can, bind to the Tailscale IP
  (`arkeep_server_bind_address`).
- Your private fleet repo, created from `consigliere-fleet-template` (private),
  with `config/inventory/hosts.yml` (the host table, each host's `util:`/`feat:`
  values) and `groups.yml`, `config/vars/` filled in, and the secrets created and
  encrypted (`scripts/secrets.sh init-admin`, then `create`/`edit`). Run
  `scripts/preflight.sh --strict` in it: it must pass. The roles this host runs need
  these secrets: `arkeep.agent`, `arkeep.server`, `arcane.server`, `semaphore.server`.
- Add the host to `config/inventory/hosts.yml` (key = its Tailscale hostname)
  with `util:`/`feat:` for what it should run (e.g. `util: [arkeep]` for the server). Hosts already on the
  tailnet need no auth key; a brand-new host needs one (bootstrap prompts for one, or set
  `TAILSCALE_AUTHKEY` for that run; it is never stored).
- A GitHub token that may manage the fleet repo's deploy keys (optional; it
  lets bootstrap register the host's key automatically, otherwise you'll paste
  the key it prints).
- In Pocket ID: two user groups (viewer, admin) with you in the admin one, and
  an OIDC client allowed the `groups` scope.
- A heartbeat check (healthchecks.io or Uptime Kuma push) for this host.

## 1. Bootstrap the host (Debian, as root)
Get `hosts/bootstrap/bootstrap.sh` onto the host (it's in the framework repo),
then:

    FRAMEWORK_REPO_URL=https://github.com/almadon/Consigliere.git \
    FLEET_CONFIG_REPO_URL=git@github.com:<you>/<fleet-repo>.git \
    FLEET_CONFIG_REGISTER_TOKEN=<token, optional> \
    HEARTBEAT_URL=<your heartbeat url> \
    ./hosts/bootstrap/bootstrap.sh

The host generates its own read-only deploy key and has it registered (or
prints it for you to add and waits), then generates its age key and prints the public
half for you to grant (`scripts/access.sh add-host <name> <key>`, `sync`, push). The
first reconcile is check-only; you approve the apply and the timer. Watch
`journalctl -u fleet-reconcile -f`; expect the first failures here.

## 2. Verify each service (over Tailscale, not the public IP)
- Arcane   http://<tailscale-ip>:3552 - create the admin account.
- Arkeep   http://<tailscale-ip>:8080 - create the admin account; note the
  gRPC address <tailscale-ip>:9090 for agents.
- Semaphore http://<tailscale-ip>:3000 - log in with the `semaphore.server` admin password.
- Heartbeat check turns green after a successful reconcile.

## 3. Deploy the console (manual for now)
    cd /opt/fleet-reconcile/framework/stacks/console
    cp ../../console/.env.example .env      # fill in; git-ignored, survives reconciles
    echo CONSOLE_BIND=<tailscale-ip> >> .env
    # also set in .env: POCKET_ID_URL=<your Pocket ID base URL, i.e. the OIDC
    # issuer>, CONSOLE_VIEWER_GROUP=<viewer group>, CONSOLE_ADMIN_GROUP=<admin
    # group>. Unset groups = nobody can sign in (fail closed).
    docker compose up -d --build
In Pocket ID register an OIDC client with redirect URI
`<NEXTAUTH_URL>/api/auth/callback/pocket-id`. In Outline: create the
machines collection (one doc per machine, table convention in
console/README.md), an API token, and optionally the overview doc with its
markers. Then open the console and check, in order: login works → tiles
render → "Edit in Outline" links open the right doc → Sync overview works.
Likely failure points: Pocket ID claim names (flagged in auth.ts) and
Outline response shapes (flagged in outline/client.ts).

## 4. Traefik (geotraefik repo) - last
Only after 2–3 work. Then wire Arkeep/Arcane/console through it per
hosts/roles/arkeep_server/README.md and close the direct ports.

## 5. Then node 2
Add it to `hosts.yml` with `feat: [arkeep]` (and the others it should run), bootstrap the same way. Leave `wazuh_agent` and `arcane_agent` out of
`feat:` until a Wazuh manager exists / you've generated the
Arcane agent token.

## Not built yet
Adoption view in the console, the token broker, scheduled check-mode drift
runs in Semaphore (needs project setup in its UI), Wazuh server rollout.
