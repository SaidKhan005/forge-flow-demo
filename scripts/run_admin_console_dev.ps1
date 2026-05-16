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
#   scripts/run_admin_console_dev.ps1 -AdminProxyBaseUri http://localhost:8080
#   scripts/run_admin_console_dev.ps1 -DemoMode
#   scripts/run_admin_console_dev.ps1 -PrintCommandOnly

param(
  # 4-mode runner contract. demo | preview | staging | production.
  # Defaults to `demo` so a forgotten flag does not silently point at
  # production. `-DemoMode` (below) is retained as a legacy alias that
  # forces -Mode demo with the fixture-login picker.
  [ValidateSet('demo', 'preview', 'staging', 'production')]
  [string] $Mode = 'demo',

  # Per-branch / per-PR preview slug. Required for -Mode preview unless
  # -AdminProxyBaseUri is supplied explicitly. The script resolves
  # `forge-flow-preview-<name>-admin` via `gcloud run services describe`.
  [string] $PreviewName,

  # Demo defaults to `--dart-define=ADMIN_SHARE_PREVIEW=true`, which lands
  # signed in as F&F support with NO login screen, NO Firebase, and NO
  # proxy required. The gateway resolvers in `lib/main_admin.dart` bypass
  # for `_kAdminDemoAuth || _kAdminSharePreview`.
  #
  # `-DemoFixtureLogin` swaps in `--dart-define=ADMIN_DEMO_AUTH=true` so
  # the fixture-login picker (`super.admin@` / `support@` / `operator@`)
  # renders instead - useful for exercising the gate's admit / fail-closed
  # paths.
  [switch] $DemoFixtureLogin,

  # Production safety - script refuses -Mode production without this.
  [switch] $IUnderstand,

  [string] $Device = 'chrome',

  [string] $AdminProxyBaseUri = $env:FORGE_FLOW_ADMIN_PROXY_BASE_URI,

  # Legacy alias for -Mode demo -DemoFixtureLogin.
  [switch] $DemoMode,

  # When set, runs against a local web-server (port 8182) instead of a
  # browser device. Used by .claude/launch.json so Claude_Preview can
  # spin the console up headlessly.
  [switch] $WebServer,

  [int] $WebPort = 8182,

  [switch] $PrintCommandOnly,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Legacy alias: `-DemoMode` = demo + fixture-login picker.
if ($DemoMode) {
  $Mode = 'demo'
  $DemoFixtureLogin = $true
}

# Production guardrail: never run pointed at the live admin proxy
# without explicit acknowledgement. Mirrors the deploy-script doctrine.
if ($Mode -eq 'production' -and -not $IUnderstand) {
  Write-Host 'BLOCKED: -Mode production targets the live admin proxy (admin-proxy.forgeflow.app). Pass -IUnderstand to confirm.'
  exit 1
}

# Resolve the admin proxy base URI for non-demo modes.
function Resolve-AdminProxyBaseUri {
  param([string] $ResolveMode, [string] $ExplicitBaseUri, [string] $PreviewSlug)

  if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseUri)) {
    return $ExplicitBaseUri
  }
  switch ($ResolveMode) {
    'preview' {
      if ([string]::IsNullOrWhiteSpace($PreviewSlug)) {
        throw '-Mode preview requires either -PreviewName <slug> or -AdminProxyBaseUri https://...'
      }
      $service = "forge-flow-preview-$PreviewSlug-proxy"
      $gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
      if (-not (Test-Path -LiteralPath $gcloud)) { $gcloud = 'gcloud' }
      Write-Host "Resolving preview admin proxy URL for $service..."
      $url = & $gcloud run services describe $service `
        --project forge-flow-staging `
        --region northamerica-northeast2 `
        --format='value(status.url)' 2>$null
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($url)) {
        throw "gcloud could not resolve $service. Pass -AdminProxyBaseUri explicitly or deploy the preview stack first."
      }
      return $url.Trim()
    }
    'staging' {
      if (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_PROXY_BASE_URI)) {
        return $env:FORGE_FLOW_PROXY_BASE_URI
      }
      throw '-Mode staging requires -AdminProxyBaseUri or FORGE_FLOW_ADMIN_PROXY_BASE_URI (staging *.run.app URLs are not stable).'
    }
    'production' {
      return 'https://admin-proxy.forgeflow.app'
    }
    default {
      throw "Unsupported mode: $ResolveMode"
    }
  }
}

$argsList = @('run', '-t', 'lib/main_admin.dart')

if ($WebServer) {
  $argsList += @('-d', 'web-server', "--web-port=$WebPort", '--web-hostname=0.0.0.0')
} else {
  $argsList += @('-d', $Device)
}

if ($Mode -eq 'demo') {
  # Default demo auto-logs in as super-admin via
  # ADMIN_SHARE_PREVIEW=true + ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true so
  # there is NO login screen and the operator has full write access to
  # every admin surface for the walkthrough. The bare ADMIN_SHARE_PREVIEW
  # path (no SUPER_ADMIN flag) remains the historical "read-only support"
  # share-preview used by `scripts/deploy_admin_console.ps1 -SharePreview`
  # (emailed review links) - that deploy script is intentionally not
  # touched here.
  #
  # `-DemoFixtureLogin` swaps in ADMIN_DEMO_AUTH=true so the picker
  # (super.admin@ / support@ / operator@) renders instead - useful for
  # exercising the gate's admit / fail-closed paths.
  if ($DemoFixtureLogin) {
    $argsList += '--dart-define=ADMIN_DEMO_AUTH=true'
  } else {
    $argsList += '--dart-define=ADMIN_SHARE_PREVIEW=true'
    $argsList += '--dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true'
  }
} else {
  $resolved = Resolve-AdminProxyBaseUri `
    -ResolveMode $Mode `
    -ExplicitBaseUri $AdminProxyBaseUri `
    -PreviewSlug $PreviewName
  Write-Host "admin-console -> $Mode -> $resolved"
  $argsList += "--dart-define=ADMIN_PROXY_BASE_URI=$resolved"
}

if ($FlutterArgs.Count -gt 0) {
  $argsList += $FlutterArgs
}

# Both web consoles serve from the same `web/index.html`, whose production
# CSP refuses `'unsafe-inline'` / `'unsafe-eval'`. Flutter Web's DDC dev
# compiler needs both — without the swap, the bundle loads but every
# DDC-injected inline script is blocked and Flutter never paints (operator
# stays on splash forever). Shared helper applies the dev-relaxed CSP for
# the duration of `flutter run`, then restores the production file on exit
# (Ctrl-C, error, or normal completion). Same swap operator-web does.
. (Join-Path $PSScriptRoot '_dev_csp_swap.ps1')

if ($PrintCommandOnly) {
  Write-DevCspSwapNotice -RepoRoot $repoRoot
  Write-Host "flutter $($argsList -join ' ')"
  exit 0
}

Begin-DevCspSwap -RepoRoot $repoRoot
Push-Location $repoRoot
try {
  & flutter @argsList
  $flutterExitCode = $LASTEXITCODE
} finally {
  Pop-Location
  End-DevCspSwap -RepoRoot $repoRoot
}
exit $flutterExitCode
