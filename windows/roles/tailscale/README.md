# windows tailscale

Keeps Tailscale running on a Windows host, including before anyone signs in.

**Contract**

- **Manages:** the `Tailscale` service (starts automatically, kept running) and the system policy `UnattendedMode = always` under
  `HKLM\SOFTWARE\Policies\Tailscale`.
- **Leaves alone:** joining the tailnet (that needs an auth key, which `bootstrap.ps1` uses once and never stores), tags, DNS and routes,
  and the Tailscale admin console's policy.
- **Change it in:** the fleet's `config/vars/`.
- **Rolls back by:** nothing to restore; set `windows_tailscale_unattended: false` to stop managing the policy (it does not remove it).
- **Check mode:** reports what it would change and changes nothing.

## Why unattended mode

On Windows, Tailscale brings the tunnel down when the signed-in user signs out and waits for the next login before it connects, unless
unattended mode is on. A host that reboots with nobody at the keyboard would then sit off the tailnet: its tailnet-only Remote Desktop and
SSH unreachable, and its telemetry (sent to the Loki and VictoriaMetrics hosts over the tailnet) unsent. The reconcile itself is not
affected: it pulls from GitHub over the public internet and uses the name saved at enrolment when Tailscale is not up.

The policy is the same registry value the Tailscale MSI's `TS_UNATTENDEDMODE=always` property writes, and `bootstrap.ps1` installs the MSI
with that property, so a new host starts unattended; this role makes an older install (or one changed by hand) converge too.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `windows_tailscale_manage` | `true` | `false` leaves Tailscale alone. |
| `windows_tailscale_unattended` | `true` | Keep Tailscale connected with no one signed in. |

**VERIFY** on a host that Tailscale applies a changed policy without restarting its service (the role does not restart it, because that
would drop any session running over the tailnet).
