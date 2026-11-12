#Requires -Version 7.4
<#
.SYNOPSIS
  The Windows baseline: clock, Windows Update, Defender, firewall and Remote Desktop. See README.md.

.DESCRIPTION
  Idempotent. In a check pass ($Context.Check) it changes nothing and reports what it would change.
  Each section can be switched off with its own *_manage variable, and every value comes from
  $Context.Vars (role defaults below, overridden by the fleet's vars/). Throws when something cannot be set.
#>
param([Parameter(Mandatory)][hashtable]$Context)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---- Defaults (the one home for each setting; the fleet overrides them in config/vars/) ---------------
$Defaults = @{
  baseline_timezone               = ''             # '' = leave the time zone alone; a Windows id ('Eastern Standard Time') or an IANA name ('America/New_York')
  windows_time_manage             = $true
  windows_ntp_servers             = @()            # @() = keep Windows' own peers; else a list such as @('time.cloudflare.com')
  windows_update_manage           = $true
  windows_update_reboot_time      = '04:00'        # when updates install, and when the host restarts if it must (local time, HH:MM)
  windows_update_auto_reboot      = $true          # false = never restart for updates by itself (a restart then waits for you)
  windows_update_other_products   = $false         # also update other Microsoft products through Windows Update
  windows_security_manage         = $true
  windows_defender_manage         = $true          # real-time protection on; skipped when another antivirus has taken Defender's place
  windows_firewall_manage         = $true          # firewall on for every profile, inbound blocked unless a rule allows it
  windows_rdp_enable              = $true          # Remote Desktop on, with Network Level Authentication
  windows_rdp_tailnet_only        = $true          # the built-in Remote Desktop rules are turned off; one rule allows the tailnet only
  windows_tailnet_ranges          = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
}
function V([string]$Name) { if ($Context.Vars.Contains($Name)) { return $Context.Vars[$Name] } else { return $Defaults[$Name] } }

$check = [bool]$Context.Check
$changes = New-Object Collections.Generic.List[string]
function Note([string]$What) { $changes.Add($(if ($check) { "would $What" } else { $What })) }

# ---- Helpers -------------------------------------------------------------------------------------------
# A registry value, or $null when the key or the value is not there. (Get-ItemPropertyValue throws a terminating error for a missing
# value that -ErrorAction cannot silence, which is the usual state of a policy key nobody has set.)
function Get-RegValue([string]$Path, [string]$Name) {
  $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -ne $item -and $item.PSObject.Properties[$Name]) { return $item.PSObject.Properties[$Name].Value }
  return $null
}

# Set a registry value; true when it was (or, in a check pass, would be) changed.
function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
  $cur = Get-RegValue $Path $Name
  if ($null -ne $cur -and "$cur" -eq "$Value") { return $false }
  if (-not $check) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
  }
  return $true
}

# IANA names for the zones a fleet is likely to use. Windows PowerShell 5.1 cannot convert them itself.
$IanaToWindows = @{
  'UTC' = 'UTC'; 'Etc/UTC' = 'UTC'
  'America/New_York' = 'Eastern Standard Time'; 'America/Detroit' = 'Eastern Standard Time'; 'America/Toronto' = 'Eastern Standard Time'
  'America/Chicago' = 'Central Standard Time'; 'America/Denver' = 'Mountain Standard Time'; 'America/Phoenix' = 'US Mountain Standard Time'
  'America/Los_Angeles' = 'Pacific Standard Time'; 'America/Vancouver' = 'Pacific Standard Time'
  'America/Anchorage' = 'Alaskan Standard Time'; 'Pacific/Honolulu' = 'Hawaiian Standard Time'
  'Europe/London' = 'GMT Standard Time'; 'Europe/Dublin' = 'GMT Standard Time'; 'Europe/Lisbon' = 'GMT Standard Time'
  'Europe/Berlin' = 'W. Europe Standard Time'; 'Europe/Amsterdam' = 'W. Europe Standard Time'; 'Europe/Rome' = 'W. Europe Standard Time'
  'Europe/Stockholm' = 'W. Europe Standard Time'; 'Europe/Vienna' = 'W. Europe Standard Time'; 'Europe/Zurich' = 'W. Europe Standard Time'
  'Europe/Paris' = 'Romance Standard Time'; 'Europe/Madrid' = 'Romance Standard Time'; 'Europe/Brussels' = 'Romance Standard Time'
  'Europe/Copenhagen' = 'Romance Standard Time'; 'Europe/Warsaw' = 'Central European Standard Time'
  'Europe/Athens' = 'GTB Standard Time'; 'Europe/Helsinki' = 'FLE Standard Time'
}
function Resolve-WindowsZone([string]$Name) {
  if ($Name -notmatch '/' -and $Name -ne 'UTC') { return $Name }   # already a Windows id
  if ($IanaToWindows.ContainsKey($Name)) { return $IanaToWindows[$Name] }
  $win = $null   # PowerShell 7 (.NET 6+) can convert any IANA name
  if ([TimeZoneInfo].GetMethod('TryConvertIanaIdToWindowsId')) { if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($Name, [ref]$win)) { return $win } }
  throw "baseline_timezone '$Name' is not a Windows time zone id and has no known Windows equivalent; use the Windows id (tzutil /l lists them)"
}

# ---- 1. Time zone and clock ----------------------------------------------------------------------------
if (V 'windows_time_manage') {
  $tz = [string](V 'baseline_timezone')
  if ($tz) {
    $want = Resolve-WindowsZone $tz
    if ((Get-TimeZone).Id -ne $want) {
      if (-not $check) { Set-TimeZone -Id $want }
      Note "set the time zone to $want"
    }
  }

  $svc = Get-CimInstance Win32_Service -Filter "Name='w32time'"
  if ($svc.StartMode -ne 'Auto') {
    if (-not $check) { Set-Service -Name w32time -StartupType Automatic }
    Note 'set the Windows Time service to start automatically'
  }
  if ($svc.State -ne 'Running') {
    if (-not $check) { Start-Service -Name w32time }
    Note 'start the Windows Time service'
  }
  $peers = @(V 'windows_ntp_servers')
  if ($peers.Count -gt 0) {
    $wantPeers = ($peers | ForEach-Object { "$_,0x9" }) -join ' '
    $wp = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    if ((Get-RegValue $wp 'NtpServer') -ne $wantPeers -or (Get-RegValue $wp 'Type') -ne 'NTP') {
      if (-not $check) {
        & w32tm.exe /config /syncfromflags:manual "/manualpeerlist:$($peers -join ' ')" /update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed ($LASTEXITCODE)" }
      }
      Note "set the NTP peers to $($peers -join ', ')"
    }
  }
}

# ---- 2. Windows Update ---------------------------------------------------------------------------------
# Policy keys (the ones Group Policy writes), so the Settings app shows them as managed by the organisation.
# AUOptions 4 = download automatically and install on a schedule. The "always restart at the scheduled time"
# policy gives a restart warning of at least 15 minutes. VERIFY on the VM that the restart really lands in the window.
if (V 'windows_update_manage') {
  $rt = [string](V 'windows_update_reboot_time')
  if ($rt -match '^([01]?\d|2[0-3]):([0-5]\d)$') { $hour = [int]$Matches[1] } else { throw "windows_update_reboot_time '$rt' must be HH:MM" }
  $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $au = "$wu\AU"
  $auto = [bool](V 'windows_update_auto_reboot')
  $wanted = @(
    @($au, 'NoAutoUpdate', 0), @($au, 'AUOptions', 4), @($au, 'ScheduledInstallDay', 0), @($au, 'ScheduledInstallTime', $hour),
    @($au, 'AlwaysAutoRebootAtScheduledTime', [int]$auto), @($au, 'AlwaysAutoRebootAtScheduledTimeMinutes', 15),
    @($au, 'NoAutoRebootWithLoggedOnUsers', [int](-not $auto)),
    @($au, 'AllowMUUpdateService', [int][bool](V 'windows_update_other_products'))
  )
  $any = $false
  foreach ($w in $wanted) { if (Set-RegValue $w[0] $w[1] $w[2]) { $any = $true } }
  if ($any) { Note "set the Windows Update policy (install daily at $rt, $(if ($auto) { 'restart at that time' } else { 'no automatic restart' }))" }
}

# What the host owes: a pending restart, so the report (and the telemetry later) can show it.
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

# ---- 3. Defender, firewall, Remote Desktop ------------------------------------------------------------
if (V 'windows_security_manage') {
  if (V 'windows_defender_manage') {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($null -eq $mp) {
      Write-Host '    Defender is not available (another antivirus is registered?); leaving it alone'
    } elseif (-not $mp.RealTimeProtectionEnabled) {
      if (-not $check) { Set-MpPreference -DisableRealtimeMonitoring $false }
      Note 'turn Defender real-time protection on'
    }
  }

  if (V 'windows_firewall_manage') {
    foreach ($prof in Get-NetFirewallProfile -PolicyStore ActiveStore) {
      $fix = @{}
      if ("$($prof.Enabled)" -ne 'True') { $fix['Enabled'] = 'True' }
      if ("$($prof.DefaultInboundAction)" -ne 'Block') { $fix['DefaultInboundAction'] = 'Block' }
      if ($fix.Count -gt 0) {
        if (-not $check) { Set-NetFirewallProfile -Name $prof.Name @fix }
        Note "set the $($prof.Name) firewall profile ($($fix.Keys -join ', '))"
      }
    }
  }

  # Remote Desktop: NLA on, and either off or reachable from the tailnet only.
  $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
  $rdpGroup = '@FirewallAPI.dll,-28752'   # the built-in "Remote Desktop" rule group (this id does not depend on the display language)
  $mine = 'Consigliere RDP (tailnet)'
  if (V 'windows_rdp_enable') {
    $c1 = Set-RegValue $ts 'fDenyTSConnections' 0
    $c2 = Set-RegValue "$ts\WinStations\RDP-Tcp" 'UserAuthentication' 1
    if ($c1 -or $c2) { Note 'turn Remote Desktop on with Network Level Authentication' }
    if (V 'windows_rdp_tailnet_only') {
      $builtin = @(Get-NetFirewallRule -Group $rdpGroup -ErrorAction SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' })
      if ($builtin.Count -gt 0) {
        if (-not $check) { $builtin | Disable-NetFirewallRule }
        Note "turn off the built-in Remote Desktop firewall rules ($($builtin.Count))"
      }
      $ranges = @(V 'windows_tailnet_ranges')
      foreach ($proto in 'TCP', 'UDP') {
        $name = "$mine $proto"
        $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        # Windows reports a CIDR range back as address/mask, so the wanted ranges are kept in the description and compared there.
        $desc = "Managed by Consigliere. Allowed: $((@($ranges | Sort-Object)) -join ', ')"
        $ok = $false
        if ($rule) { $ok = ("$($rule.Enabled)" -eq 'True') -and ("$($rule.Action)" -eq 'Allow') -and ($rule.Description -eq $desc) }
        if (-not $ok) {
          if (-not $check) {
            if ($rule) { $rule | Remove-NetFirewallRule }
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol $proto -LocalPort 3389 `
              -RemoteAddress $ranges -Profile Any -Group 'Consigliere' -Description $desc | Out-Null
          }
          Note "allow Remote Desktop ($proto 3389) from the tailnet only"
        }
      }
    } else {
      # Windows' own arrangement: the built-in Remote Desktop rules, reachable from the LAN. Undo what tailnet-only mode did.
      # Public-profile-only variants stay off: Windows itself does not open Remote Desktop on a public network when you switch it on.
      $off = @(Get-NetFirewallRule -Group $rdpGroup -ErrorAction SilentlyContinue | Where-Object { "$($_.Enabled)" -ne 'True' -and "$($_.Profile)" -ne 'Public' })
      if ($off.Count -gt 0) {
        if (-not $check) { $off | Enable-NetFirewallRule }
        Note "turn the built-in Remote Desktop firewall rules back on ($($off.Count))"
      }
      foreach ($proto in 'TCP', 'UDP') {
        $mine1 = Get-NetFirewallRule -DisplayName "$mine $proto" -ErrorAction SilentlyContinue
        if ($mine1) {
          if (-not $check) { $mine1 | Remove-NetFirewallRule }
          Note "remove the tailnet-only Remote Desktop rule ($proto)"
        }
      }
    }
  } else {
    if (Set-RegValue $ts 'fDenyTSConnections' 1) { Note 'turn Remote Desktop off' }
  }
}

$msg = if ($changes.Count) { $changes -join '; ' } else { 'already as wanted' }
if ($pending) { $msg += ' [restart pending]' }
return @{ Changed = ($changes.Count -gt 0); Message = $msg }
