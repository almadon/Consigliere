# Command-line reference (framework side)

What runs on the hosts themselves. The admin scripts you run from your fleet repo (`scripts/*.sh`) are in the fleet repo's `runbooks/cli-reference.md`.

## `hosts/bootstrap/bootstrap.sh`: one-time setup of a new host

Run once, by hand or from cloud-init, as root. Detects the kind of host (Debian and Ubuntu continue; Unraid and macOS hand over to their own setup),
installs Tailscale, Docker's prerequisites, Ansible, sops and age, clones both repos, makes the host's deploy key and age key, runs a **check** pass, and
(after you approve, or with `BOOTSTRAP_APPLY=yes`) applies and installs the 20-minute timer.

| Variable | Meaning |
|---|---|
| `FRAMEWORK_REPO_URL` (required) / `FRAMEWORK_REPO_BRANCH` | This repository; branch empty = the remote's default |
| `FLEET_CONFIG_REPO_URL` (required) / `FLEET_CONFIG_REPO_BRANCH` | Your private fleet repo |
| `FLEET_CONFIG_REGISTER_TOKEN` | A GitHub token allowed to manage that repo's deploy keys. Used once, never stored, so the host registers its own read-only deploy key. Without it the host prints the key and waits |
| `FLEET_CONFIG_DEPLOY_KEY_FILE` | Use a deploy key you already have instead of generating one |
| `NODE_NAME` | Sets the OS hostname first (lower-case, short): until a host is on the tailnet the fleet identifies it by its hostname, which must equal its key in `hosts.yml`. Also fixes `127.0.1.1` in `/etc/hosts` and stops cloud-init renaming it back. Cloud images usually name the machine after the instance, so set this for them |
| `TAILSCALE_AUTHKEY` | Auth key for joining the tailnet; asked for (hidden) if unset and the host is not yet on the tailnet |
| `BOOTSTRAP_APPLY=yes` | Non-interactive: apply and install the timer. Without it a non-interactive run only checks |
| `CONSIGLIERE_PROFILE=debian\|unraid\|macos` | Override the host-kind detection |
| `HEARTBEAT_URL`, `HEARTBEAT_FAIL_URL` | Optional pings on a successful or failed reconcile (healthchecks.io style; failure URL defaults to `<url>/fail`) |
| `RECONCILE_MODE=check\|apply` | Written into `/etc/fleet-reconcile.env` for the timer |

The host prints its **age public key** at the end: register it from your admin machine with `scripts/node.sh key <name>` (or `scripts/access.sh add-host`).
Architectures: x86_64 and aarch64 (ARM64) both work; see [platforms.md](platforms.md).

`bootstrap.sh` also runs `install-ansible.sh` (`ANSIBLE_BUNDLE_VERSION`, default 12.0.0; see [platforms.md](platforms.md#ansible-on-the-host)) and `install-sops.sh`; both can be run by hand and do nothing when already satisfied.

## `hosts/bootstrap/reconcile.sh`: the reconciler

Run by `fleet-reconcile.service` (timer: 2 min after boot, then every 20 min, randomised by up to 3 min). Pulls both repos, assembles a throw-away run
directory, runs **check first**, and applies only if the check succeeded. Everything it prints goes to the journal (`journalctl -u fleet-reconcile`) and to
`<workdir>/last-run.log`.

| Variable | Meaning |
|---|---|
| `RECONCILE_MODE` | `apply` (default: check, then apply) or `check` (report drift only, change nothing) |
| `RECONCILE_PRECHECK=0` | Skip the check pass (bootstrap does, after you approved the first check by hand) |
| `RECONCILE_WORKDIR` | Work directory (default `/opt/fleet-reconcile`) |
| `RECONCILE_CRED_DIR` | Host credentials: deploy key, age key (default `/etc/fleet-reconcile`) |
| `RECONCILE_PLAYBOOK` | Entry playbook (default `site.yml`; Unraid uses `site-unraid.yml`) |
| `FLEET_CONFIG_SUBDIR` | Where config lives inside the fleet repo (default `config`) |
| `ANSIBLE_EXTRA_ARGS` | Extra flags passed to `ansible-playbook` (word-split) |
| `HEARTBEAT_URL`, `HEARTBEAT_FAIL_URL` | Pinged on success and on failure |
| `RECONCILE_NOTIFY_CHANGES=0` | Do not send the "applied N change(s)" note (failures and recoveries are still sent) |
| `RECONCILE_NOTIFY_REPEAT_SECS` | Repeat a failure notification at most this often (default 21600 = 6 h) |
| `RECONCILE_STATE_DIR` | Where it remembers the last reported failure (default: the work directory) |

The first four lines of settings live in `/etc/fleet-reconcile.env`. Reports go through `fleet-notify` when the `apprise` feature is installed (see below).
On demand: `systemctl start fleet-reconcile` (or `scripts/reconcile-now.sh` from the fleet repo, which also waits and summarises).
A check-only run by hand: `set -a; . /etc/fleet-reconcile.env; set +a; RECONCILE_MODE=check /opt/fleet-reconcile/framework/hosts/bootstrap/reconcile.sh`.

## `hosts/bootstrap/unraid/bootstrap-unraid.sh`: Unraid

Same idea in a container (`--restart always`), reconciling every `RECONCILE_INTERVAL` seconds (default 1200) plus up to `RECONCILE_JITTER` (default 180).
Also: `CONSIGLIERE_DIR` (default `/mnt/user/appdata/consigliere`), `FLEET_CONFIG_REGISTER_TOKEN`, `HEARTBEAT_URL`/`HEARTBEAT_FAIL_URL`, `BOOTSTRAP_APPLY=yes`.
One run only: `docker exec consigliere-reconcile consigliere-loop once`.

## Helpers installed on hosts

| Command | From | What it does |
|---|---|---|
| `fleet-notify "<title>" ["<body>"]` | `apprise` role (`feat: [apprise]`) | Sends a notification through Apprise (body from stdin if omitted). Env `FLEET_NOTIFY_TAG` (default `alert`) picks which tagged URLs get it |
| `systemctl status fleet-reconcile` / `journalctl -u fleet-reconcile` | systemd | State and output of the last runs |
| `systemctl status otelcol-contrib` | `otel_agent` role | The log shipper (`feat: [otel]`) |
| `docker exec garage /garage ...` | `garage` role | Garage's CLI (`status`, `bucket list`, `key info <name> --show-secret`, ...) |
| `docker exec grafana grafana cli admin reset-admin-password '<new>'` | `grafana_server` role | Reset the break-glass admin password |
| `ls /etc/fleet-reconcile`, `/opt/fleet-reconcile` | | Credentials (deploy key, age key) and the work directory (both repos, last-run.log) |
