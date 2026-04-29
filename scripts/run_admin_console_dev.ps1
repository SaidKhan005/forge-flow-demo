# Phase 11A.0 — Run the F&F Operations Console (Flutter Web) locally.
#
# Defaults to LIVE Firebase admin auth (matches the Cloud Run
# default) so a local dev session validates the same gate that
# production uses. The Dart `kAdminFirebaseOptions` constant mirrors
# `web/firebase-config.js`, so no local secret is required beyond the
# committed staging Firebase web API key + project id.
#
# Pass `-DemoMode` to swap in the fixture-login demo source for the
# 11A.0 walkthrough (super.admin@ / support@ / operator@). Demo mode
# is intentionally opt-in so local dev exercises the production
# auth path by default.
#
# Examples:
#   scripts/run_admin_console_dev.ps1
#   scripts/run_admin_console_dev.ps1 -Device chrome
#   scripts/run_admin_console_dev.ps1 -DemoMode
#   scripts/run_admin_console_dev.ps1 -PrintCommandOnly

param(
  [string] $Device = 'chrome',

  [switch] $DemoMode,

  [switch] $PrintCommandOnly,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$argsList = @(
  'run',
  '-t', 'lib/main_admin.dart',
  '-d', $Device
)

if ($DemoMode) {
  $argsList += '--dart-define=ADMIN_DEMO_AUTH=true'
}

if ($FlutterArgs.Count -gt 0) {
  $argsList += $FlutterArgs
}

if ($PrintCommandOnly) {
  Write-Host "flutter $($argsList -join ' ')"
  exit 0
}

Push-Location $repoRoot
try {
  & flutter @argsList
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
