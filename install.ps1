<#
.SYNOPSIS
  Install yuremote into one or more DeepSeek Harness profiles.

.DESCRIPTION
  Links YuRemote into each profile without a package manager or downloads.
  Existing installations are migrated with their state and configuration intact.

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
$packageName = 'yuremote'

if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $env:DSH_HOME = Join-Path $HOME '.dsh' }
$profilesRoot = Join-Path $env:DSH_HOME 'profiles'
$pluginPath = (Resolve-Path -LiteralPath $PluginDir).Path
$manifestPath = Join-Path $pluginPath 'package.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "yuremote: $manifestPath not found — point -PluginDir at the plugin checkout."
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.name -ne $packageName) {
  throw "yuremote: $manifestPath declares '$($manifest.name)', expected '$packageName'."
}

function Get-DshExe {
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $guess = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'
  if (Test-Path -LiteralPath $guess) { return $guess }
  throw 'yuremote: the dsh CLI is not on PATH.'
}

$node = (Get-Command node -ErrorAction Stop).Source
$installer = Join-Path $pluginPath 'tools/install-profile.mjs'
$mode = if ($Uninstall) { 'uninstall' } else { 'install' }

foreach ($name in $Profile) {
  $profileDir = Join-Path $profilesRoot $name
  $pkgPath = Join-Path $profileDir 'package.json'

  if (-not (Test-Path -LiteralPath $pkgPath)) {
    if ($Uninstall) { Write-Warning "[$name] no profile at $profileDir — skipped."; continue }
    Write-Host "[$name] profile does not exist; creating it from the shipped 'web' template…" -ForegroundColor Cyan
    $dsh = Get-DshExe
    & $dsh --profile $name --from-default-profile web --dump-config | Out-Null
    if (-not (Test-Path -LiteralPath $pkgPath)) { throw "[$name] profile creation did not produce $pkgPath" }
  }

  & $node $installer $mode $pluginPath $profileDir $env:DSH_HOME
  if ($LASTEXITCODE -ne 0) { throw "[$name] YuRemote installer failed with exit code $LASTEXITCODE" }
}

if ($Uninstall) { return }
Write-Host ''
Write-Host 'Next: restart the profile, then open 远程访问 / Remote access in the sidebar to set a password and scan the QR code.' -ForegroundColor Green
Write-Host "State and sessions live in: $(Join-Path $env:DSH_HOME 'yuremote')"
