# Security

This project's instance of the security posture. Reporting a vulnerability is a separate matter; see `SECURITY.md` if one exists.

## Trust boundaries

- **Public repo, private fleet repo.** Nothing site-specific or secret enters this repo. The audit and review should treat a hostname, address, token or key here as a bug.
- **Each host trusts git, not a controller.** A push to `main` on either repo is applied on every host that tracks it. The lint gate and review are therefore the change-approval step; protect both repos' default branches.
- **A host reads only its own secrets.** Each secret file is encrypted to the age public keys of the hosts allowed to read it. The host's private key never leaves it.
- **The deploy key is read-only** and used for nothing but the fleet clone and fetch.

## Secrets

Backup credentials, API keys and tokens live in the fleet repo under `config/secrets/<kind>/<name>.yml`, sops-encrypted. The `load_secrets` role is the only code that reads them, so the backend can change. Tailscale auth keys are
never stored; `bootstrap.sh` prompts for one. The fleet template ships a pre-commit guard that refuses an unencrypted secret. A role that writes a credential to disk uses mode `0600` and `no_log` on the task.

## Network exposure

Hosts are closed to the world by default: ufw denies inbound except everything on the tailnet interface and ports a tag asks for. SSH is reachable over Tailscale, or from LAN networks listed in `firewall_ssh_from`; a host not yet on the tailnet
keeps SSH open, with a warning, so it cannot be locked out. Docker-published ports bypass ufw, so the `docker` role guards them. `exposure_watch` scans the public addresses on a schedule and reports anything the fleet did not declare.
Public web routes go through Traefik, with header profiles (`app`, `strict`, `relaxed`, `framed`) and sign-in through an OIDC provider.

## Known limits

- Cloud-provider firewalls are outside the reach of a host agent and are not managed.
- A host that is compromised can read the secrets it is a recipient of, and can push nothing, but it can run whatever its own reconcile applies. Revoking a host means removing its key from the recipients (`scripts/access.sh`) and re-encrypting.
- The age keys are not backed up by Consigliere; losing a host's key means re-adding the host.
- **VERIFY:** the Wazuh stack in `stacks/wazuh/` has default credentials that must be rotated before it leaves localhost; the procedure is in its README. It has not been run against a live host.
