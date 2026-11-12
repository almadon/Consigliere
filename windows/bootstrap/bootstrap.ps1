<#
.SYNOPSIS
  One-time enrolment of a Windows host. Run once, in an elevated PowerShell. Safe to re-run.

.DESCRIPTION
  The Windows counterpart of hosts/bootstrap/bootstrap.sh. A new host has neither repo, so the timed
  reconcile cannot be the first step. This script:

    1. installs git, Tailscale and age with WinGet, and the pinned sops release (checksum-verified);
    2. joins the tailnet, if it is not on it yet;
    3. gives the host its own read-only deploy key for the PRIVATE fleet repo (registered through the
       GitHub API when -FleetConfigRegisterToken is given, otherwise printed for you to add);
    4. gives the host its own age key and prints the public half, so you can grant it its secrets;
    5. clones the public framework repo;
    6. runs one CHECK-ONLY reconcile, asks before applying, then registers the Scheduled Task.

  Everything host-local lives under C:\ProgramData\Consigliere and is readable only by SYSTEM and
  Administrators. The Tailscale auth key and the GitHub token are used once and never stored.
  See docs/windows-host.md. Nothing here has been run on a real host yet.

.EXAMPLE
  $env:TAILSCALE_AUTHKEY = 'tskey-auth-...'
  .\bootstrap.ps1 -FrameworkRepoUrl https://github.com/almadon/Consigliere.git `
                  -FleetConfigRepoUrl git@github.com:you/fleet.git -NodeName win-spire
#>
[CmdletBinding()]
param(
  [string]$FrameworkRepoUrl = $env:FRAMEWORK_REPO_URL,
  [string]$FrameworkRepoBranch = $env:FRAMEWORK_REPO_BRANCH,        # empty = the remote default branch
  [string]$FleetConfigRepoUrl = $env:FLEET_CONFIG_REPO_URL,
  [string]$FleetConfigRepoBranch = $env:FLEET_CONFIG_REPO_BRANCH,   # empty = the remote default branch
  [string]$NodeName = $env:NODE_NAME,                               # name on the tailnet (the host's identity); the OS hostname is NOT changed
  [string]$TailscaleAuthKey = $env:TAILSCALE_AUTHKEY,               # only needed if the host is not on the tailnet yet
  [string]$FleetConfigRegisterToken = $env:FLEET_CONFIG_REGISTER_TOKEN,  # GitHub token allowed to manage the repo's deploy keys
  [string]$HeartbeatUrl = $env:HEARTBEAT_URL,
  [string]$HeartbeatFailUrl = $env:HEARTBEAT_FAIL_URL,
  [switch]$Apply,                                                   # required for a non-interactive run to apply and register the task
  [int]$IntervalMinutes = 20,
  [int]$AccessWaitSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # Windows PowerShell 5.1 defaults to older TLS
$env:GIT_TERMINAL_PROMPT = '0'   # unattended runs never wait on a credentials prompt

# ---- Pinned tools -----------------------------------------------------------------------------------
# WinGet installs git, Tailscale and age at the version it offers (set a version here to pin one).
# sops is not in the WinGet repository, so it is the vendor's release, checked against a pinned SHA-256
# from that release's sops-vX.Y.Z.checksums.txt. Change the version and both checksums together.
$WingetPackages = @(
  @{ Id = 'Git.Git';             Version = '' },
  @{ Id = 'Tailscale.Tailscale'; Version = '' },
  @{ Id = 'FiloSottile.age';     Version = '' }
)
$SopsVersion = '3.13.3'
$SopsSha256 = @{
  amd64 = 'a4a9a398858fe8b2ef72d9686d930bf7c5cece9be74ad83ac3b53cfdd70e6b1c'
  arm64 = '7f936a0d08edbeba3eb8f50bad1fe71eba83a140a80dfd17051f3bdb4facb08a'
}

$Root      = Join-Path $env:ProgramData 'Consigliere'
$CredDir   = Join-Path $Root 'creds'
$Framework = Join-Path $Root 'framework'
$BinDir    = Join-Path $Root 'bin'
$ConfigFile = Join-Path $Root 'reconcile.json'
$DeployKey = Join-Path $CredDir 'deploy_key'
$AgeKey    = Join-Path $CredDir 'age.key'
$TaskName  = 'Consigliere Reconcile'

function Say($m)  { Write-Host "==> $m" }
function Warn($m) { Write-Warning $m }
function Fail($m) { throw $m }

# Run a native program; stop with its output when it fails (PowerShell does not do that by itself).
# Windows PowerShell 5.1 turns anything a native program writes to stderr (git's progress lines, for one) into a
# terminating error when $ErrorActionPreference is Stop, so it is relaxed inside the function; the exit code decides.
function Invoke-Native {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [switch]$AllowFail)
  $ErrorActionPreference = 'Continue'
  $out = & $Exe @Arguments 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { Fail "$Exe $($Arguments -join ' ') failed ($LASTEXITCODE): $out" }
  return $out
}

# True when the program exits 0; output is discarded.
function Test-Native([string]$Exe, [string[]]$Arguments = @()) {
  $ErrorActionPreference = 'Continue'
  & $Exe @Arguments *> $null
  return ($LASTEXITCODE -eq 0)
}

# Only SYSTEM and Administrators (by well-known SID, so the account names' language does not matter).
function Lock-Path([string]$Path) {
  Invoke-Native icacls @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F') | Out-Null
}

function Update-SessionPath {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Install one package with WinGet unless it is already there. Machine scope first, because the reconcile runs as SYSTEM
# and a per-user install is invisible to it; a package with no machine-scope installer is retried without the flag.
function Install-WingetPackage([string]$Id, [string]$Version = '') {
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Fail 'winget was not found. On Windows 11 it ships as "App Installer"; update it from the Microsoft Store, then re-run.'
  }
  if (Test-Native winget.exe @('list', '--exact', '--id', $Id, '--source', 'winget', '--accept-source-agreements')) {
    Say "OK $Id already installed"; return
  }
  $a = @('install', '--exact', '--id', $Id, '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  if ($Version) { $a += @('--version', $Version) }
  if (-not (Test-Native winget.exe ($a + @('--scope', 'machine')))) {
    Invoke-Native winget.exe $a | Out-Null
  }
  Say "INSTALLED $Id"
}

# ---- 0. Preconditions -------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'Run this in an elevated PowerShell (Run as administrator).'
}
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Fail 'This script is for Windows.' }

# ---- 0b. PowerShell 7 is a prerequisite ---------------------------------------------------------------
# The reconcile and the roles need PowerShell 7.4 or later (Windows PowerShell 5.1 is what a fresh Windows has). This file
# must stay valid 5.1 syntax so that it can get this far; it installs PowerShell 7 and carries on there.
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
  Say "Windows PowerShell $($PSVersionTable.PSVersion) is too old; installing PowerShell 7 and continuing in it"
  if (-not $PSCommandPath) { Fail 'Save this script to a file and run it from there (it has to start itself again under PowerShell 7).' }
  Install-WingetPackage 'Microsoft.PowerShell'
  $pwsh7 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
  if (-not (Test-Path $pwsh7)) { Fail "PowerShell 7 is not at $pwsh7 after the install." }
  $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($k -eq 'TailscaleAuthKey') { $env:TAILSCALE_AUTHKEY = [string]$v; continue }                 # secrets go by environment,
    if ($k -eq 'FleetConfigRegisterToken') { $env:FLEET_CONFIG_REGISTER_TOKEN = [string]$v; continue } # not the command line
    if ($v -is [switch]) { if ($v.IsPresent) { $forward += "-$k" } } else { $forward += @("-$k", [string]$v) }
  }
  & $pwsh7 @forward
  exit $LASTEXITCODE
}
$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

if ($interactive) {
  $d = if ($FrameworkRepoUrl) { $FrameworkRepoUrl } else { 'https://github.com/almadon/Consigliere.git' }
  $in = Read-Host "Framework repo URL [$d]"; $FrameworkRepoUrl = if ($in) { $in } else { $d }
  $d = $FleetConfigRepoUrl
  $in = Read-Host "Your PRIVATE fleet repo URL (git@github.com:you/fleet.git)$(if ($d) { " [$d]" })"
  $FleetConfigRepoUrl = if ($in) { $in } else { $d }
}
if (-not $FrameworkRepoUrl)   { Fail 'Set -FrameworkRepoUrl (the public framework repo).' }
if (-not $FleetConfigRepoUrl) { Fail 'Set -FleetConfigRepoUrl (your PRIVATE fleet-config repo).' }
# The private repo is read with a per-host deploy key, which needs the SSH form.
if ($FleetConfigRepoUrl -like 'https://github.com/*') {
  $FleetConfigRepoUrl = 'git@github.com:' + $FleetConfigRepoUrl.Substring('https://github.com/'.Length)
  Say "Using the SSH form for the private repo: $FleetConfigRepoUrl"
}
if ($FleetConfigRepoUrl -notmatch '^(git@[^:]+:|ssh://)') {
  Fail 'The fleet repo URL must be an SSH URL (git@host:owner/repo.git); a deploy key cannot authenticate an https URL.'
}

New-Item -ItemType Directory -Force -Path $Root, $CredDir, $BinDir | Out-Null
Lock-Path $Root

# ---- 1. git, Tailscale, age (WinGet) ----------------------------------------------------------------
Say 'Installing git, Tailscale and age with WinGet'
foreach ($p in $WingetPackages) { Install-WingetPackage $p.Id $p.Version }
Update-SessionPath

$git = (Get-Command git.exe -ErrorAction Stop).Source
$gitUsr = Join-Path (Split-Path (Split-Path $git)) 'usr\bin'
$sshKeygen = Join-Path $gitUsr 'ssh-keygen.exe'
if (-not (Test-Path $sshKeygen)) { Fail "ssh-keygen.exe not found next to git ($sshKeygen)." }
$ageKeygen = (Get-Command age-keygen.exe -ErrorAction SilentlyContinue)
if (-not $ageKeygen) { Fail 'age-keygen.exe not found on PATH after installing FiloSottile.age; open a new elevated shell and re-run.' }

# ---- 1b. sops: pinned release, checksum verified ----------------------------------------------------
$sops = Join-Path $BinDir 'sops.exe'
$sopsOk = (Test-Path $sops) -and ((Invoke-Native $sops @('--version') -AllowFail | Out-String) -match [regex]::Escape($SopsVersion))
if ($sopsOk) {
  Say "OK sops $SopsVersion already installed"
} else {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "sops-$([guid]::NewGuid()).exe"
  try {
    Invoke-WebRequest -UseBasicParsing -OutFile $tmp `
      -Uri "https://github.com/getsops/sops/releases/download/v$SopsVersion/sops-v$SopsVersion.$arch.exe"
    $got = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLowerInvariant()
    if ($got -ne $SopsSha256[$arch]) { Fail "sops checksum mismatch (got $got)" }
    Copy-Item $tmp $sops -Force
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  Say "INSTALLED sops $SopsVersion"
}

# ---- 2. Tailscale ----------------------------------------------------------------------------------
$ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) { Fail "tailscale.exe not found at $ts" }
function Get-TailscaleSelf {
  $j = Invoke-Native $ts @('status', '--json') -AllowFail | Out-String
  if (-not $j) { return $null }
  try { $s = ($j | ConvertFrom-Json) } catch { return $null }
  if ($s.BackendState -eq 'Running' -and $s.Self) { return $s.Self }
  return $null
}
if (Get-TailscaleSelf) {
  Say 'OK already on the tailnet'
} elseif ($TailscaleAuthKey) {
  Say 'Joining the tailnet'
  $up = @('up', "--auth-key=$TailscaleAuthKey")
  if ($NodeName) { $up += "--hostname=$NodeName" }
  Invoke-Native $ts $up | Out-Null
} elseif ($interactive) {
  $sec = Read-Host 'Tailscale auth key (Enter to join by browser approval instead)' -AsSecureString
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  $up = @('up'); if ($key) { $up += "--auth-key=$key" }; if ($NodeName) { $up += "--hostname=$NodeName" }
  Say 'Joining the tailnet (if no key was given, approve the URL it prints)'
  Invoke-Native $ts $up | Out-Host
} else {
  Fail 'Not on the tailnet and no -TailscaleAuthKey given.'
}
$self = Get-TailscaleSelf
if (-not $self) { Fail 'Tailscale is not running after the join. Check "tailscale status".' }
$TsName = ($self.DNSName -split '\.')[0]
Say "Tailscale name: $TsName"

# ---- 3. Read access to the private fleet repo (per-host read-only deploy key) ------------------------
$title = "consigliere-$TsName"
if (-not (Test-Path $DeployKey)) {
  Say "Generating this host's deploy key"
  # An empty passphrase is passed differently by Windows PowerShell 5.1 and PowerShell 7, so hand over one raw argument string.
  $p = Start-Process -FilePath $sshKeygen -NoNewWindow -Wait -PassThru `
         -ArgumentList "-q -t ed25519 -N `"`" -C `"$title`" -f `"$DeployKey`""
  if ($p.ExitCode -ne 0 -or -not (Test-Path $DeployKey)) { Fail "ssh-keygen failed ($($p.ExitCode))" }
}
Lock-Path $CredDir
# git (not the Windows ssh) reads the repo, so name the key in git's own ssh, with forward slashes.
$keyFwd = $DeployKey -replace '\\', '/'
$env:GIT_SSH_COMMAND = "ssh -i `"$keyFwd`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
function Test-FleetRead {
  return (Test-Native $git @('ls-remote', '--exit-code', $FleetConfigRepoUrl, 'HEAD'))
}
if (Test-FleetRead) {
  Say 'Access to the fleet-config repo already works'
} else {
  $path = $null
  if ($FleetConfigRepoUrl -match '^git@github\.com:(.+)$') { $path = $Matches[1] }
  elseif ($FleetConfigRepoUrl -match '^ssh://git@github\.com/(.+)$') { $path = $Matches[1] }
  if ($path) { $path = $path -replace '\.git$', '' }
  if ($FleetConfigRegisterToken -and $path) {
    Say "Registering this host's key as a read-only deploy key on $path"
    try {
      $pub = ((Get-Content "$DeployKey.pub" -Raw).Trim() -split ' ')[0..1] -join ' '
      $body = @{ title = $title; key = $pub; read_only = $true } | ConvertTo-Json
      Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$path/keys" -Body $body -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $FleetConfigRegisterToken"; Accept = 'application/vnd.github+json' } | Out-Null
    } catch { Warn "automatic registration failed (token scope? key already registered?): $($_.Exception.Message). Falling back to manual." }
    Start-Sleep -Seconds 2
  }
  if (-not (Test-FleetRead)) {
    Write-Host ''
    Write-Host "This host cannot read $FleetConfigRepoUrl yet."
    Write-Host "Add this as a READ-ONLY deploy key on that repo (title: $title):"
    Write-Host ''
    Write-Host (Get-Content "$DeployKey.pub" -Raw)
    if ($interactive) {
      while (-not (Test-FleetRead)) { Read-Host 'Press Enter once the key is added (Ctrl-C to abort)' | Out-Null }
    } else {
      $waited = 0
      while (-not (Test-FleetRead)) {
        if ($waited -ge $AccessWaitSeconds) { Fail "still no access after ${AccessWaitSeconds}s. Add the key above, then re-run." }
        Start-Sleep -Seconds 15; $waited += 15
      }
    }
  }
  Say 'Access to the fleet-config repo confirmed'
}

# ---- 4. This host's secrets identity (age key) --------------------------------------------------------
if (-not (Test-Path $AgeKey)) {
  Say "Generating this host's age key"
  Invoke-Native $ageKeygen.Source @('-o', $AgeKey) | Out-Null
}
Lock-Path $CredDir
$agePub = ((Invoke-Native $ageKeygen.Source @('-y', $AgeKey)) | Out-String).Trim()
Write-Host ''
Write-Host "This host's secrets recipient (public key; safe to share):"
Write-Host "  $agePub"
Write-Host ''
Write-Host 'On your admin machine, in your fleet repo, grant it its secrets:'
Write-Host "  scripts/access.sh add-host $TsName $agePub"
Write-Host '  scripts/access.sh sync'
Write-Host "  git add -A && git commit -m 'Add $TsName' && git push"
Write-Host ''
if ($interactive) { Read-Host 'Press Enter once that is pushed (Ctrl-C to abort)' | Out-Null }

# ---- 5. Settings for the timed reconcile, and the framework clone ------------------------------------
Say 'Writing the settings file for future reconcile runs (no secrets in it)'
[ordered]@{
  FrameworkRepoUrl      = $FrameworkRepoUrl
  FrameworkRepoBranch   = [string]$FrameworkRepoBranch
  FleetConfigRepoUrl    = $FleetConfigRepoUrl
  FleetConfigRepoBranch = [string]$FleetConfigRepoBranch
  HeartbeatUrl          = [string]$HeartbeatUrl
  HeartbeatFailUrl      = [string]$HeartbeatFailUrl
  TailscaleName         = $TsName
} | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
Lock-Path $ConfigFile

Say "Cloning the framework repo (to get reconcile.ps1)"
if (Test-Path (Join-Path $Framework '.git')) {
  Invoke-Native $git @('-C', $Framework, 'remote', 'set-url', 'origin', $FrameworkRepoUrl) | Out-Null
  Invoke-Native $git @('-C', $Framework, 'fetch', 'origin') | Out-Null
  $ref = if ($FrameworkRepoBranch) { "origin/$FrameworkRepoBranch" } else { 'origin/HEAD' }
  Invoke-Native $git @('-C', $Framework, 'reset', '--hard', $ref) | Out-Null
} else {
  if (Test-Path $Framework) { Remove-Item $Framework -Recurse -Force }
  $c = @('clone'); if ($FrameworkRepoBranch) { $c += @('--branch', $FrameworkRepoBranch) }; $c += @($FrameworkRepoUrl, $Framework)
  try { Invoke-Native $git $c | Out-Null }
  catch { Fail "could not get $FrameworkRepoUrl. The framework repo is public and needs no login, so the URL is wrong or unreachable. Fix it and re-run; nothing else needs cleaning up." }
}

# ---- 6. First run: check only; then apply and schedule -----------------------------------------------
$reconcile = Join-Path $Framework 'windows\bootstrap\reconcile.ps1'
if (-not (Test-Path $reconcile)) {
  Warn "windows\bootstrap\reconcile.ps1 is not in this framework checkout (it is not built yet). Enrolment is done up to here; the Scheduled Task was NOT registered."
  return
}
$ps = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'   # PowerShell 7: the reconcile needs it (see 0b)
if (-not (Test-Path $ps)) { Fail "PowerShell 7 is not at $ps" }
Say 'First run: CHECK ONLY (nothing on this host is changed)'
& $ps -NoProfile -ExecutionPolicy Bypass -File $reconcile -Mode check
if ($LASTEXITCODE -ne 0) { Warn 'the check pass reported errors; read the output above.' }

if ($interactive) {
  $answer = Read-Host 'Apply these changes for real and register the timer? [y/N]'
  if ($answer -notmatch '^[yY]$') { Write-Host 'Nothing applied, timer not registered. Re-run bootstrap.ps1 when ready.'; return }
} elseif (-not $Apply) {
  Write-Host 'Non-interactive run: nothing applied, timer not registered. Re-run with -Apply to apply.'
  return
}
Say 'Applying'
& $ps -NoProfile -ExecutionPolicy Bypass -File $reconcile -Mode apply
if ($LASTEXITCODE -ne 0) { Fail 'the first apply failed; the timer was NOT registered. Fix the cause and re-run.' }

Say "Registering the Scheduled Task '$TaskName' (every $IntervalMinutes minutes, as SYSTEM)"
$action    = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reconcile`" -Mode apply"
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
               -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 9999)
$trigger.RandomDelay = 'PT2M'
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
               -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$settings.Priority = 7   # below normal, the Windows counterpart of the Linux reconcile's low priority
$taskPrin  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrin -Force | Out-Null

Say "Done. Reconciliation now runs automatically every ~$IntervalMinutes minutes."
Say "Check it with: Get-ScheduledTaskInfo -TaskName '$TaskName'"
