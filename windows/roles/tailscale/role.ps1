#Requires -Version 7.4
<#
.SYNOPSIS
  Tailscale on a Windows host: its service running, and kept running before anyone signs in. See README.md.

.DESCRIPTION
  Idempotent. In a check pass ($Context.Check) it changes nothing and reports what it would change. It does not join the tailnet (that needs
  an auth key, which bootstrap.ps1 uses once); it reports the state. Throws when Tailscale is not installed.
#>
param([Parameter(Mandatory)][hashtable]$Context)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Defaults = @{
  windows_tailscale_manage     = $true
  windows_tailscale_unattended = $true   # keep Tailscale connected when nobody is signed in (without it, the tunnel waits for a login)
}
function V([string]$Name) { if ($Context.Vars.Contains($Name)) { return $Context.Vars[$Name] } else { return $Defaults[$Name] } }

$check = [bool]$Context.Check
$changes = New-Object Collections.Generic.List[string]
function Note([string]$What) { $changes.Add($(if ($check) { "would $What" } else { $What })) }

if (-not (V 'windows_tailscale_manage')) { return @{ Changed = $false; Message = 'not managed (windows_tailscale_manage is false)' } }

# ---- 1. The service ------------------------------------------------------------------------------------------
$svc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'"
if (-not $svc) { throw 'the Tailscale service is not installed (bootstrap.ps1 installs it)' }
if ($svc.StartMode -ne 'Auto') {
  if (-not $check) { Set-Service -Name Tailscale -StartupType Automatic }
  Note 'set the Tailscale service to start automatically'
}
if ($svc.State -ne 'Running') {
  if (-not $check) { Start-Service -Name Tailscale }
  Note 'start the Tailscale service'
}

# ---- 2. Unattended mode ----------------------------------------------------------------------------------------
# The system policy Tailscale itself reads (the same value the MSI's TS_UNATTENDEDMODE property writes). Without "always", the Windows
# client brings the tunnel down when the signed-in user signs out and waits for the next login before it connects.
if (V 'windows_tailscale_unattended') {
  $key = 'HKLM:\SOFTWARE\Policies\Tailscale'
  $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
  $cur = if ($null -ne $item -and $item.PSObject.Properties['UnattendedMode']) { $item.PSObject.Properties['UnattendedMode'].Value } else { $null }
  if ($cur -ne 'always') {
    if (-not $check) {
      if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
      New-ItemProperty -LiteralPath $key -Name UnattendedMode -Value 'always' -PropertyType String -Force | Out-Null
    }
    Note 'turn on unattended mode (Tailscale stays connected with no one signed in)'
  }
}

# ---- 3. State, for the report ----------------------------------------------------------------------------------
$state = 'unknown'
$tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (Test-Path $tsExe) {
  try { $state = [string]((& $tsExe status --json 2>$null | Out-String | ConvertFrom-Json).BackendState) } catch { $state = 'not answering' }
}
if ($state -ne 'Running') { Write-Host "    Tailscale is $state; the host is not on the tailnet right now" }

$msg = if ($changes.Count) { $changes -join '; ' } else { 'already as wanted' }
return @{ Changed = ($changes.Count -gt 0); Message = "$msg [tailnet: $state]" }
