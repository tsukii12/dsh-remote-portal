<#
.SYNOPSIS
  Install dsh-remote-portal into one or more DeepSeek Harness profiles.

.DESCRIPTION
  A profile is an ordered stack of bundle patches under $DSH_HOME/profiles/<name>.
  Installing this plugin means exactly two edits plus a pnpm link:

    1. package.json  dependencies:  "dsh-remote-portal": "link:<plugin dir>"
    2. package.json  dsh.profile.bundles:  [..., "dsh-remote-portal"]
    3. pnpm install in the profile directory (the plugin has no dependencies,
       so this only creates the symlink)

  The script is idempotent, backs up package.json before touching it, and never
  modifies cordis.patch.yml — runtime switches live in the Settings panel and are
  persisted to $DSH_HOME/dsh-remote-portal/state.json.

  A restart of the target profile is required afterwards: exiting and reopening
  the desktop app, or Ctrl+C then `dsh web` for the web profile.

.PARAMETER Profile
  Profile names to install into. Default: desktop, web.

.PARAMETER PluginDir
  The plugin directory. Default: the directory this script lives in.

.PARAMETER Uninstall
  Remove the plugin from the given profiles instead.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Profile web
  .\install.ps1 -Uninstall -Profile web
#>
[CmdletBinding()]
param(
  [string[]] $Profile = @('desktop', 'web'),
  [string] $PluginDir = $PSScriptRoot,
  [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$packageName = 'dsh-remote-portal'

if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $env:DSH_HOME = Join-Path $HOME '.dsh' }
$profilesRoot = Join-Path $env:DSH_HOME 'profiles'
$pluginPath = (Resolve-Path -LiteralPath $PluginDir).Path
$manifestPath = Join-Path $pluginPath 'package.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "dsh-remote-portal: $manifestPath not found — point -PluginDir at the plugin checkout."
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.name -ne $packageName) {
  throw "dsh-remote-portal: $manifestPath declares '$($manifest.name)', expected '$packageName'."
}

function Get-DshExe {
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $guess = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'
  if (Test-Path -LiteralPath $guess) { return $guess }
  throw 'dsh-remote-portal: the dsh CLI is not on PATH.'
}

$dsh = Get-DshExe

foreach ($name in $Profile) {
  $profileDir = Join-Path $profilesRoot $name
  $pkgPath = Join-Path $profileDir 'package.json'

  if (-not (Test-Path -LiteralPath $pkgPath)) {
    if ($Uninstall) { Write-Warning "[$name] no profile at $profileDir — skipped."; continue }
    Write-Host "[$name] profile does not exist; creating it from the shipped 'web' template…" -ForegroundColor Cyan
    & $dsh --profile $name --from-default-profile web --dump-config | Out-Null
    if (-not (Test-Path -LiteralPath $pkgPath)) { throw "[$name] profile creation did not produce $pkgPath" }
  }

  $raw = Get-Content -LiteralPath $pkgPath -Raw
  $pkg = $raw | ConvertFrom-Json
  if (-not $pkg.PSObject.Properties['dsh'] -or -not $pkg.dsh.profile) {
    throw "[$name] $pkgPath has no dsh.profile section — is this a Harness profile?"
  }

  $bundles = @()
  if ($pkg.dsh.profile.PSObject.Properties['bundles']) { $bundles = @($pkg.dsh.profile.bundles) }
  $hasBundle = $bundles -contains $packageName

  if ($Uninstall) {
    if (-not $hasBundle) { Write-Host "[$name] not installed — nothing to do." -ForegroundColor DarkGray; continue }
    Copy-Item -LiteralPath $pkgPath -Destination "$pkgPath.bak-portal" -Force
    $newBundles = @($bundles | Where-Object { $_ -ne $packageName })
    if ($pkg.dependencies -and $pkg.dependencies.PSObject.Properties[$packageName]) {
      $pkg.dependencies.PSObject.Properties.Remove($packageName)
    }
    $pkg.dsh.profile.bundles = $newBundles
    ($pkg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $pkgPath -Encoding utf8
    & $dsh plugin --profile $name install
    Write-Host "[$name] removed. Restart this profile to unload the gateway." -ForegroundColor Yellow
    continue
  }

  # ── install ───────────────────────────────────────────────────────────────
  $linkSpec = "link:$($pluginPath -replace '\\', '/')"
  Copy-Item -LiteralPath $pkgPath -Destination "$pkgPath.bak-portal" -Force

  if (-not $pkg.PSObject.Properties['dependencies'] -or $null -eq $pkg.dependencies) {
    $pkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  if ($pkg.dependencies.PSObject.Properties[$packageName]) {
    $pkg.dependencies.$packageName = $linkSpec
  } else {
    $pkg.dependencies | Add-Member -NotePropertyName $packageName -NotePropertyValue $linkSpec -Force
  }

  if (-not $hasBundle) {
    $newBundles = @($bundles + $packageName)
    if ($pkg.dsh.profile.PSObject.Properties['bundles']) { $pkg.dsh.profile.bundles = $newBundles }
    else { $pkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $newBundles -Force }
  } else {
    Write-Host "[$name] bundle entry already present — refreshing the link." -ForegroundColor DarkGray
  }

  ($pkg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $pkgPath -Encoding utf8

  Write-Host "[$name] linking $packageName …" -ForegroundColor Cyan
  & $dsh plugin --profile $name install | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "[$name] pnpm install failed with exit code $LASTEXITCODE" }

  # Verify the composed tree really carries the row, so a silent YAML/manifest
  # problem is caught here instead of at the user's next launch. The `desktop`
  # profile is owned by the Electron application and refuses `--dump-config`
  # from the CLI, so there the two file edits above are the whole contract.
  $dump = & $dsh --profile $name --dump-config 2>&1 | Out-String
  if ($dump -match 'managed exclusively by the Electron application') {
    Write-Host "[$name] OK — profile is Electron-managed (no CLI config dump); the dependency and bundle row are written." -ForegroundColor Green
  } elseif ($dump -notmatch [regex]::Escape($packageName)) {
    throw "[$name] plugin row missing from the composed profile — check $pkgPath and cordis.patch.yml."
  } else {
    Write-Host "[$name] OK — row composes. Restart this profile to start the gateway." -ForegroundColor Green
  }
}

Write-Host ''
Write-Host 'Next: restart the profile, then open Settings → 远程访问 to set a password and scan the QR code.' -ForegroundColor Green
Write-Host "State and sessions live in: $(Join-Path $env:DSH_HOME 'dsh-remote-portal')"
