# windows baseline

The baseline every Windows host gets: the clock, Windows Update, Defender, the firewall and Remote Desktop.

**Contract**

- **Manages:** the time zone (when `baseline_timezone` is set) and the Windows Time service; the Windows Update policy keys; Defender's
  real-time protection; the firewall profiles; Remote Desktop and its firewall rules.
- **Leaves alone:** the hostname, accounts, installed apps, the power plan, and Defender's exclusions and scans.
- **Change it in:** the fleet's `config/vars/` (group file, for example `vars/group/os_windows.yml`, or the host's file). Defaults are in
  `role.ps1`.
- **Rolls back by:** nothing here keeps a copy. Every value is a documented policy key or setting, so setting the `*_manage` variable to
  false stops the role touching that part; it does not undo what was already applied.
- **Check mode:** reports what it would change and changes nothing.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `baseline_timezone` | `""` | Empty leaves the zone alone. A Windows id (`Eastern Standard Time`) or a common IANA name (`America/New_York`). |
| `windows_time_manage` | `true` | Manage the time zone and the Windows Time service. |
| `windows_ntp_servers` | `[]` | Empty keeps Windows' own time peers; otherwise the list to sync from. |
| `windows_update_manage` | `true` | Manage the Windows Update policy. |
| `windows_update_reboot_time` | `"04:00"` | Local time that updates install, and the host restarts if it must. |
| `windows_update_auto_reboot` | `true` | `false` never restarts by itself; a restart then waits for you. |
| `windows_update_other_products` | `false` | Also update other Microsoft products. |
| `windows_security_manage` | `true` | Manage Defender, the firewall and Remote Desktop. |
| `windows_defender_manage` | `true` | Real-time protection on. Skipped when another antivirus has replaced Defender. |
| `windows_firewall_manage` | `true` | Firewall on for every profile, inbound blocked unless a rule allows it. |
| `windows_rdp_enable` | `true` | Remote Desktop on, with Network Level Authentication. `false` turns it off. |
| `windows_access` | `tailnet` | One switch for Remote Desktop and SSH (see the `ssh` role): `tailnet` switches the built-in Remote Desktop rules off and allows only `windows_tailnet_ranges`; `lan` switches Windows' own rules back on (reachable from the LAN) and removes the role's tailnet-only rules. |
| `windows_tailnet_ranges` | the Tailscale IPv4 and IPv6 ranges | What `tailnet` means. Both settings are defined in `windows/defaults.yml`. |
| `windows_rdp_tailnet_only` | unset | Older switch for RDP alone; when a host sets it, it wins over `windows_access` for RDP. Kept so a half-updated fleet cannot lock a host out; prefer `windows_access`. |

## Notes

- **Windows Update** is set through the same registry policy keys Group Policy writes, so Settings shows them as managed. Windows 11 may
  ignore some of them on editions or builds that moved to newer update controls. **VERIFY** on the VM that the restart lands in the
  window (the policy gives at least 15 minutes of warning).
- **Pending restart** is reported in the role's message (`[restart pending]`); the telemetry role will export it.
- **Remote Desktop rules** are found by the built-in group's language-independent id, not by name. The role's own rules carry the allowed
  ranges in their description, because Windows reports a CIDR range back as `address/mask`.
- **Not done:** the hostname (left as it is), SSH (the `ssh` role) and Tailscale (its own role).
