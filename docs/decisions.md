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
