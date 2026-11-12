# windows ssh

OpenSSH Server on a Windows host, key-only, reachable the way `windows_access` says.

**Contract**

- **Manages:** the OpenSSH Server capability and its `sshd` service; a marked block at the top of `sshd_config` (key logins on, password
  logins off when an admin key exists); `administrators_authorized_keys`; the SSH default shell; the SSH firewall rules.
- **Leaves alone:** the rest of `sshd_config` (the vendor lines stay as they are), host keys, per-user `authorized_keys`, and any other
  firewall rule.
- **Change it in:** the fleet's `config/vars/` (for example `vars/group/all.yml`, or the host's file). Defaults are in `role.ps1`; the shared
  `windows_access` and `windows_tailnet_ranges` are in `windows/defaults.yml`.
- **Rolls back by:** a change to `sshd_config` is validated with `sshd -t` first, a copy is kept as `sshd_config.consigliere-bak`, and if
  `sshd` does not come back listening on port 22 the copy is restored and the run fails with that said.
- **Check mode:** reports what it would change and changes nothing.

## The access policy

`windows_access` is one switch for Remote Desktop and SSH together:

| Value | SSH | Remote Desktop |
|---|---|---|
| `tailnet` (default) | Port 22 allowed only from `windows_tailnet_ranges`; the any-source OpenSSH rule is turned off. | Same, by the baseline role. |
| `lan` | The standard OpenSSH rule is on (any source, as Windows sets it); the tailnet-only rule is removed. | Windows' own rules. |

Tailscale SSH is not an option here: Windows cannot be a Tailscale SSH server, so this is plain OpenSSH behind a firewall rule. The rule
is made before the old one is turned off, so a session that arrived over the old rule is never cut off by the change.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `windows_ssh_manage` | `true` | `false` leaves SSH entirely alone. |
| `windows_ssh_password_auth` | `false` | Password logins. Never switched off while no admin key exists, so the role cannot lock a host out. |
| `windows_ssh_default_shell` | `pwsh` | The shell a login gets: `pwsh` (PowerShell 7), `powershell` (5.1) or `cmd`. |
| `windows_access` | `tailnet` | `tailnet` or `lan` (see above). |
| `windows_tailnet_ranges` | Tailscale's IPv4 and IPv6 ranges | What `tailnet` means. |
| `baseline_admin_ssh_keys`, `baseline_bastion_ssh_keys` | the fleet's | The keys written to `administrators_authorized_keys` (the same variables as the Linux baseline). |

## Notes

- **Administrators' keys on Windows** are in `C:\ProgramData\ssh\administrators_authorized_keys`, not in a profile; sshd refuses the file
  unless only SYSTEM and Administrators can read it, which the role sets.
- **Installing the capability** downloads it through Windows Update, so the host needs to reach Microsoft's servers. **VERIFY** on the VM.
- **Not verified on Windows:** every cmdlet here. The `sshd_config` block logic was tested apart from Windows.
