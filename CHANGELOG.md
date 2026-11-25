# Changelog

What changed and why, including reverts. Dates are absolute.

## 2026-11-25

- **Notification relay (decision 31).** New `util: [notify_relay]` and `feat: [notify]`: `fleet-notify` posts to one relay host, which holds the Home Assistant token and calls Supernotify. It exits non-zero when the alert is not accepted. Nothing uses it until a fleet adds the tags; `feat: [apprise]` is unchanged. Not yet run against a real Home Assistant.

## 2026-11-17

- **Host metrics from an LXC.** In container mode on an Alpine LXC the collector reported the Proxmox machine's CPU, memory and load as the LXC's (lxcfs shows the LXC its own `/proc`, but a Docker container inside it reads the kernel's, even through the `/hostfs` mount). They are now left out where the Docker daemon's memory is far below the kernel's, with a note in the run; filesystem metrics stay. A normal host and every systemd host are unchanged (the native render is byte-identical). Unraid's numbers were right all along: the memory states of the collector overlap, so they do not add up to the total, but the utilization that cmdr and the dashboards use is.
- **Quieter Docker proxy.** The read-only socket proxy behind `otel_agent` logged every request at HAProxy's info level, and the collector shipped those lines to Loki: on a Docker host it was the largest log source (893 lines in 15 minutes on one). `otel_agent_docker_proxy_log_level` (default `warning`) drops them. The proxy is recreated once on each Docker host.
- **`otel_agent` container mode, first real hosts.** It did not start on an Alpine LXC (no memory controller: `memory.max` missing) or on Unraid (an explicit `rslave` mount of `/` is refused when the root is not shared), and the next runs reported success with the collector not running. The memory limit is now probed and left out where Docker cannot set it, the host mount names no mode, and every run makes sure the collector is up. The test gained both cases.
- **`otel_agent` as a container.** On a host without apt and systemd (Alpine, Unraid, a container reconciler) the collector runs from its image under Docker, reading the host through read-only mounts: the system log from a file (`/var/log/messages` or `/var/log/syslog`, by platform), Docker logs, and host metrics through `/hostfs` when asked. `otel_agent_mode: auto` leaves every Debian and Ubuntu host on the native service, whose configuration renders byte for byte as before. Applied through `safe_apply`; the collector image's own `validate` checks the configuration. Decision 27, `ci/otel-container.sh`.
- **A platform layer.** What kind of machine a host is (family, release, architecture, whether Ansible changes it or runs in a container) is worked out once by the `platform` role from the Ansible facts and a profile in `hosts/platforms/`; roles declare what they need in `platform.yml` and `fleet_plan` skips a role a host cannot run, with a message. Decisions 18 to 26 record the choices. Each change was compared check-only against the previous version on a sample of the maintainer's Debian, Ubuntu and Proxmox hosts before it was merged, and showed no change.
- **One entry playbook.** `hosts/site-unraid.yml` is gone: `site.yml` serves every Linux-like host, and `RECONCILE_RUNTIME=container` (or the older `RECONCILE_PLAYBOOK=site-unraid.yml`, still accepted) runs it on a container host.
- **Alpine hosts.** `hosts/bootstrap/alpine/` installs Docker, Tailscale, OpenSSH and the admin key, then uses the container reconciler as Unraid does; `bootstrap.sh` detects Alpine. The host-level roles also run on Alpine with OpenRC in the CI matrix.
- **Host table: `os:` and `arch:`.** Optional for a host that runs Ansible itself; the fleet's scripts read `os:` to know a host is reconciled by a container (`reconcile-now`, `fleet-run`). Cmdr shows both as chips.
- **Releases and tool versions.** `platform_version`, per-release profile overrides, `requires_version`, and a Debian-style version comparison (Ansible's `version` test gets `~`, epochs and `ubuntu1` wrong). `baseline_apt_retries: auto` applies the apt retry stopgap only where apt is in a vulnerable range (opt-in; the ranges are marked VERIFY).
- **Six portable tasks** in the platform role: `package`, `repo`, `service`, `schedule`, `boot_task`, `artifact`. The systemd units of `certwarden_agent`, `restic_mirror`, `exposure_watch`, `apt_updates`, `compose_updates` and `nic_offload` are written through them, byte for byte as before (checked by rendering the old templates and the new output side by side); on a host without systemd they become cron entries and `local.d` scripts. cron cannot catch up a missed run.
- **Traefik routes by domain.** `config/routes/<domain>.yml` in the fleet repo: a default `via` and `cert` per file, `via` per route. Both layouts work and add up. Cmdr gained a Domains section.
- **Deprecations fixed:** top-level facts (`ansible_facts[...]`), the internal `vars` dictionary (the `vars` lookup), and `ansible.posix` 2.2.2 installed on the hosts from `hosts/requirements-hosts.yml` (the bundled 2.1.x imports from a removed module).
- **CI:** the `platforms` workflow runs the layer on Debian 13, Ubuntu 24.04 and Alpine 3.22 in containers; unit tests for the version, schedule and route code run in the same job.
- **Documentation reviewed:** the README, platforms, architecture, ownership, security, credits and STATE pages updated for the above; the Windows page's status corrected (it is experimental and has run on one VM); role READMEs added for `platform` and `fleet_plan`.

## 2026-11-01

- **Muximux 3.7.0 (from 3.6.2).** Released 2026-10-29. Embedded apps such as a Homarr dashboard can now switch Muximux to other apps (`allow_navigation`, off by default, per app), and the release updates `go-jose` for a denial-of-service fix. The role gains an optional `allow_navigation` field on tiles in `muximux_apps`; nothing changes for a tile that does not set it. The role's own pin is the only version change, so a host takes the upgrade at its next reconcile (the container image is pulled and recreated).

## 2026-10-28

- **Reconcile is faster on routine runs.** `RECONCILE_PRECHECK` now defaults to `auto`: the check pass runs only when a repo changed since the last successful apply. A scheduled drift-correction pass over commits already checked and applied goes straight to apply, roughly halving its time. `RECONCILE_PRECHECK=1` restores the old always-check behaviour. Measured on an Oracle ARM VM: one pass took about 76 seconds, spread over roughly 80 tasks, so there was no single slow task to fix.
- `site.yml`: the second play no longer gathers facts again; the first play's stay available.
- `RECONCILE_PROFILE=1` prints per-task timings.
- Documentation brought onto the conformIT standard: README redesign with a layer diagram and a managed/not-managed contract, `docs/ownership.md`, `architecture.md`, `security.md`, `credits.md`, `STATE.md`, `decisions.md`, `AGENTS.md`, `LICENSE`.
- Naming history and references to unrelated sibling projects removed from the docs.
