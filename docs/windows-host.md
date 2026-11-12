# Adding a Windows host (design, not built)

Status: **designed; `bootstrap.ps1`, `reconcile.ps1` and the `baseline` and `ssh` roles are written but have not been run on a host.** The inventory, group, variable and tag-selection
logic was exercised against the real fleet config on a Mac; everything that touches Windows (the task, WinGet, the Event Log) was not. The first target is one Windows 11 Pro VM on an Unraid host. This page is what the
baseline will do, so it can be corrected before scripts exist. [decisions.md](decisions.md) entry 9 records the choice.

The model does not change: the host reconciles itself, on a timer, from the public framework repo and the private fleet repo. Nothing
reaches into it from outside.

## Scope for the first version

Managed: time zone and clock, Windows Update, Defender, the firewall, remote access, Tailscale, observability, the reconciler itself.
Not managed: hostname, local accounts, installed apps, the power plan, anything the user does at the desktop. Not in this version:
feature parity with Linux roles, Docker-based features, `fleet-run.sh --update` and `--reboot`.

## Layout

A `windows/` tree next to `macos/`:

```
windows/
  bootstrap/bootstrap.ps1     one-time enrolment, run once as Administrator
  bootstrap/reconcile.ps1     the timed pull: git pull both repos, decrypt, run the roles
  roles/<name>/               one idempotent PowerShell script per role, with a README that opens with the contract block
  site.ps1                    the role order, and which tag manifests select which roles
```

Why not Ansible: it has no native Windows controller, so the choice is a Linux layer (WSL2) on every host or plain PowerShell. The
framework keeps one pull loop and a short list of roles, so plain PowerShell is the smaller change. Every role script follows the Ansible
rules in spirit: idempotent, a `-WhatIf` path where a cmdlet allows it, and a result of `changed` or `unchanged` that the reconciler logs.

## Prerequisite: PowerShell 7

The reconcile and every role need PowerShell 7.4 or later (`#Requires -Version 7.4`); Windows PowerShell 5.1, which a fresh Windows has, is
not enough. `bootstrap.ps1` is the one file kept valid for 5.1: when it finds an older PowerShell it installs PowerShell 7 from the project's
release zip (pinned version, SHA-256 checked) into `C:\Program Files\PowerShell\7` and starts itself again under `pwsh.exe`, passing its
parameters on (secrets by environment, not the command line). It is not installed with WinGet: 7.7 is an MSIX package, WinGet puts that
in the signed-in user's profile, and SYSTEM, which runs the reconcile, cannot use it. The Scheduled Task runs `pwsh.exe`. Roles can therefore use PowerShell 7 features and the .NET it brings.

## Reconcile loop

A Scheduled Task running `pwsh.exe` as SYSTEM, every 20 minutes with a random delay, no overlapping runs. Each run:

1. `git pull --ff-only` the framework and the fleet repo (same two-repo pattern as `hosts/bootstrap/reconcile.sh`; credentials never
   prompt).
2. Skip the apply when neither repo changed and the last run succeeded, as the Linux reconciler does.
3. Decrypt the host's secrets with `sops.exe` using the host's age key.
4. Run the roles in order, stop on the first failure, write one line per role to the Windows Event Log (source `Consigliere`) and a
   status file the telemetry reads.

The host is identified by its Tailscale name, like every other host, and looked up in `config/inventory/hosts.yml`.

## Enrolment

One command from an elevated PowerShell. The script needs the framework URL and a Tailscale auth key (or approves the node by hand):

1. Make sure PowerShell 7.4 or later is installed (it is a prerequisite, see below), then install git (MinGit), Tailscale, age and sops from
   pinned, checksum-verified vendor releases, all machine-wide.
2. Join the tailnet with the fleet's tag.
3. Create the host's age key and print its public half, so you add it to `config/access.yml` and run `scripts/access.sh sync` in the fleet
   repo (the same step a Linux host needs).
4. Clone both repos to `C:\ProgramData\Consigliere`.
5. Register the Scheduled Task and run the first reconcile.

## How a run picks its roles

The host is found in `config/inventory/hosts.yml` by its Tailscale name, and its values become groups through the `keyed_groups` of
`groups.yml` (`type_vps`, `util_traefik`, ...) plus `os_windows`. Variables merge as on Linux, with a later file replacing a whole key:
`vars/group/all.yml`, then each group's file in alphabetical order, then `vars/host/<name>.yml`, then the host's own table values.

Roles come from two places, in this order:

1. `windows/site.yml` (or the fleet's `config/windows/site.yml`, which wins): the roles every Windows host runs.
2. The tag manifests, the same files Linux uses (`config/tags/<dim>/<value>.yml`, then the framework's `hosts/tags/`). A manifest adds
   `windows_roles: [name, ...]` and optionally `windows_vars: {...}` beside its Linux `roles:` and `vars:`, so `feat: [otel]` means
   observability on either OS. A tag with no `windows_roles` is only a class on Windows. `order` and `requires` work as on Linux.

Not evaluated in this version: `groups:` and `compose:` rules in `groups.yml` (a warning is logged), Jinja inside variable files, and
`vars/routes`.

## The role contract

A role is `windows/roles/<name>/role.ps1` (or `config/windows/roles/<name>/role.ps1` in the fleet repo, which wins). It is a script
taking `-Context` and returning `@{ Changed = $true|$false; Message = '...' }`.

- `$Context.Check` is true in a check pass: change nothing, say whether you would.
- It must be idempotent, and throw when it fails. A failed role stops the host's run, as in Ansible.
- `$Context.Vars` are the merged variables (with the manifest's `windows_vars` on top), `$Context.Name` the host, `$Context.Paths` the
  folders and `sops.exe`, and `& $Context.GetSecret 'kind.name'` returns the decrypted `config/secrets/<kind>/<name>.yml`.
- A config change to a running service goes through the validate, keep a copy, apply, health-check and restore pattern of `safe_apply`.

The run writes a summary line in Ansible's recap format (so the Linux tooling that reads it still works), one Event Log entry (source
`Consigliere`), and `last-status.json` under `C:\ProgramData\Consigliere` for the telemetry. `force-run` in that folder makes the next
run go ahead even when nothing changed, the counterpart of `scripts/reconcile-now.sh`.

## Roles in the first version

| Role | What it does |
|---|---|
| `baseline` (written) | Time zone and `w32time`, Windows Update through the policy registry keys (install and restart at `windows_update_reboot_time`, default `04:00`; a pending restart is reported), Defender real-time protection on, the firewall on for all profiles, RDP with NLA reachable from the tailnet only. Hostname left alone. See its [README](../windows/roles/baseline/README.md). |
| `tailscale` (written) | The Tailscale service running and set to start automatically, and unattended mode on, so the host rejoins the tailnet at boot with no one signed in. Joining stays with `bootstrap.ps1`. See its [README](../windows/roles/tailscale/README.md). |
| `ssh` (written) | OpenSSH Server installed as a Windows capability, key-only (fleet admin keys in `administrators_authorized_keys`), with `sshd_config` changes validated and restored on failure, and port 22 allowed from the tailnet only when `windows_access` is `tailnet`. See its [README](../windows/roles/ssh/README.md). |
| `tailscale` | Installed and joined (tag from the host table). Settings the Linux role sets on DNS and routes are options here too. |
| `otel_agent` | The OpenTelemetry collector as a service: Windows Event Log channels (System, Application, Security) as logs, host metrics (CPU, memory, disk, network, processes) as metrics, plus the reconcile status and pending-reboot state. Config changes validate, keep a copy, apply, health-check and restore, like `safe_apply`. |

## Where the tools come from

The reconcile runs as SYSTEM, so everything it uses must be machine-wide; nothing may live in a user's profile, and WinGet is not used at all
(it is a per-user app, absent on some editions, and one more thing that changes versions). Every tool is the vendor's release file checked
against a pinned SHA-256: PowerShell 7, sops, age, MinGit (Git for Windows' minimal zip) and the Tailscale MSI, which is installed with
unattended mode on. Version bumps are therefore by hand ([decisions.md](decisions.md) entries 11, 12 and 16).

- **The OpenTelemetry collector** will follow the same pattern: the project's release archive with a pinned checksum, as the Linux role pins
  its package. (It is not in the WinGet repository either.)

## YAML on the host

The reconcile reads the fleet's YAML with the `powershell-yaml` module (which bundles YamlDotNet), pinned to a version and a SHA-256. It is
fetched on first use straight from the PowerShell Gallery's package URL into `C:\ProgramData\Consigliere\modules` and imported from there;
`Install-Module` is not used, because it needs the NuGet provider, which PowerShell 7 does not have the way Windows PowerShell does.

## Secrets

The same sops and age scheme as Linux. The age key lives in `C:\ProgramData\Consigliere\age.key` with an ACL for SYSTEM and Administrators
only. A secret that is a credential is never written to the log or the status file. Read [security.md](security.md) before touching this.

## Reaching the host

One setting, `windows_access`, says how reachable a host is, for Remote Desktop and SSH together: `tailnet` (the default, locked down: only
the tailnet ranges may connect) or `lan` (Windows' own arrangement, reachable from the local network too). It is defined in
`windows/defaults.yml` and set per host or group in the fleet's `config/vars/`. SSH is plain OpenSSH behind a firewall rule, not bound to the
Tailscale address (sshd can start before Tailscale has one), and a rule is always made before the one it replaces is turned off.


Over Tailscale only: SSH for automation, RDP for hands-on use. Neither is open on the LAN profile. `scripts/fleet-run.sh` could run plain
commands and `--status` over SSH once the ssh role exists; the update and reboot actions are apt-shaped and stay Linux-only for now.

## Open items

- `scripts/access.sh` and `config/access.yml` must accept a Windows host (an age recipient, no `apt`-shaped assumptions). Not checked yet.
- The Spire VM's disk, vTPM and Secure Boot settings are the user's side; Windows 11 needs both, and the install itself is not managed.
- Defender exclusions, if the collector's directory needs one, are decided when it is built.

## Testing

Each role is first run by hand on the VM (with GUI access for the parts that fail without a desktop), then by the Scheduled Task, then
left to run for a day with reboots. Nothing here has been run yet.
