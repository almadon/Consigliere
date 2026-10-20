# MailFlow stack

A self-hosted webmail client ([mailflow.sh](https://mailflow.sh), AGPL-3.0; source: github.com/maathimself/mailflow) for IMAP accounts. Four containers:
the nginx frontend, the Node backend, PostgreSQL 16 and Redis 7 -- all published for **amd64 and arm64**, so it runs on the Oracle Ampere VPS.
This compose file is the project's `docker-compose.ghcr.yml` trimmed to sit behind Traefik: nothing is published on the host, nginx speaks plain HTTP
(`NGINX_TLS=off`) on the shared `proxynet` network, and TLS comes from the Traefik host's certificate.

## Deploy

1. On the host: Docker and Traefik from Consigliere (`util: [docker, traefik]`, `cert: [a64.one]`), and `proxynet` in `traefik_server_networks`.
2. `cp .env.example .env`, fill the four secrets (the file says how), `APP_URL` = the public address.
3. `docker compose up -d` (or point Arcane at this directory).
4. Publish it from your fleet repo: `scripts/publish.sh --host <node> --name mail --domain mail.a64.one --backend http://mailflow-frontend:80`, push, DNS record, done.
   Traefik sets `X-Forwarded-Proto: https` itself, which MailFlow needs for its secure session cookies.
5. Open it; the **first account you register becomes the admin**. Register it before anyone else can reach the URL.

## Configure in the web UI (not possible through the compose file)

- **SSO:** Settings -> SSO. Any OIDC provider works; add a client in Pocket ID (callback shown on that page), then set the issuer, client id and secret there. A
  group claim (`groups`) plus an admin group name maps admins; you can disable password login once SSO works.
- **Mail accounts:** each user adds their IMAP/SMTP accounts under their own settings; credentials are encrypted with `ENCRYPTION_KEY`.
- Outbound only: it connects out to your mail providers (IMAP 993, SMTP 465/587). It does not need an inbound mail port. Note that Oracle Cloud blocks outbound port 25.

## Browser notifications (Web Push, optional)

MailFlow sends browser push notifications with a VAPID key pair that you generate **once** and keep. Generate it inside the backend container (which ships the `web-push` module) and append it
to `.env` without printing the private key:

    cd /opt/mailflow
    docker exec mailflow-backend node -e '
      const k = require("web-push").generateVAPIDKeys();
      process.stdout.write("VAPID_PUBLIC_KEY=" + k.publicKey + "\nVAPID_PRIVATE_KEY=" + k.privateKey + "\nVAPID_SUBJECT=https://mail.example.org\n");' >> .env
    docker compose up -d        # recreates only the backend

The public key is 87 characters and the private key 43. `VAPID_SUBJECT` is a contact the push services (Google, Mozilla, Apple) can see: use an https address of the site or a `mailto:`. If you
lose the private key nothing breaks except that existing browser subscriptions stop working and users re-enable notifications. Keep the new `.env` in your password manager.

## Back up (Arkeep)

State is in PostgreSQL plus your `.env`. An Arkeep policy on the node's agent: a **Command (stdin)** source named `mailflow-db` with
`docker exec mailflow-postgres pg_dump -U mailflow mailflow` (a consistent dump), and a Directory source for the folder holding `.env`. Do not back up the
raw Postgres volume while it is running. Avoid `docker compose down -v`: it deletes the volumes.
