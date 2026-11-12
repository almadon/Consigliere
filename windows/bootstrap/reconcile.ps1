#Requires -Version 7.4
<#
.SYNOPSIS
  The timed pull for a Windows host: sync both repos, work out what this host runs, run the roles.

.DESCRIPTION
  The Windows counterpart of hosts/bootstrap/reconcile.sh, run by the 'Consigliere Reconcile' Scheduled Task
  (registered by bootstrap.ps1) as SYSTEM. Each host reconciles itself; nothing reaches into it.

    1. Sync the public framework repo and the private fleet repo (a per-host read-only deploy key).
    2. Skip the run when neither repo moved since the last successful apply (a full run still happens every
       FullEverySecs, so drift is corrected, and whenever force-run exists).
    3. Find this host (its Tailscale name, case-insensitive) in config/inventory/hosts.yml and turn its values into
       groups with the keyed_groups of config/inventory/groups.yml.
    4. Merge variables: vars/group/all.yml, then each group's file in alphabetical order, then vars/host/<name>.yml.
       A later file replaces a whole key of an earlier one, as in Ansible's default.
    5. Select roles: windows/site.yml's list first, then the roles named by `windows_roles:` in the tag manifests
       (config/tags/<dim>/<value>.yml first, then the framework's hosts/tags/), in manifest `order`.
    6. Run each role script. Check mode first when a repo moved, then apply.

  A role is windows/roles/<name>/role.ps1 (or config/windows/roles/<name>/role.ps1 in the fleet repo, which wins).
  It is a script taking -Context and returning @{ Changed = <bool>; Message = <string> }. It must not change
  anything when $Context.Check is true, and must throw when it fails. See docs/windows-host.md.

  Limits of the first version, stated so they are not a surprise: group `groups:` rules and `compose:` in
  groups.yml are not evaluated (a warning is logged); Jinja in variable files is not expanded (values are used
  as written); host_vars from vars/routes are not read.

.PARAMETER Mode
  check  report what would change, change nothing.
  apply  (default) pre-check when a repo moved, then apply.
#>
[CmdletBinding()]
param(
  [ValidateSet('check', 'apply')][string]$Mode = 'apply',
  [string]$Root = (Join-Path $env:ProgramData 'Consigliere')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:GIT_TERMINAL_PROMPT = '0'   # an unattended run never waits on a credentials prompt

$ConfigFile  = Join-Path $Root 'reconcile.json'
$CredDir     = Join-Path $Root 'creds'
$DeployKey   = Join-Path $CredDir 'deploy_key'
$AgeKey      = Join-Path $CredDir 'age.key'
$FrameworkDir = Join-Path $Root 'framework'
$FleetDir    = Join-Path $Root 'fleet-config'
$BinDir      = Join-Path $Root 'bin'
$ModuleDir   = Join-Path $Root 'modules'
$StateFile   = Join-Path $Root 'last-applied'
$ForceFile   = Join-Path $Root 'force-run'
$StatusFile  = Join-Path $Root 'last-status.json'
$RunLog      = Join-Path $Root 'last-run.log'
$Sops        = Join-Path $BinDir 'sops.exe'
$YamlModuleVersion = '0.4.9'   # powershell-yaml, pinned: the package's SHA-256 below (the nupkg as the Gallery serves it)
$YamlModuleSha256 = '9148c268709ab46b21835c3ed8502ebdbff4a6dc19e65b7b3dd6b66e9131fd28'
$EventSource = 'Consigliere'

function Say($m)  { Write-Host "==> $m" }
function Warn($m) { Write-Warning $m }
function Fail($m) { throw $m }

# stderr from a native program must not become a terminating error in Windows PowerShell 5.1; the exit code decides.
function Invoke-Native {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [switch]$AllowFail)
  $ErrorActionPreference = 'Continue'
  $out = & $Exe @Arguments 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { Fail "$Exe $($Arguments -join ' ') failed ($LASTEXITCODE): $out" }
  return $out
}

function Write-Event([string]$Message, [string]$Type = 'Information', [int]$Id = 1000) {
  try {
    if (-not [Diagnostics.EventLog]::SourceExists($EventSource)) { [Diagnostics.EventLog]::CreateEventSource($EventSource, 'Application') }
    [Diagnostics.EventLog]::WriteEntry($EventSource, $Message, [Diagnostics.EventLogEntryType]$Type, $Id)
  } catch { Warn "could not write to the Event Log: $($_.Exception.Message)" }
}

# ---- single instance, log, settings -----------------------------------------------------------------
$mutex = New-Object Threading.Mutex($false, 'Global\ConsigliereReconcile')
if (-not $mutex.WaitOne(0)) { Write-Host 'Another reconcile is running; this one does nothing.'; exit 0 }

$script:Roles = New-Object Collections.ArrayList   # one entry per role this run: name, outcome, message
$script:Outcome = 'failed'
$script:Reason = ''
$script:Fingerprint = ''
$script:TsName = ''
$script:ConfDir = ''
$settings = $null
$transcript = $false
try { Start-Transcript -Path $RunLog -Force | Out-Null; $transcript = $true } catch { Warn "no transcript: $($_.Exception.Message)" }

function Send-Heartbeat([string]$Url) {
  if (-not $Url) { return }
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $Url | Out-Null } catch { }   # never fails the run
}

# ---- YAML (powershell-yaml, pinned, saved under the Consigliere folder) -------------------------------
function Initialize-Yaml {
  if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) { return }
  $psd1 = Join-Path $ModuleDir "powershell-yaml\$YamlModuleVersion\powershell-yaml.psd1"
  if (-not (Test-Path $psd1)) {
    # Straight from the Gallery's package URL, checked against a pinned SHA-256. (Install-Module and Save-Module need the NuGet
    # provider, which PowerShell 7 does not have the way Windows PowerShell does, and would need a trusted-repository prompt.)
    Say "Fetching powershell-yaml $YamlModuleVersion"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "psyaml-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      $pkg = Join-Path $tmp 'powershell-yaml.zip'   # a .nupkg is a zip; Expand-Archive wants the extension
      Invoke-WebRequest -UseBasicParsing -OutFile $pkg -Uri "https://www.powershellgallery.com/api/v2/package/powershell-yaml/$YamlModuleVersion"
      $got = (Get-FileHash -Algorithm SHA256 $pkg).Hash.ToLowerInvariant()
      if ($got -ne $YamlModuleSha256) { Fail "powershell-yaml checksum mismatch (got $got)" }
      $dest = Split-Path $psd1
      if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
      Expand-Archive -Path $pkg -DestinationPath $dest -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Import-Module $psd1 -Force
}
function Read-Yaml([string]$Path) {
  $t = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if (-not $t -or -not $t.Trim()) { return @{} }
  $d = ConvertFrom-Yaml $t
  if ($null -eq $d) { return @{} }
  return $d
}
# The leading comma stops PowerShell from unwrapping a one-element (or empty) array on return.
function As-List($v) { if ($null -eq $v) { return ,@() } else { return ,@($v) } }
function Merge-Vars([hashtable]$Base, $Over) {   # a later value replaces a whole key
  if ($Over) { foreach ($k in $Over.Keys) { $Base[$k] = $Over[$k] } }
}

# ---- repos ------------------------------------------------------------------------------------------
function Sync-Repo([string]$Url, [string]$Branch, [string]$Dir) {
  if (Test-Path (Join-Path $Dir '.git')) {
    Invoke-Native git @('-C', $Dir, 'remote', 'set-url', 'origin', $Url) | Out-Null
    Invoke-Native git @('-C', $Dir, 'fetch', 'origin') | Out-Null
    if ($Branch) {
      Invoke-Native git @('-C', $Dir, 'checkout', $Branch) | Out-Null
      Invoke-Native git @('-C', $Dir, 'reset', '--hard', "origin/$Branch") | Out-Null
    } else {
      Invoke-Native git @('-C', $Dir, 'remote', 'set-head', 'origin', '--auto') | Out-Null
      Invoke-Native git @('-C', $Dir, 'reset', '--hard', 'origin/HEAD') | Out-Null
    }
  } else {
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    $a = @('clone'); if ($Branch) { $a += @('--branch', $Branch) }; $a += @($Url, $Dir)
    Invoke-Native git $a | Out-Null
  }
}

# ---- inventory --------------------------------------------------------------------------------------
function Find-HostEntry($Node, [string]$Name) {   # the `hosts:` mapping may sit anywhere under the groups
  if ($Node -is [System.Collections.IDictionary]) {
    if ($Node.Contains('hosts') -and $Node['hosts'] -is [System.Collections.IDictionary]) {
      foreach ($k in $Node['hosts'].Keys) {
        if ($k.ToString().ToLowerInvariant() -eq $Name) {
          $v = $Node['hosts'][$k]
          if ($null -eq $v) { return @{} } else { return $v }
        }
      }
    }
    foreach ($k in $Node.Keys) { $r = Find-HostEntry $Node[$k] $Name; if ($null -ne $r) { return $r } }
  }
  return $null
}
function Get-Groups($HostVars, $GroupsDef) {
  $g = New-Object Collections.Generic.List[string]
  if ($GroupsDef -is [System.Collections.IDictionary]) {
    foreach ($kg in (As-List $GroupsDef['keyed_groups'])) {
      $key = [string]$kg['key']; if (-not $key -or -not $HostVars.Contains($key)) { continue }
      $prefix = [string]$kg['prefix']; $sep = if ($kg.Contains('separator')) { [string]$kg['separator'] } else { '_' }
      foreach ($val in (As-List $HostVars[$key])) {
        $name = ($(if ($prefix) { "$prefix$sep$val" } else { "$val" })) -replace '[^A-Za-z0-9_]', '_'
        if (-not $g.Contains($name)) { $g.Add($name) }
      }
    }
    foreach ($unsupported in 'groups', 'compose') {
      if ($GroupsDef.Contains($unsupported) -and $GroupsDef[$unsupported]) { Warn "groups.yml '$unsupported' is not evaluated on Windows; only keyed_groups are." }
    }
  }
  $g.Add('os_windows')   # the counterpart of the baseline's automatic os_<system> groups
  $arr = $g.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)   # Ansible merges same-level groups alphabetically
  return $arr
}
function Read-VarsFor([string]$Dir, [string]$Name) {   # <Name>.yml, or a <Name>/ directory of .yml files
  $r = @{}
  $f = Join-Path $Dir "$Name.yml"
  if (Test-Path -LiteralPath $f) { Merge-Vars $r (Read-Yaml $f) }
  $d = Join-Path $Dir $Name
  if (Test-Path -LiteralPath $d -PathType Container) {
    foreach ($x in (Get-ChildItem -LiteralPath $d -Filter '*.yml' | Sort-Object Name)) { Merge-Vars $r (Read-Yaml $x.FullName) }
  }
  return $r
}

# ---- tag manifests ----------------------------------------------------------------------------------
function Find-Manifest([string]$Tag, [string[]]$Dirs) {
  foreach ($d in $Dirs) { $p = Join-Path $d ($Tag + '.yml'); if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}
function Get-TagPlan($HostVars, [string[]]$TagDirs) {
  $dims = 'util', 'feat', 'cert', 'prop', 'fw'
  $queue = New-Object Collections.Queue
  foreach ($dim in $dims) {
    if (-not $HostVars.Contains($dim)) { continue }
    $vals = As-List $HostVars[$dim]
    if ($vals.Count -gt 0 -and (Find-Manifest "$dim/_default" $TagDirs)) { $queue.Enqueue("$dim/_default") }
    foreach ($v in $vals) { $queue.Enqueue("$dim/$v") }
  }
  $seen = @{}; $found = @()
  while ($queue.Count -gt 0) {
    $tag = [string]$queue.Dequeue()
    if ($seen.ContainsKey($tag)) { continue }
    $seen[$tag] = $true
    $path = Find-Manifest $tag $TagDirs
    if (-not $path) { continue }   # a tag with no manifest is just a class
    $m = Read-Yaml $path
    if ($m -isnot [System.Collections.IDictionary]) { Fail "tag manifest $path must be a YAML mapping" }
    foreach ($r in (As-List $m['requires'])) { $queue.Enqueue([string]$r) }
    $order = 50; if ($m.Contains('order')) { $order = [int]$m['order'] }
    $found += [pscustomobject]@{ Tag = $tag; Order = $order; Roles = (As-List $m['windows_roles']); Vars = $(if ($m.Contains('windows_vars') -and $m['windows_vars']) { $m['windows_vars'] } else { @{} }); Path = $path }
  }
  $plan = @(); $done = @{}
  foreach ($t in ($found | Sort-Object Order, Tag)) {
    if ($t.Roles.Count -eq 0) { continue }   # no windows_roles: for Windows the tag is just a class
    foreach ($r in $t.Roles) {
      if ($done.ContainsKey($r)) { continue }
      $done[$r] = $true
      $plan += [pscustomobject]@{ Role = [string]$r; Tag = $t.Tag; Vars = $t.Vars }
    }
  }
  return $plan
}

# ---- secrets ----------------------------------------------------------------------------------------
# A scope is "<kind>.<name>", the file config/secrets/<kind>/<name>.yml, as for the Linux load_secrets role.
function Get-FleetSecret([string]$Scope) {
  $i = $Scope.IndexOf('.')
  if ($i -lt 1) { Fail "secret scope '$Scope' must look like <kind>.<name>" }
  $file = Join-Path (Join-Path (Join-Path $script:ConfDir 'secrets') $Scope.Substring(0, $i)) ($Scope.Substring($i + 1) + '.yml')
  if (-not (Test-Path -LiteralPath $file)) { Fail "no secret file for '$Scope' ($file)" }
  $env:SOPS_AGE_KEY_FILE = $AgeKey
  $out = Invoke-Native $Sops @('-d', '--input-type', 'yaml', '--output-type', 'yaml', $file) -AllowFail
  if ($LASTEXITCODE -ne 0) { Fail "Cannot decrypt secret '$Scope' (is this host a recipient? run scripts/access.sh sync): $($out | Select-Object -First 1)" }
  return (ConvertFrom-Yaml (($out | Out-String)))
}

# ---- the run ----------------------------------------------------------------------------------------
function Invoke-Roles($Plan, [bool]$Check, [hashtable]$BaseVars) {
  $ok = 0; $changed = 0; $failed = 0
  $label = if ($Check) { 'check' } else { 'apply' }
  foreach ($step in $Plan) {
    $path = $null
    foreach ($base in @((Join-Path $script:ConfDir 'windows\roles'), (Join-Path $FrameworkDir 'windows\roles'))) {
      $p = Join-Path (Join-Path $base $step.Role) 'role.ps1'
      if (Test-Path -LiteralPath $p) { $path = $p; break }
    }
    if (-not $path) { $failed++; [void]$script:Roles.Add(@{ role = $step.Role; tag = $step.Tag; result = 'failed'; message = 'no such role (windows\roles\<name>\role.ps1)' }); Write-Host "FAILED $($step.Role): no such role"; break }
    $v = @{}; Merge-Vars $v $BaseVars; Merge-Vars $v $step.Vars
    $ctx = @{
      Name = $script:TsName; Check = $Check; Vars = $v; Tag = $step.Tag
      Paths = @{ Root = $Root; Framework = $FrameworkDir; Fleet = $FleetDir; Conf = $script:ConfDir; Bin = $BinDir; Creds = $CredDir; Sops = $Sops }
      GetSecret = { param($scope) Get-FleetSecret $scope }
    }
    Write-Host "--> [$label] $($step.Role)  (from $($step.Tag))"
    try {
      $r = & $path -Context $ctx
      $isChanged = $false; $msg = ''
      if ($r -is [System.Collections.IDictionary]) { $isChanged = [bool]$r['Changed']; $msg = [string]$r['Message'] }
      $ok++; if ($isChanged) { $changed++ }
      $res = if ($isChanged) { 'changed' } else { 'ok' }
      Write-Host "    $res $msg"
      if (-not $Check) { [void]$script:Roles.Add(@{ role = $step.Role; tag = $step.Tag; result = $res; message = $msg }) }
    } catch {
      $failed++
      $msg = $_.Exception.Message
      Write-Host "FAILED $($step.Role): $msg"
      [void]$script:Roles.Add(@{ role = $step.Role; tag = $step.Tag; result = 'failed'; message = $msg })
      break   # like Ansible: a failed role stops this host's run
    }
  }
  return @{ Ok = $ok; Changed = $changed; Failed = $failed }
}

try {
  if (-not (Test-Path $ConfigFile)) { Fail "no settings file at $ConfigFile; run bootstrap.ps1 first" }
  $settings = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
  function Setting([string]$Key, $Default = '') { if ($settings.PSObject.Properties.Name -contains $Key -and $null -ne $settings.$Key -and "$($settings.$Key)" -ne '') { return $settings.$Key } else { return $Default } }

  Initialize-Yaml
  $fullEvery = [int](Setting 'FullEverySecs' 3600)
  $precheck = [string]$(if ($env:RECONCILE_PRECHECK) { $env:RECONCILE_PRECHECK } else { Setting 'Precheck' 'auto' })

  Say 'Syncing framework repo'
  Sync-Repo ([string]$settings.FrameworkRepoUrl) ([string](Setting 'FrameworkRepoBranch')) $FrameworkDir
  Say 'Syncing private fleet-config repo'
  if (Test-Path $DeployKey) {
    $env:GIT_SSH_COMMAND = "ssh -i `"$($DeployKey -replace '\\', '/')`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  }
  Sync-Repo ([string]$settings.FleetConfigRepoUrl) ([string](Setting 'FleetConfigRepoBranch')) $FleetDir
  Remove-Item Env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue

  $fw = ((Invoke-Native git @('-C', $FrameworkDir, 'rev-parse', 'HEAD')) | Out-String).Trim()
  $fl = ((Invoke-Native git @('-C', $FleetDir, 'rev-parse', 'HEAD')) | Out-String).Trim()
  $script:Fingerprint = "$fw-$fl"
  $forced = Test-Path $ForceFile
  if ($forced) { Remove-Item $ForceFile -Force }

  # This host's identity: its Tailscale name (the host table's key), the settings file's copy if Tailscale is down.
  $tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  $script:TsName = ([string](Setting 'TailscaleName')).ToLowerInvariant()
  if (Test-Path $tsExe) {
    try {
      $self = (Invoke-Native $tsExe @('status', '--json') -AllowFail | Out-String | ConvertFrom-Json).Self
      if ($self -and $self.DNSName) { $script:TsName = ($self.DNSName -split '\.')[0].ToLowerInvariant() }
    } catch { Warn "could not read the Tailscale name; using '$($script:TsName)'" }
  }
  if (-not $script:TsName) { Fail 'this host has no Tailscale name yet (not on the tailnet?)' }

  $reposChanged = $true
  $prevFp = ''; $prevTs = 0
  if (Test-Path $StateFile) {
    $parts = (Get-Content $StateFile -Raw).Trim() -split '\s+'
    $prevFp = $parts[0]; if ($parts.Count -gt 1) { $prevTs = [int64]$parts[1] }
    if ($prevFp -eq $script:Fingerprint) { $reposChanged = $false }
  }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($Mode -eq 'apply' -and -not $forced -and $fullEvery -gt 0 -and $prevFp -eq $script:Fingerprint -and ($now - $prevTs) -lt $fullEvery) {
    Say "Nothing new in either repo since the last successful apply ($([int](($now - $prevTs) / 60)) min ago); skipping (a full run is forced every $([int]($fullEvery / 60)) min)"
    Write-Host "$($script:TsName) : ok=0 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0 (unchanged, run skipped)"
    $script:Outcome = 'skipped'
    return
  }

  $script:ConfDir = Join-Path $FleetDir ([string](Setting 'FleetConfigSubdir' 'config'))
  foreach ($need in 'inventory\hosts.yml', 'inventory\groups.yml', 'vars\group') {
    if (-not (Test-Path (Join-Path $script:ConfDir $need))) { Fail "$need not found in the fleet-config repo (see consigliere-fleet-template/)" }
  }

  Say 'Reading the host table'
  $hostEntry = Find-HostEntry (Read-Yaml (Join-Path $script:ConfDir 'inventory\hosts.yml')) $script:TsName
  if ($null -eq $hostEntry) {
    Warn "'$($script:TsName)' has no entry in inventory/hosts.yml; only the site roles run. The key must equal this host's Tailscale hostname."
    $hostEntry = @{}
  }
  $groups = Get-Groups $hostEntry (Read-Yaml (Join-Path $script:ConfDir 'inventory\groups.yml'))
  Say "Groups: $($groups -join ', ')"

  $vars = @{}
  $defaultsFile = Join-Path $FrameworkDir 'windows\defaults.yml'   # the framework's own layer, below everything the fleet sets
  if (Test-Path $defaultsFile) { Merge-Vars $vars (Read-Yaml $defaultsFile) }
  $groupDir = Join-Path $script:ConfDir 'vars\group'
  Merge-Vars $vars (Read-VarsFor $groupDir 'all')
  foreach ($g in $groups) { Merge-Vars $vars (Read-VarsFor $groupDir $g) }
  Merge-Vars $vars (Read-VarsFor (Join-Path $script:ConfDir 'vars\host') $script:TsName)
  Merge-Vars $vars $hostEntry   # the table's own values are host variables too
  $vars['inventory_hostname'] = $script:TsName
  $vars['fleet_groups'] = @($groups)

  # Site roles (always), then what the tags select.
  $siteFile = Join-Path $script:ConfDir 'windows\site.yml'
  if (-not (Test-Path $siteFile)) { $siteFile = Join-Path $FrameworkDir 'windows\site.yml' }
  $plan = @()
  if (Test-Path $siteFile) {
    foreach ($r in (As-List (Read-Yaml $siteFile)['roles'])) { $plan += [pscustomobject]@{ Role = [string]$r; Tag = 'site'; Vars = @{} } }
  }
  $have = @{}; foreach ($p in $plan) { $have[$p.Role] = $true }
  $tagDirs = @((Join-Path $script:ConfDir 'tags'), (Join-Path $FrameworkDir 'hosts\tags'))
  foreach ($p in (Get-TagPlan $hostEntry $tagDirs)) { if (-not $have.ContainsKey($p.Role)) { $plan += $p; $have[$p.Role] = $true } }
  Say "Plan: $(if ($plan.Count) { ($plan | ForEach-Object { $_.Role }) -join ', ' } else { '(no roles)' })"

  if ($Mode -eq 'check') {
    Say 'Check only'
    $res = Invoke-Roles $plan $true $vars
  } else {
    $doPre = switch ($precheck) { '1' { $true } '0' { $false } 'auto' { $reposChanged } default { Fail "Precheck must be auto, 1 or 0" } }
    if ($doPre) {
      Say 'Pre-check (nothing is changed)'
      $pre = Invoke-Roles $plan $true $vars
      if ($pre.Failed -gt 0) { Fail 'the pre-check failed; not applying' }
      $script:Roles.Clear()
    }
    Say 'Applying'
    $res = Invoke-Roles $plan $false $vars
    if ($res.Failed -eq 0) { Set-Content -Path $StateFile -Value "$($script:Fingerprint) $now" -Encoding ASCII }
  }
  Write-Host "$($script:TsName) : ok=$($res.Ok) changed=$($res.Changed) unreachable=0 failed=$($res.Failed) skipped=0 rescued=0 ignored=0"
  if ($res.Failed -gt 0) { Fail "$($res.Failed) role(s) failed" }
  $script:Outcome = 'ok'
}
catch {
  $script:Reason = $_.Exception.Message
  Write-Host "ERROR: $($script:Reason)"
  $script:Outcome = 'failed'
}
finally {
  try {
    $status = [ordered]@{
      time = (Get-Date).ToUniversalTime().ToString('o'); mode = $Mode; result = $script:Outcome; reason = $script:Reason
      fingerprint = $script:Fingerprint; host = $script:TsName; roles = @($script:Roles)
    }
    ($status | ConvertTo-Json -Depth 5) | Set-Content -Path $StatusFile -Encoding UTF8
    if ($script:Outcome -eq 'failed') { Write-Event "Reconcile ($Mode) FAILED: $($script:Reason)" 'Error' 1001 }
    elseif ($script:Outcome -eq 'ok') { Write-Event "Reconcile ($Mode) ok: $(@($script:Roles).Count) role(s) applied" 'Information' 1000 }
    if ($Mode -eq 'apply' -and $settings) {
      if ($script:Outcome -eq 'failed') {
        $fu = [string](Setting 'HeartbeatFailUrl'); if (-not $fu -and (Setting 'HeartbeatUrl')) { $fu = "$(Setting 'HeartbeatUrl')/fail" }
        Send-Heartbeat $fu
      } else { Send-Heartbeat ([string](Setting 'HeartbeatUrl')) }
    }
  } catch { Warn "could not record the result: $($_.Exception.Message)" }
  if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
  $mutex.ReleaseMutex()
}
if ($script:Outcome -eq 'failed') { exit 1 } else { exit 0 }
