param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet(
    'BuildLocal',
    'BuildRolling',
    'InstallEquicord',
    'BuildInstallEquicord',
    'RestoreEquicord',
    'LaunchDiscord',
    'Clean'
  )]
  [string] $Task
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BuildPath = Join-Path $RepoRoot 'tmp\app.asar'

function Write-Step([string] $Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Command([string] $Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found in PATH."
  }
}

function Assert-Windows {
  if (-not $IsWindows) {
    throw 'This task is Windows-only.'
  }
}

function Get-GitShortSha {
  Assert-Command 'git'
  $sha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $sha) {
    throw 'Could not determine the current Git commit.'
  }
  return $sha
}

function Get-UpdateRepo {
  Assert-Command 'git'
  $origin = (& git -C $RepoRoot remote get-url origin).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $origin) {
    throw 'Could not read the origin remote URL.'
  }

  if ($origin -match 'github\.com[/:](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
    return "$($Matches.owner)/$($Matches.repo -replace '\.git$', '')"
  }

  throw "Origin is not a GitHub repository URL: $origin"
}

function Invoke-Pack([string[]] $Arguments) {
  Assert-Command 'node'
  Assert-Command 'asar'

  Push-Location $RepoRoot
  try {
    & node (Join-Path $RepoRoot 'scripts\pack.js') @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "scripts/pack.js exited with code $LASTEXITCODE."
    }
  }
  finally {
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $BuildPath -PathType Leaf)) {
    throw "Build completed without producing $BuildPath."
  }
  if ((Get-Item -LiteralPath $BuildPath).Length -le 0) {
    throw "Build output is empty: $BuildPath"
  }

  return $BuildPath
}

function Build-Local {
  Write-Step 'Building local OpenAsar (auto-update disabled)'
  $sha = Get-GitShortSha
  $version = "dev-$sha"

  $result = Invoke-Pack @(
    '--disable-autoupdate',
    '--version', $version,
    '--output', $BuildPath
  )

  Write-Host "Built $version -> $result" -ForegroundColor Green
  return $result
}

function Build-Rolling {
  Write-Step 'Building local rolling-channel OpenAsar'
  $sha = Get-GitShortSha
  $updateRepo = Get-UpdateRepo

  $versions = @()
  foreach ($tag in (& git -C $RepoRoot tag --list 'v*')) {
    if ($tag -match '^v(\d+)\.(\d+)\.(\d+)$') {
      $versions += [Version]::new([int] $Matches[1], [int] $Matches[2], [int] $Matches[3])
    }
  }

  if ($LASTEXITCODE -ne 0) {
    throw 'Could not enumerate Git tags.'
  }

  $latest = if ($versions.Count -gt 0) {
    $versions | Sort-Object -Descending | Select-Object -First 1
  }
  else {
    [Version]::new(0, 0, 0)
  }

  $nextPatch = $latest.Build + 1
  $version = "$($latest.Major).$($latest.Minor).$nextPatch-nightly.local+$sha"

  $result = Invoke-Pack @(
    '--update-repo', $updateRepo,
    '--update-channel', 'rolling-nightly',
    '--version', $version,
    '--output', $BuildPath
  )

  Write-Host "Built $version -> $result" -ForegroundColor Green
  return $result
}

function Get-DiscordLayout {
  Assert-Windows

  if (-not $env:LOCALAPPDATA) {
    throw 'LOCALAPPDATA is not defined.'
  }

  $discordRoot = Join-Path $env:LOCALAPPDATA 'Discord'
  if (-not (Test-Path -LiteralPath $discordRoot -PathType Container)) {
    throw "Discord installation directory was not found: $discordRoot"
  }

  $candidates = @()
  foreach ($dir in (Get-ChildItem -LiteralPath $discordRoot -Directory -ErrorAction Stop)) {
    if ($dir.Name -notmatch '^app-(.+)$') {
      continue
    }

    try {
      $version = [Version] $Matches[1]
    }
    catch {
      continue
    }

    $resources = Join-Path $dir.FullName 'resources'
    if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
      continue
    }

    $candidates += [pscustomobject]@{
      Directory = $dir
      Version = $version
      Resources = $resources
    }
  }

  $active = $candidates | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $active) {
    throw "No usable app-* Discord installation was found under $discordRoot."
  }

  return [pscustomobject]@{
    Root = $discordRoot
    AppDirectory = $active.Directory.FullName
    Version = $active.Version
    Resources = $active.Resources
    LoaderAsar = Join-Path $active.Resources 'app.asar'
    TargetAsar = Join-Path $active.Resources '_app.asar'
    WorkingBackup = Join-Path $active.Resources '_app.asar.backup'
    StockBackup = Join-Path $active.Resources 'app.asar.backup'
    Updater = Join-Path $discordRoot 'Update.exe'
  }
}

function Assert-EquicordLayout($Layout) {
  if (-not (Test-Path -LiteralPath $Layout.LoaderAsar -PathType Leaf)) {
    throw "Equicord loader app.asar is missing: $($Layout.LoaderAsar)"
  }
  if (-not (Test-Path -LiteralPath $Layout.TargetAsar -PathType Leaf)) {
    throw "_app.asar is missing. Refusing to modify this Discord install because it does not look Equicord-patched."
  }

  $loader = Get-Item -LiteralPath $Layout.LoaderAsar
  if ($loader.Length -gt 1MB) {
    throw "resources\app.asar is unexpectedly large ($($loader.Length) bytes). Refusing to overwrite an installation that may not use the Equicord loader layout."
  }

  $loaderText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Layout.LoaderAsar))
  if ($loaderText -notmatch '(?i)equicord') {
    throw 'resources\app.asar does not reference Equicord. Refusing to touch _app.asar.'
  }

  Write-Host "Discord $($Layout.Version): $($Layout.AppDirectory)" -ForegroundColor DarkGray
  Write-Host 'Equicord loader layout verified.' -ForegroundColor Green
  if (Test-Path -LiteralPath $Layout.StockBackup -PathType Leaf) {
    Write-Host "Preserving Equilotl stock backup: $($Layout.StockBackup)" -ForegroundColor DarkGray
  }
}

function Stop-Discord {
  Write-Step 'Stopping Discord'

  $processes = @(Get-Process -Name 'Discord' -ErrorAction SilentlyContinue)
  if ($processes.Count -gt 0) {
    $processes | Stop-Process -Force
  }

  $deadline = (Get-Date).AddSeconds(15)
  do {
    $processes = @(Get-Process -Name 'Discord' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
      Write-Host 'Discord is fully stopped.' -ForegroundColor Green
      return
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)

  $pids = ($processes.Id -join ', ')
  throw "Discord is still running after 15 seconds (PID(s): $pids)."
}

function Start-Discord($Layout) {
  if (@(Get-Process -Name 'Discord' -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host 'Discord is already running.' -ForegroundColor Yellow
    return
  }

  if (-not (Test-Path -LiteralPath $Layout.Updater -PathType Leaf)) {
    throw "Discord Update.exe was not found: $($Layout.Updater). Refusing to bypass the normal launcher path."
  }

  Write-Step 'Starting Discord normally through Update.exe'
  Start-Process -FilePath $Layout.Updater -ArgumentList @('--processStart', 'Discord.exe') -WorkingDirectory $Layout.Root | Out-Null

  $deadline = (Get-Date).AddSeconds(20)
  do {
    if (@(Get-Process -Name 'Discord' -ErrorAction SilentlyContinue).Count -gt 0) {
      Write-Host 'Discord started.' -ForegroundColor Green
      return
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)

  throw 'Discord did not appear within 20 seconds after Update.exe launch.'
}

function Replace-EquicordAsar($Layout, [string] $SourceAsar) {
  if (-not (Test-Path -LiteralPath $SourceAsar -PathType Leaf)) {
    throw "Build to install does not exist: $SourceAsar"
  }

  if (@(Get-Process -Name 'Discord' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Discord restarted while preparing the install. Refusing to replace _app.asar.'
  }

  Write-Step 'Backing up current Equicord _app.asar'
  $oldHash = (Get-FileHash -LiteralPath $Layout.TargetAsar -Algorithm SHA256).Hash
  Copy-Item -LiteralPath $Layout.TargetAsar -Destination $Layout.WorkingBackup -Force
  $backupHash = (Get-FileHash -LiteralPath $Layout.WorkingBackup -Algorithm SHA256).Hash
  if ($backupHash -ne $oldHash) {
    throw 'Backup verification failed. _app.asar was not modified.'
  }
  Write-Host "Backup verified: $($Layout.WorkingBackup)" -ForegroundColor Green

  Write-Step 'Replacing Equicord _app.asar'
  try {
    Remove-Item -LiteralPath $Layout.TargetAsar -Force
    Copy-Item -LiteralPath $SourceAsar -Destination $Layout.TargetAsar -Force

    $sourceHash = (Get-FileHash -LiteralPath $SourceAsar -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $Layout.TargetAsar -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
      throw 'Installed _app.asar hash does not match the build output.'
    }
  }
  catch {
    Write-Warning 'Installation failed. Attempting to restore the verified backup.'
    if (Test-Path -LiteralPath $Layout.WorkingBackup -PathType Leaf) {
      Copy-Item -LiteralPath $Layout.WorkingBackup -Destination $Layout.TargetAsar -Force
    }
    throw
  }

  Write-Host "Installed: $($Layout.TargetAsar)" -ForegroundColor Green
}

function Install-ExistingEquicordBuild {
  $layout = Get-DiscordLayout
  Assert-EquicordLayout $layout

  if (-not (Test-Path -LiteralPath $BuildPath -PathType Leaf)) {
    throw "No existing build found at $BuildPath. Run 'OpenAsar | Build Local' first."
  }

  Stop-Discord
  try {
    Replace-EquicordAsar $layout $BuildPath
  }
  catch {
    try { Start-Discord $layout } catch { Write-Warning "Discord could not be restarted after the failed install: $($_.Exception.Message)" }
    throw
  }
  Start-Discord $layout
}

function Build-And-InstallEquicord {
  $layout = Get-DiscordLayout
  Assert-EquicordLayout $layout

  # Keep this order deliberate: stop, verify dead, build, backup, replace, launch.
  Stop-Discord
  try {
    $build = Build-Local
    Replace-EquicordAsar $layout $build
  }
  catch {
    try { Start-Discord $layout } catch { Write-Warning "Discord could not be restarted after the failed operation: $($_.Exception.Message)" }
    throw
  }
  Start-Discord $layout
}

function Restore-EquicordBackup {
  $layout = Get-DiscordLayout
  Assert-EquicordLayout $layout

  if (-not (Test-Path -LiteralPath $layout.WorkingBackup -PathType Leaf)) {
    throw "Working backup does not exist: $($layout.WorkingBackup)"
  }

  Stop-Discord
  try {
    Write-Step 'Restoring _app.asar.backup'
    Copy-Item -LiteralPath $layout.WorkingBackup -Destination $layout.TargetAsar -Force

    $backupHash = (Get-FileHash -LiteralPath $layout.WorkingBackup -Algorithm SHA256).Hash
    $restoredHash = (Get-FileHash -LiteralPath $layout.TargetAsar -Algorithm SHA256).Hash
    if ($backupHash -ne $restoredHash) {
      throw 'Restored _app.asar hash does not match the backup.'
    }
    Write-Host 'Backup restored and verified.' -ForegroundColor Green
  }
  catch {
    try { Start-Discord $layout } catch { Write-Warning "Discord could not be restarted after restore failure: $($_.Exception.Message)" }
    throw
  }
  Start-Discord $layout
}

function Clean-DevBuilds {
  Write-Step 'Cleaning local OpenAsar build output'

  $paths = @(
    (Join-Path $RepoRoot 'tmp\app.asar'),
    (Join-Path $RepoRoot 'tmp\pack-build'),
    (Join-Path $RepoRoot 'tmp\openasar-build')
  )

  foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Recurse -Force
      Write-Host "Removed $path" -ForegroundColor DarkGray
    }
  }

  Write-Host 'Clean complete.' -ForegroundColor Green
}

switch ($Task) {
  'BuildLocal' { [void] (Build-Local) }
  'BuildRolling' { [void] (Build-Rolling) }
  'InstallEquicord' { Install-ExistingEquicordBuild }
  'BuildInstallEquicord' { Build-And-InstallEquicord }
  'RestoreEquicord' { Restore-EquicordBackup }
  'LaunchDiscord' {
    $layout = Get-DiscordLayout
    Assert-EquicordLayout $layout
    Start-Discord $layout
  }
  'Clean' { Clean-DevBuilds }
}