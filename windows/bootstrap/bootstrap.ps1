<#
.SYNOPSIS
  One-time enrolment of a Windows host. Run once, in an elevated PowerShell. Safe to re-run.

.DESCRIPTION
  The Windows counterpart of hosts/bootstrap/bootstrap.sh. A new host has neither repo, so the timed
  reconcile cannot be the first step. This script:

    1. installs git (MinGit), Tailscale, age and sops from pinned, checksum-verified vendor releases, all machine-wide (no WinGet);
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
# Everything the reconcile uses must be machine-wide: it runs as SYSTEM and cannot see a user's profile, and nothing here needs WinGet (it
# is a per-user app, absent on some editions, and a moving part). So every tool is the vendor's release file checked against a pinned SHA-256:
#   - git: MinGit, Git for Windows' minimal zip (no installer, no GUI), in Program Files\MinGit;
#   - Tailscale: the vendor's MSI, installed with unattended mode on;
#   - PowerShell 7, sops and age: release zips and files, in Program Files and C:\ProgramData\Consigliere\bin (readable only by SYSTEM
#     and Administrators).
# Change a version and its checksums together. Git's and age's values match the SHA-256 GitHub records for each release asset, and
# Tailscale's the .msi.sha256 file next to each MSI on pkgs.tailscale.com; windows/tools/verify-age-pins.sh checks age's against its
# Sigsum proofs (the .proof files) when you bump that version.
$GitVersion = '2.56.1'
$GitTag = 'v2.56.1.windows.1'
$GitSha256 = @{
  amd64 = '4a92850b6e917da4fd010669b614b55dccf5b0ec333a534cc4be4700dfefdafd'   # MinGit-2.56.1-64-bit.zip
  arm64 = '96571e442e90523a90e5fd8661b4c4e43bc192910f3c6db938816e6955b4cc8c'   # MinGit-2.56.1-arm64.zip
}
$TailscaleVersion = '1.104.6'
$TailscaleSha256 = @{
  amd64 = '8445636f79e258f56e01d324e5562d4ebcdf898ab84c2e618ae05014b8ba90ab'
  arm64 = '2810b17d4edcb6feb0307d0029e67426d2af78f0e4b1092fbbe307f5875c82b7'
}
$AgeVersion = '1.3.2'
$AgeSha256 = @{
  amd64 = 'f48d8f8f9ebe903ab5027ed067652f2cc1db94bc206976430133b905dcd8e8c7'
  arm64 = 'fae351336c8d5f30f93cc3ccdec16d1ed7851d68cdd6656d41955cc31a447c9d'
}
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
# The inherit flags (OI)(CI) are for folders only: on a file they leave an entry that applies to nothing, so the file ends up with an
# empty access list that nobody can read (found on the first real run).
function Lock-Path([string]$Path) {
  $rights = if (Test-Path -LiteralPath $Path -PathType Container) { '(OI)(CI)F' } else { 'F' }
  Invoke-Native icacls @($Path, '/inheritance:r', '/grant:r', "*S-1-5-18:$rights", "*S-1-5-32-544:$rights") | Out-Null
}

function Update-SessionPath {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# The machine's architecture, not the running process's: an x64 shell emulated on an ARM64 Windows still reports AMD64 in
# $env:PROCESSOR_ARCHITECTURE, and would fetch the wrong binaries.
function Get-OsArch {
  if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) { return 'arm64' }
  return 'amd64'
}

# git: use one that is already machine-wide (Git for Windows in Program Files); otherwise unpack MinGit and put it on the machine PATH.
function Install-MinGit {
  $existing = Get-Command git.exe -ErrorAction SilentlyContinue
  $pfs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
  if ($existing -and ($pfs | Where-Object { $existing.Source.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
    Say "OK git already installed ($($existing.Source))"; return $existing.Source
  }
  $dir = Join-Path $env:ProgramFiles 'MinGit'
  $exe = Join-Path $dir 'cmd\git.exe'
  if (-not (Test-Path $exe)) {
    $arch = Get-OsArch
    $zipName = if ($arch -eq 'arm64') { "MinGit-$GitVersion-arm64.zip" } else { "MinGit-$GitVersion-64-bit.zip" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "mingit-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      $zip = Join-Path $tmp $zipName
      Say "Downloading MinGit $GitVersion"
      Invoke-WebRequest -UseBasicParsing -OutFile $zip -Uri "https://github.com/git-for-windows/git/releases/download/$GitTag/$zipName"
      $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
      if ($got -ne $GitSha256[$arch]) { Fail "MinGit checksum mismatch (got $got)" }
      if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
      Expand-Archive -Path $zip -DestinationPath $dir -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $exe)) { Fail "git is not at $exe after unpacking." }
    Say "INSTALLED MinGit $GitVersion"
  }
  $cmd = Join-Path $dir 'cmd'
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if (($machinePath -split ';') -notcontains $cmd) { [Environment]::SetEnvironmentVariable('Path', "$machinePath;$cmd", 'Machine') }
  return $exe
}

# Tailscale: the vendor's MSI, machine-wide, with unattended mode on so the tunnel does not wait for a login. An existing install is kept.
function Install-Tailscale {
  $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (Test-Path $ts) { Say 'OK Tailscale already installed'; return }
  $arch = Get-OsArch
  $msiName = "tailscale-setup-$TailscaleVersion-$arch.msi"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "tailscale-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $msi = Join-Path $tmp $msiName
    Say "Downloading Tailscale $TailscaleVersion"
    Invoke-WebRequest -UseBasicParsing -OutFile $msi -Uri "https://pkgs.tailscale.com/stable/$msiName"
    $got = (Get-FileHash -Algorithm SHA256 $msi).Hash.ToLowerInvariant()
    if ($got -ne $TailscaleSha256[$arch]) { Fail "Tailscale checksum mismatch (got $got)" }
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', 'TS_UNATTENDEDMODE=always', 'TS_NOLAUNCH=1')
    if ($p.ExitCode -notin 0, 3010) { Fail "the Tailscale installer failed (msiexec exit $($p.ExitCode))" }
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if (-not (Test-Path $ts)) { Fail "Tailscale is not at $ts after the install." }
  Say "INSTALLED Tailscale $TailscaleVersion"
}

# ---- 0. Preconditions -------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'Run this in an elevated PowerShell (Run as administrator).'
}
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Fail 'This script is for Windows.' }

# ---- 0b. PowerShell 7 is a prerequisite ---------------------------------------------------------------
# The reconcile and the roles need PowerShell 7.4 or later (Windows PowerShell 5.1 is what a fresh Windows has). This file
# must stay valid 5.1 syntax so that it can get this far; it installs PowerShell 7 (below) and carries on there.
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
  Say "Windows PowerShell $($PSVersionTable.PSVersion) is too old; installing PowerShell 7 and continuing in it"
  if (-not $PSCommandPath) { Fail 'Save this script to a file and run it from there (it has to start itself again under PowerShell 7).' }
  $pwsh7 = Install-PowerShell7
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

# ---- 1. git and Tailscale ---------------------------------------------------------------------------
Say 'Installing git and Tailscale (pinned releases, machine-wide)'
$git = Install-MinGit
Install-Tailscale
Update-SessionPath

$pf = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
if (-not ($pf | Where-Object { $git.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
  Fail "git is at $git, outside Program Files: it was installed for one user, and the reconcile runs as SYSTEM. Uninstall it and re-run."
}
# ssh-keygen comes with Windows' own OpenSSH client (MinGit leaves it out).
$sshKeygen = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
if (-not (Test-Path $sshKeygen)) {
  Say 'Installing the Windows OpenSSH client'
  Import-Module Dism -UseWindowsPowerShell -WarningAction SilentlyContinue
  Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null
  if (-not (Test-Path $sshKeygen)) { Fail "ssh-keygen.exe is not at $sshKeygen after installing the OpenSSH client." }
}

# ---- 1a. age: pinned release, checksum verified -------------------------------------------------------
$ageKeygen = [pscustomobject]@{ Source = (Join-Path $BinDir 'age-keygen.exe') }
$ageOk = (Test-Path $ageKeygen.Source) -and ((Invoke-Native $ageKeygen.Source @('--version') -AllowFail | Out-String) -match [regex]::Escape($AgeVersion))
if ($ageOk) {
  Say "OK age $AgeVersion already installed"
} else {
  $aarch = Get-OsArch
  $atmp = Join-Path ([IO.Path]::GetTempPath()) "age-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Force -Path $atmp | Out-Null
  try {
    $azip = Join-Path $atmp 'age.zip'
    Invoke-WebRequest -UseBasicParsing -OutFile $azip -Uri "https://github.com/FiloSottile/age/releases/download/v$AgeVersion/age-v$AgeVersion-windows-$aarch.zip"
    $agot = (Get-FileHash -Algorithm SHA256 $azip).Hash.ToLowerInvariant()
    if ($agot -ne $AgeSha256[$aarch]) { Fail "age checksum mismatch (got $agot)" }
    Expand-Archive -Path $azip -DestinationPath $atmp -Force
    foreach ($n in 'age.exe', 'age-keygen.exe') { Copy-Item (Join-Path $atmp "age\$n") (Join-Path $BinDir $n) -Force }
  } finally { Remove-Item $atmp -Recurse -Force -ErrorAction SilentlyContinue }
  Say "INSTALLED age $AgeVersion"
}

# ---- 1b. sops: pinned release, checksum verified ----------------------------------------------------
$sops = Join-Path $BinDir 'sops.exe'
$sopsOk = (Test-Path $sops) -and ((Invoke-Native $sops @('--version') -AllowFail | Out-String) -match [regex]::Escape($SopsVersion))
if ($sopsOk) {
  Say "OK sops $SopsVersion already installed"
} else {
  $arch = Get-OsArch
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
# A copy left by an earlier run may carry a broken access list (an empty one, from the first version of Lock-Path). Start clean; if the
# delete is refused, take ownership, reset the list and try again, and say so rather than failing later with "access denied".
if (Test-Path -LiteralPath $ConfigFile) {
  try { Remove-Item -LiteralPath $ConfigFile -Force -ErrorAction Stop }
  catch {
    Warn "could not delete the old $ConfigFile ($($_.Exception.Message)); taking ownership and resetting its access list"
    Invoke-Native takeown.exe @('/f', $ConfigFile) -AllowFail | Out-Null
    Invoke-Native icacls.exe @($ConfigFile, '/reset') -AllowFail | Out-Null
    Remove-Item -LiteralPath $ConfigFile -Force -ErrorAction Stop
  }
}
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
