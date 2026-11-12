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
