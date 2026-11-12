#Requires -Version 7.4
<#
.SYNOPSIS
  OpenSSH Server on a Windows host: installed, key-only, reachable the way windows_access says. See README.md.

.DESCRIPTION
  Idempotent. In a check pass ($Context.Check) it changes nothing and reports what it would change. A change to sshd_config follows the
  safe_apply pattern: validate the new file with `sshd -t`, keep a copy, apply, check that sshd is listening, restore on failure.
  Throws when something cannot be set.
#>
param([Parameter(Mandatory)][hashtable]$Context)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---- Defaults (windows_access and windows_tailnet_ranges are shared with the baseline: see windows\defaults.yml) -----------
$Defaults = @{
  windows_ssh_manage        = $true
  windows_ssh_password_auth = $false   # off only when at least one admin key exists to log in with, so the role cannot lock a host out
  windows_ssh_default_shell = 'pwsh'   # pwsh (PowerShell 7), powershell (Windows PowerShell 5.1) or cmd
}
function V([string]$Name) { if ($Context.Vars.Contains($Name)) { return $Context.Vars[$Name] } else { return $Defaults[$Name] } }

$check = [bool]$Context.Check
$changes = New-Object Collections.Generic.List[string]
function Note([string]$What) { $changes.Add($(if ($check) { "would $What" } else { $What })) }

if (-not (V 'windows_ssh_manage')) { return @{ Changed = $false; Message = 'not managed (windows_ssh_manage is false)' } }

$access = [string](V 'windows_access')
if ($access -notin 'tailnet', 'lan') { throw "windows_access '$access' must be tailnet or lan" }
$ranges = @(V 'windows_tailnet_ranges')
if ($access -eq 'tailnet' -and $ranges.Count -eq 0) { throw 'windows_access is tailnet but windows_tailnet_ranges is empty' }

# The admin keys, from the same fleet variables the Linux baseline uses, without duplicates.
$keys = @()
foreach ($n in 'baseline_admin_ssh_keys', 'baseline_bastion_ssh_keys') {
  if ($Context.Vars.Contains($n) -and $Context.Vars[$n]) { $keys += @($Context.Vars[$n]) }
}
$keys = @($keys | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)

$sshDir  = Join-Path $env:ProgramData 'ssh'
$cfgPath = Join-Path $sshDir 'sshd_config'
$keysPath = Join-Path $sshDir 'administrators_authorized_keys'
$sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
$defaultRule = 'OpenSSH-Server-In-TCP'    # the rule Windows creates with the capability (any source address)
$mine = 'Consigliere SSH (tailnet)'

# ---- Pure helpers (tested apart from Windows) ---------------------------------------------------------------
$BeginMark = '# BEGIN consigliere (managed by windows\roles\ssh; edit the fleet variables, not this block)'
$EndMark = '# END consigliere'

# The config with this role's block at the top. sshd takes the first value it sees for a keyword, so a block at the top wins over the
# vendor lines below it; anything that was not ours is kept as it was.
function Build-SshdConfig([string]$Current, [bool]$PasswordAuth) {
  $stripped = [regex]::Replace($Current, '(?s)' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '\r?\n?', '')
  $lines = @($BeginMark, 'PubkeyAuthentication yes', $(if ($PasswordAuth) { 'PasswordAuthentication yes' } else { 'PasswordAuthentication no' }), $EndMark)
  return (($lines -join "`r`n") + "`r`n" + $stripped.TrimStart("`r", "`n"))
}
function Same-Text([string]$A, [string]$B) { return (($A -replace "`r`n", "`n").TrimEnd() -eq ($B -replace "`r`n", "`n").TrimEnd()) }
function Write-TextFile([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }

# ---- 1. The OpenSSH Server capability ------------------------------------------------------------------------
Import-Module Dism -UseWindowsPowerShell -WarningAction SilentlyContinue   # Windows PowerShell's module, through PowerShell 7's compatibility layer
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if (-not $cap) { throw 'this Windows has no OpenSSH.Server capability' }
if ("$($cap.State)" -ne 'Installed') {
  if (-not $check) { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  Note 'install the OpenSSH Server'
  if ($check) { Note 'then configure it (service, sshd_config, keys, firewall)'; return @{ Changed = $true; Message = ($changes -join '; ') } }
}

# ---- 2. The service (its first start creates the host keys and the default sshd_config) ---------------------
$svc = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if ($svc.StartMode -ne 'Auto') {
  if (-not $check) { Set-Service -Name sshd -StartupType Automatic }
  Note 'set sshd to start automatically'
}
if ($svc.State -ne 'Running') {
  if (-not $check) { Start-Service -Name sshd }
  Note 'start sshd'
}
if (-not (Test-Path $cfgPath)) {
  if ($check) { Note 'create the default sshd_config'; return @{ Changed = $true; Message = ($changes -join '; ') } }
  Copy-Item (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd_config_default') $cfgPath
}

# ---- 3. Keys: administrators_authorized_keys, readable only by SYSTEM and Administrators --------------------
# (Administrators' keys on Windows are in this one file, not in the user's profile.)
$wantKeys = ($keys -join "`r`n") + "`r`n"
$haveKeys = if (Test-Path $keysPath) { Get-Content -LiteralPath $keysPath -Raw } else { '' }
if ($keys.Count -gt 0 -and -not (Same-Text $haveKeys $wantKeys)) {
  if (-not $check) {
    Write-TextFile $keysPath $wantKeys
    & icacls.exe $keysPath /inheritance:r /grant '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null   # a file: plain Full control, no folder inherit flags
    if ($LASTEXITCODE -ne 0) { throw "icacls on $keysPath failed ($LASTEXITCODE)" }
  }
  Note "write the admin keys ($($keys.Count))"
}

# ---- 4. sshd_config: validate, keep a copy, apply, check, restore --------------------------------------------
$wantPassword = [bool](V 'windows_ssh_password_auth')
if (-not $wantPassword -and $keys.Count -eq 0) {
  $wantPassword = $true   # never switch passwords off while no key can log in
  Write-Host '    no admin keys set (baseline_admin_ssh_keys): leaving password logins on so the host cannot be locked out'
}
$current = Get-Content -LiteralPath $cfgPath -Raw
$desired = Build-SshdConfig $current $wantPassword
if (-not (Same-Text $current $desired)) {
  if (-not $check) {
    $new = "$cfgPath.new"; $bak = "$cfgPath.consigliere-bak"
    Write-TextFile $new $desired
    $test = & $sshdExe -t -f $new 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item $new -Force; throw "the new sshd_config does not validate, nothing was changed: $($test | Out-String)" }
    Copy-Item $cfgPath $bak -Force
    Move-Item $new $cfgPath -Force
    Restart-Service -Name sshd
    $up = $false
    foreach ($i in 1..10) {
      Start-Sleep -Seconds 1
      if ((Get-Service sshd).Status -eq 'Running' -and (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) { $up = $true; break }
    }
    if (-not $up) {
      Copy-Item $bak $cfgPath -Force; Restart-Service -Name sshd
      throw 'sshd did not come back listening on port 22 with the new sshd_config; the previous one was restored'
    }
  }
  Note "update sshd_config (key logins on, passwords $(if ($wantPassword) { 'on' } else { 'off' }))"
}

# ---- 5. Default shell ----------------------------------------------------------------------------------------
$shell = switch ([string](V 'windows_ssh_default_shell')) {
  'pwsh'       { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
  'powershell' { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
  'cmd'        { Join-Path $env:SystemRoot 'System32\cmd.exe' }
  default      { throw "windows_ssh_default_shell must be pwsh, powershell or cmd" }
}
function Get-RegValue([string]$Path, [string]$Name) {
  $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -ne $item -and $item.PSObject.Properties[$Name]) { return $item.PSObject.Properties[$Name].Value }
  return $null
}
$shellKey = 'HKLM:\SOFTWARE\OpenSSH'
if ((Get-RegValue $shellKey 'DefaultShell') -ne $shell -or (Get-RegValue $shellKey 'DefaultShellCommandOption') -ne '-c') {
  if (-not $check) {
    if (-not (Test-Path $shellKey)) { New-Item -Path $shellKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $shellKey -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $shellKey -Name DefaultShellCommandOption -Value '-c' -PropertyType String -Force | Out-Null
  }
  Note "set the SSH shell to $shell"
}

# ---- 6. Firewall, the way windows_access says ----------------------------------------------------------------
$def = Get-NetFirewallRule -Name $defaultRule -ErrorAction SilentlyContinue
$ours = Get-NetFirewallRule -DisplayName $mine -ErrorAction SilentlyContinue
if ($access -eq 'tailnet') {
  # Ours first, then the any-source rule off: there is never a moment with no rule for a session that arrived over the old one.
  $desc = "Managed by Consigliere. Allowed: $((@($ranges | Sort-Object)) -join ', ')"   # Windows reports a CIDR back as address/mask, so compare the description
  $ok = $false
  if ($ours) { $ok = ("$($ours.Enabled)" -eq 'True') -and ("$($ours.Action)" -eq 'Allow') -and ($ours.Description -eq $desc) }
  if (-not $ok) {
    if (-not $check) {
      if ($ours) { $ours | Remove-NetFirewallRule }
      New-NetFirewallRule -DisplayName $mine -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -RemoteAddress $ranges -Profile Any `
        -Group 'Consigliere' -Description $desc | Out-Null
    }
    Note 'allow SSH (TCP 22) from the tailnet only'
  }
  if ($def -and "$($def.Enabled)" -eq 'True') {
    if (-not $check) { $def | Disable-NetFirewallRule }
    Note 'turn off the any-source OpenSSH firewall rule'
  }
} else {
  if ($def -and "$($def.Enabled)" -ne 'True') {
    if (-not $check) { $def | Enable-NetFirewallRule }
    Note 'turn the standard OpenSSH firewall rule back on (reachable from the LAN)'
  }
  if ($ours) {
    if (-not $check) { $ours | Remove-NetFirewallRule }
    Note 'remove the tailnet-only SSH rule'
  }
}

return @{ Changed = ($changes.Count -gt 0); Message = $(if ($changes.Count) { $changes -join '; ' } else { 'already as wanted' }) }
