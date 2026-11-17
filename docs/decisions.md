# Decisions

Numbered, never reused. A reversed decision gets a new entry that supersedes the old one.

## 1. Check before apply only when something changed

**Chosen.** `RECONCILE_PRECHECK=auto` (the default): `reconcile.sh` runs the check pass only when either repo's commit differs from the last successful apply. A scheduled pass over the same commits goes straight to apply.

**Why.** A run is dominated by per-task cost (a measured pass took about 76 seconds across roughly 80 tasks on a small ARM VM, with no single slow task), and a check pass doubles it. The check exists to catch a bad *new* change before it is applied; a repeat over commits that already passed adds little.

**Cost.** A drift-correction pass no longer has a pre-check of its own, so an environment change (a package removed, a disk full) can fail in apply instead of check. The apply still fails the run loudly; it does not hide it.

**Rejected.** Skipping the apply when the check reports no changes: tasks that are skipped in check mode (some `command` and `shell` tasks) would never run, which loses behaviour. Removing the check altogether.

**Revisit if.** A drift-correction apply breaks a host in a way a check would have caught; or the check pass is made cheap enough to always run. `RECONCILE_PRECHECK=1` restores the old behaviour per host.

## 2. Do not gather facts twice in one run

**Chosen.** The second play in `hosts/site.yml` sets `gather_facts: false`; facts from the first play persist for the run. Saves a second or two per pass. **Cost.** Anything in that play that expects a fact changed by the first play's tasks (not just gathered) would see the old value; none is known. **Revisit if** a role in the second play needs fresh facts.

## 3. Rollback is `safe_apply` where it is adopted, and not yet everywhere

**Chosen.** Record the gap honestly instead of claiming conformance with conformIT's principle 12. `otel_agent`, `forgejo_runner` and `zwave_js_ui` validate, keep a copy, apply, health-gate and restore. **Cost.** The other service roles can still leave a service down after a bad config until the next fix. **Revisit when** a role's incident shows the cost, or when moving a role onto `safe_apply` is cheap; do the roles that run the host's own access path (Traefik, Tailscale-adjacent) first.

## 4. Docs state what is managed and what is not, in two places

**Chosen.** A short pair of tables in the README (the contract a reader needs first) and the full `docs/ownership.md` with mechanism and backup per row. **Cost.** Two tables to keep in step. **Rejected.** Leaving ownership implicit in each role README. **Revisit if** the two drift; then generate one from the other.

## 5. Licence: MIT

**Chosen.** MIT, matching conformIT's code licence, copied from there. **VERIFY.** This was chosen by the assistant to complete the required file set; the maintainer should confirm it, especially given that some adopted components are AGPL or non-commercial (see [credits.md](credits.md)), which affects what anyone may do with a *deployment* but not with this repo's own code. **Revisit** on the maintainer's word.

## 6. No naming history, no cross-project lineage in the docs

**Chosen.** The README and `VISION.md` no longer record earlier names or relate the project to unrelated siblings. The maintainer judged both noise. History stays in git. **Cost.** A reader of old issues may not recognise the old names.

## 7. Em dashes replaced repo-wide with spaced hyphens in older files

**Chosen.** To satisfy conformIT's mechanical check without rewriting every sentence, older text had the em-dash character with spaces replaced by ` - `. New and rewritten prose avoids both. **Cost.** Some older sentences read less well than a rewrite would. **Revisit** when those files are next edited for content.

## 8. Disable apt download retries while CVE-2026-109518 is open

**Chosen.** The `baseline` role writes `/etc/apt/apt.conf.d/99consigliere-apt-retries` with `Acquire::Retries "0"` on every node, including Proxmox nodes (`baseline_apt_retries`, default `0`). The flaw lets an on-path attacker swap a verified package by forcing download retries. **VERIFY.** The setting is a stopgap reported by secondary sources; the APT team's advisory and the Debian and Ubuntu notices say only to upgrade apt, and name no workaround. The real fix is a fixed apt (2.2.5, 2.4.15, 2.6.2, 2.8.4, 3.0.4 or later). **Cost.** A flaky mirror now fails an apt run instead of retrying. **Rejected.** Relying on this alone; Proxmox nodes have unattended upgrades off, so they need `apt install --only-upgrade apt` by hand. **Revisit when** every host runs a fixed apt: set `baseline_apt_retries: null` (the file is then left in place, so remove it by hand) or back to `3`.

## 9. Windows hosts: pull-only PowerShell reconciler, designed first

**Chosen.** A Windows 11 Pro VM is reconciled by a Scheduled Task running PowerShell role scripts that pull both repos, decrypt with sops and age, and apply idempotent roles, in a new `windows/` tree. WinGet installs the pinned tools. First scope: time, Windows Update with a reboot window, Defender, firewall, tailnet-only SSH and RDP, Tailscale and the OpenTelemetry collector. The design is [windows-host.md](windows-host.md); nothing is built. **Cost.** A second reconciler to maintain beside `reconcile.sh`, and Windows roles cannot share Ansible modules or playbooks. **Rejected.** Ansible in WSL2 (a Linux layer on every host); PowerShell DSC (another language, DSC v3 still moving); push over WinRM (breaks the pull-only model). **VERIFY.** WinGet running as SYSTEM, and the collector's availability through WinGet. **Revisit if** the Windows roles grow enough that a shared role format with the Linux side would pay for itself, or WinGet proves unreliable unattended.

## 10. Windows hosts need PowerShell 7.4 or later

**Chosen.** The Windows reconcile and roles require PowerShell 7.4+ (`#Requires`); `bootstrap.ps1` stays valid Windows PowerShell 5.1, installs `Microsoft.PowerShell` through WinGet when it is missing and restarts itself under `pwsh.exe`; the Scheduled Task runs `pwsh.exe`. The maintainer asked for the latest PowerShell as a prerequisite. **Cost.** One more package on every host, and `bootstrap.ps1` carries a small 5.1 compatibility layer (no 7-only syntax in that one file). **Rejected.** Supporting 5.1 in the roles: it needed workarounds already (native stderr becoming errors, no IANA time zone conversion, no `-AsHashtable`). **Revisit if** a role must run before PowerShell 7 can be installed.

## 11. PowerShell 7 comes from the pinned release zip, not WinGet

**Chosen.** `bootstrap.ps1` unpacks `PowerShell-<version>-win-x64.zip` (or arm64) into `C:\Program Files\PowerShell\7`, checked against a pinned SHA-256, and adds it to the machine PATH. **Why.** The first test on the VM showed WinGet reporting `Microsoft.PowerShell` as installed while `pwsh.exe` was not in Program Files: 7.7.0 is published only as an MSIX bundle and zips (no MSI), and an MSIX lands in the user's profile, out of reach of the SYSTEM Scheduled Task. **Cost.** The version is bumped by hand (version and two checksums), and WinGet will not upgrade it. **Rejected.** `Add-WindowsFeature` and `Add-WindowsCapability` (PowerShell 7 is not a Windows feature; only Windows PowerShell 5.1 is); an older WinGet-installed MSI version (pins the fleet to a release that is about to age out). **Revisit if** PowerShell ships a machine-wide installer again. This refines entry 10; the prerequisite itself is unchanged.

## 12. Nothing the Windows reconcile uses may live in a user profile

**Chosen.** The reconcile runs as SYSTEM, so every dependency is machine-wide. WinGet is used only at enrolment, in the administrator's session, with `--scope machine` and no fallback, for `Git.Git` and `Tailscale.Tailscale` (both have machine-scope installers; git's location is checked afterwards). PowerShell 7, sops and age are the vendors' release files with pinned SHA-256 values (entry 11 covers PowerShell). The scheduled task never calls WinGet. **Cost.** Three tools are upgraded by editing a version and checksums, not by WinGet. age publishes no checksum file, so its pins are the hashes of the zips as downloaded when they were written. **Rejected.** WinGet for everything (MSIX and portable packages are per-user); WinGet run as SYSTEM from the task (unreliable, and it would change versions unattended). **Revisit if** WinGet gains a dependable SYSTEM mode, or a tool's vendor starts publishing checksums or signatures we can pin instead.

## 13. age pins are checked against Sigsum proofs when bumped

**Chosen.** Entry 12 said age publishes no checksum file; that was too narrow. Each age release asset has a GitHub-recorded SHA-256 (the pinned values match it) and a `.proof` file, a Sigsum transparency-log proof tied to the maintainer's signing keys. `windows/tools/verify-age-pins.sh` verifies both zips' proofs with `sigsum-verify` and compares the pins, and is run when the age version is changed. Hosts still compare only the SHA-256, so the bootstrap needs no extra tool. **VERIFY.** The script has not been run: installing `sigsum-verify` was blocked in the session that wrote it. **Cost.** A bump needs `sigsum-verify` on an admin machine. **Rejected.** Verifying the proof on each host (needs the Go verifier on Windows too). **Revisit if** more tools publish Sigsum proofs, or the bump check should move into CI.

## 14. A mirror outage must not stop the whole reconcile

**Chosen.** The baseline's apt step is now three tasks: refresh the package lists (a failure is reported, not fatal), say so when it failed, then install the baseline packages without forcing a refresh. A `baseline_apt_retries` of `null` now removes the drop-in instead of leaving it. **Why.** On the first day of the `Acquire::Retries "0"` stopgap (decision 8), ampere's reconcile failed at "Install baseline packages": its cloud provider's Ubuntu mirror returned 503 for every index file for over two minutes, and the single apt task stopped every role after it. **Cost.** A host whose lists are stale will install packages from them; the install still fails if something it needs is truly missing. **Revisit if** a stale cache ever causes a wrong install. Decision 8's stopgap is no longer needed on the hosts checked (all on a fixed apt); setting `baseline_apt_retries: null` in the fleet removes it.

## 15. One access policy for Windows remote access; SSH by firewall, not by bind address

**Chosen.** `windows_access` (`tailnet` or `lan`) controls Remote Desktop and SSH together, defined in `windows/defaults.yml` with the shared `windows_tailnet_ranges`; the reconcile merges that file below everything the fleet sets. The `ssh` role installs the OpenSSH Server capability, writes a marked block at the top of `sshd_config`, writes `administrators_authorized_keys`, sets the default shell, and scopes port 22 with a firewall rule made before the any-source rule is turned off. **Why.** The maintainer asked for tailnet-only SSH as part of a locked-down policy, and the first run showed a tailnet-only RDP rule cutting off a LAN session on a host not yet on the tailnet. **Cost.** Reachability rests on the Windows firewall, not on where sshd listens; a host with the firewall off (`windows_firewall_manage: false` and another tool) would expose port 22. The older `windows_rdp_tailnet_only` is still honoured so a half-updated fleet cannot lock a host out; remove it from the role once no host sets it. **Rejected.** `ListenAddress` set to the Tailscale IP (sshd can start before Tailscale has an address and then not listen); Tailscale SSH (Windows cannot be a Tailscale SSH server). **VERIFY.** Everything touching Windows: the capability install, `sshd -t`, the firewall rules. **Revisit if** the role needs to support passwords-only hosts, or another OS joins the policy.

## 16. No WinGet on Windows hosts; Tailscale unattended by policy

**Chosen.** `bootstrap.ps1` no longer uses WinGet. git is MinGit (Git for Windows' minimal zip, pinned SHA-256 from GitHub's asset digests, in Program Files\MinGit); Tailscale is the vendor's MSI (pinned SHA-256 from the `.msi.sha256` files) installed with `TS_UNATTENDEDMODE=always`; ssh-keygen comes from Windows' own OpenSSH client. A new `tailscale` role keeps the service running and sets `UnattendedMode = always` under `HKLM\SOFTWARE\Policies\Tailscale`. **Why.** The maintainer's direction was to move away from WinGet wherever the apps cannot run as SYSTEM, and the first test host showed Tailscale not connecting until someone logged in, which on Windows is the default unless unattended mode is on. The tools WinGet had installed did run as SYSTEM, but every tool already pinned (PowerShell, sops, age) was a vendor release, WinGet is absent on some editions, and one install path is simpler than two. **Cost.** Four more version-and-checksum pins to bump by hand; Tailscale updates itself afterwards, so its pin only matters for first installs. **Rejected.** Keeping WinGet for git and Tailscale; the Git for Windows installer (a GUI-era installer where a zip will do). **VERIFY.** The MSI install flags, MinGit's behaviour under SYSTEM, and that Tailscale applies a changed policy without a restart. This supersedes the WinGet parts of entries 11 and 12.

## 17. The Arcane agent role knows both naming styles and fails when the agent will not stay up

**Chosen.** Arcane 3 (the `next` images) reads only ARCANE_-prefixed settings (`ARCANE_AGENT`, `ARCANE_AGENT_TOKEN`, `ARCANE_MANAGER_API_URL`, `ARCANE_AGENT_TRANSPORT`) and refuses to start on the old names; Arcane 2 and earlier read the old names. `arcane_agent_env_prefixed`, worked out from `arcane_agent_version`, picks the style, and the old `poll` transport becomes `auto` in the new style. After starting the container the role now fails the run if the agent is not running, is restarting, or has restarted five times or more. **Why.** On 2026-11-06 the fleet moved all six agents to `agent:next` with the old names, so every agent crash-looped (about 8,500 restarts each) for six days with every reconcile reporting success, because `docker compose up` succeeded. The change was not verified after the reconcile; it was marked as an unchecked guess and then not checked. **Cost.** A new container waits 15 seconds in the run that creates it. `latest` is assumed to be the old style until the variable is set. **Rejected.** Pinning a tag (Arcane updates its own agents from its UI and an older agent refuses a newer database); checking only that `docker compose up` succeeded. **Revisit when** `latest` becomes Arcane 3.

## 18. Alpine hosts use the container reconciler, not native Alpine support

**Chosen.** An Alpine host (the first is a Proxmox LXC Docker host) gets Docker and Tailscale from `apk` through `hosts/bootstrap/alpine/bootstrap-alpine.sh`, and is then reconciled the way Unraid is: one container runs `reconcile.sh` through the Docker socket (`hosts/site-unraid.yml`). `bootstrap.sh` detects Alpine and hands over.

**Cost.** Only container-based roles run. There is no host baseline, no firewall role, no `tailscale` role (joining the tailnet is done by hand once), and no OpenTelemetry agent, because that one is a native systemd service. The host's own updates are not scheduled.

**Rejected.** Native Alpine support (Ansible on the host, an OpenRC or cron loop, Alpine branches in about 15 roles that use apt or systemd). It would give full parity, but it touches roles that every Debian host runs, for one small host.

**Revisit when** a second or third Alpine host needs host-level logs or metrics, or when the OpenTelemetry role can run as a container.


## 19. A platform layer: one profile per host, roles declare what they need

**Chosen.** Platform knowledge moves out of `bootstrap.sh`, the five entry playbooks and the roles into one place. A `platform` role works out `platform_family` (debian, alpine, macos, unraid), `platform_arch` (amd64, arm64, ...), `platform_runtime` (`host` when Ansible changes the machine itself, `container` when the reconciler runs in a container on a Docker socket) and `platform_capabilities` (`host`, `apt`, `apk`, `systemd`, `openrc`, `launchd`, `docker`, `ufw`), from the Ansible facts plus a data file per family in `hosts/platforms/`. A role that cannot work everywhere says what it needs in a `platform.yml` next to its tasks (`requires: [host, apt, systemd]`). `fleet_plan` compares the two before it runs an item and, when something is missing, skips it with a message that names the missing capability, instead of failing halfway or being left out of one playbook by hand. Roles with no `platform.yml` run wherever a tag selects them, as before, so the change is adopted role by role.

**Cost.** One more role to run first, one more small file per host-bound role, and a vocabulary of capabilities to keep small. Declarations are written by hand: a scan for `apt` or `systemd` in a role overstates it (restic_server and safe_apply mention both conditionally and already run on Unraid), so a wrong declaration can skip a role that would have worked. The first step changes no behaviour on a Debian host; that is checked by running a check-mode pass before and after.

**Rejected.** Making the roles portable by branching inside each task on `ansible_os_family`: it spreads the platform knowledge again, which is the problem. One implementation for every firewall (ufw, nftables, pf, Windows Firewall): they are different mechanisms, so they stay separate roles behind one name. Deriving the capabilities only from facts: inside the container reconciler the facts describe the container, not the host.

**Revisit when** the capability list grows past about ten entries, when a role needs a version of a capability (systemd 252 or newer, say), or when a profile needs more than data (code per platform).

**Next steps (not done in this change).** Merge `site-unraid.yml` into `site.yml` once the planner skips unsupported roles reliably; convert the apt-bound roles to package and service abstractions (baseline, docker, tailscale first); a CI matrix that runs the roles in Debian 13, Ubuntu 24.04 and Alpine containers; an `os:` attribute in the host table.

## 20. One entry playbook; the container reconciler is `site.yml` with a runtime setting

**Chosen.** `hosts/site-unraid.yml` is gone. `site.yml` serves every Linux-like host: `become` follows `platform_runtime`, and the base roles (baseline, tailscale, sops, docker: `fleet_plan_base_roles`) go through the same platform check as the roles the tags select, so a container host skips them with a message instead of being left out of a separate file by hand. `reconcile.sh` takes `RECONCILE_RUNTIME=container`, and still accepts `RECONCILE_PLAYBOOK=site-unraid.yml` as the same thing, so a host set up earlier (Unraid) needs no new bootstrap. The firewall step also checks the platform (needs `host` and `ufw`).

**Cost.** Four extra skipped-role messages in a container host's log on every run. The base roles now run through `include_role` inside `fleet_plan` instead of `roles:`; handlers still run when the first play ends, as before. A fleet that kept its own `site-unraid.yml` is unaffected (its file still wins).

**Rejected.** A `site-unraid.yml` that imports `site.yml`: reconcile.sh copies the chosen playbook to a run directory under the name `site.yml`, so it would import itself.

**Revisit when** a platform needs a task in the first play that no role can express, or the skipped-role messages hide real output (then a quieter summary line instead).

## 21. `os` and `arch` in the host table; the table informs container hosts, the facts decide host runs

**Chosen.** The host table takes two optional attributes, `os:` (debian, ubuntu, alpine, unraid, macos, windows) and `arch:` (amd64, arm64), which also become groups (`os_alpine`, `arch_amd64`). The fleet's scripts read `os:` to tell how a host is reconciled (a container for alpine and unraid, systemd otherwise), replacing the single `type: unraid` special case in `reconcile-now` and `fleet-run`. The `platform` role uses `os:` as the platform family only in a container run, where the facts describe the container; in a host run the facts win and a disagreement with the table is logged.

**Cost.** One more thing to keep right in the table, for the hosts that need it. A container host with no `os:` is treated as a systemd host by the scripts (and `reconcile-now` fails on it with `systemctl: not found`, which is how this was found on the first Alpine host).

**Rejected.** A separate `reconciler: container` attribute (one more name for what `os:` already says, and it would not feed the platform layer). Letting the table override the facts in a host run: a wrong entry would make a host run another platform's roles (apt on a Mac).

**Revisit when** a platform can be reconciled either way (Alpine on the host with OpenRC, per decision 19's later steps): `os:` alone will not say which, and the table will need a second attribute or the scripts will need to ask the host.

## 22. The platform layer knows releases and tool versions, compared the Debian way

**Chosen.** The `platform` role also publishes `platform_version` (the distribution's name, full and major version, release name), a profile can carry release-specific overrides (`versions:`), and a role can require a version of a tool on the host (`requires_version` in its `platform.yml`, checked by the planner like a capability). Tool versions are read by a command from the profile's `tools:` map, only when something asks, and cached. Versions are compared by two filters in `hosts/plugins/filter/` that follow Debian Policy 5.6.12 (the ordering dpkg uses), tested in `hosts/tests/`. `baseline_apt_retries: auto` is the first user: the stopgap for the apt retry vulnerability applies only where the installed apt is in a listed vulnerable range.

**Cost.** A Python plugin to maintain, and a version command per tool per platform. The vulnerable ranges for apt are a reading of secondary reports and are marked VERIFY; `auto` is opt-in, and the default (`0`) is unchanged. In a container run the release and the tools of the machine are unknown, so a version requirement is unmet there (a role that must run on a container host must not declare one).

**Rejected.** Ansible's `version` test (wrong for `~`, epochs and distribution suffixes). Deciding by the distribution release alone: the vulnerability follows the apt package version, which differs by branch and can be updated or backported independently of the release. Reading every tool's version on every run: it costs a command per tool for nothing.

**Revisit when** a platform needs a comparison dpkg's rules get wrong (Alpine's `-r` revisions are only approximated), or when reading versions costs enough to cache across runs.

## 23. Routes kept one file per domain, each route says which host serves it

**Chosen.** Traefik routes can be written in `config/routes/<domain>.yml` in the fleet repo, one file per domain or zone. A file may set a default `via` (the host or list of hosts whose Traefik serves its routes) and the `cert` that covers its names; a route can override `via`. The `fleet_routes` lookup (`hosts/plugins/lookup/`) returns the routes whose `via` names a host, and `traefik_server` turns each domain's routes into a route variable of its own, so everything downstream (conflict checks, templates) is unchanged. The existing `traefik_server_routes*` variables keep working and add up with the files, so hosts move over one at a time. A file that is not valid stops the run with every problem listed; a host that does not serve the certificate a file names is refused.

**Cost.** Two places can define routes during the move. A mistake in a domain file can affect every host that serves routes from it (validated before push and by the role). The per-host file is no longer the place to see what a host serves: `scripts/routes.sh` and Cmdr show that view.

**Rejected.** Tagging hosts with the domains they serve: one domain's routes are usually split across hosts (public and internal), so a host tag would mean all or nothing for a file; `via` per route with a file default covers both. Deriving each host's `cert:` tag from the files in this step: the tag also selects roles and secret grants at planning time, before the routes are read, so for now the files name the certificate and the role checks it agrees with the host.

**Revisit when** the check is more of a chore than a help (then derive the certificate from the files, which means teaching the planner to read them), or when a route needs different settings on each of the hosts that serve it.

## 24. Package, repository and service tasks in the platform role; roles degrade by capability

**Chosen.** The platform role has three tasks every platform answers (`tasks_from: package`, `repo`, `service`), driven by the profile: apt, apk or the generic module for packages; the vendor's key and source file on apt (moved from the docker and tailscale roles, behaviour unchanged) and the community repository on Alpine; `systemd` or `service` for services, with the profile's `packages:` and `services:` maps giving each platform's names. `docker` and `tailscale` use them and declare `requires: [host, package, service]`; `baseline` declares only `host` and guards its apt-only parts (retry setting, lists, unattended upgrades) and its systemd-only parts by capability, so it runs on a host with a different package manager and init. The sshd reload handler has an OpenRC variant. A matrix in `ci/` runs the platform layer in Debian, Ubuntu and Alpine containers on every push.

**Cost.** One more layer between a role and `apt`, so a Debian-only reader has to look in `hosts/roles/platform/tasks/`. The Alpine paths (community repository, `conf.d` ordering for docker, the OpenRC handler) are tested only in a container, not on a long-lived Alpine host, until one runs the reconciler on the host itself (decision 18). The UDP GRO tuning and the firewall stay systemd and ufw only.

**Rejected.** `ansible.builtin.package` for everything: it cannot refresh an index or tell apt to update on install, which tailscale relies on. A per-distribution copy of each role: that is the Debian-only shape this removes.

**Revisit when** a platform needs a task the three do not cover (a repository with a different mechanism, a service with a different state model), or when the matrix gets slow enough to matter.

## 25. `schedule` and `boot_task`: the same job, a systemd unit or cron or local.d

**Chosen.** Two more primitives in the platform role. `schedule` runs a command on a schedule: on systemd it writes the service and timer the five timer roles (certwarden_agent, restic_mirror, exposure_watch, apt_updates, compose_updates) used to write, byte for byte (checked by rendering each role's old template and the primitive's with the same variables); elsewhere it installs a cron entry. The calendar stays a systemd expression, so the fleet's existing values keep working; a small translator turns it into cron fields and **refuses** what cron cannot say (a specific year, non-zero seconds, a day of the month together with a weekday) instead of guessing. `boot_task` runs commands at every boot: a systemd oneshot unit (nic_offload, byte for byte as before), or a `/etc/local.d/*.start` script under OpenRC. Those roles now declare `package`, `schedule` or `boot` instead of `apt` and `systemd`, and install `bash` and `python3` themselves where their scripts need them. Both are tested for real on Alpine (a scheduled job fires through crond; a boot task runs through local.d) in the container matrix, and on Debian by the byte comparison and the canary.

**Cost.** Cron cannot catch up a run that was missed while the host was off (systemd's `Persistent=true`); the primitive documents that, and these jobs (updates, mirrors, scans, certificate checks) run again at the next schedule. systemd-only options (`After=`, hardening such as `ProtectSystem`) are ignored under cron, so a job that relies on them is less isolated there. The scripts of these roles are bash and python; they are installed, not rewritten, and their behaviour on Alpine is only as tested as the primitives. The firewall's docker guard and tailscale's UDP GRO unit were left as they are: the first is tied to docker's own unit ordering, the second retires hand-made systemd units.

**Rejected.** A schedule expressed in cron syntax for everyone: it would change every systemd host's units. An emulation of `Persistent=true` with a stamp file: one more thing to test and explain for jobs that do not need it. Rewriting the role scripts for POSIX sh: no host needs it.

**Revisit when** a job needs a catch-up after downtime, or when a platform has a scheduler that is neither systemd nor cron.
