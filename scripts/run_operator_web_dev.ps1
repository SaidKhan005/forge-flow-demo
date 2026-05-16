# B-FU-dev-csp / Phase 11W.0 — Run the Forge & Flow Operator Web
# Console (Flutter Web) locally for the Phase 2 walkthrough.
#
# Wraps the manual `flutter run -d web-server --web-port=8181 -t
# lib/main_operator_web.dart` invocation with the dev-CSP swap that
# the Flutter DDC dev bundle requires. The source `web/index.html`
# stays prod-strict on disk; this helper backs the file up, applies
# the dev-relaxed CSP for the duration of the run, and restores from
# backup on exit (Ctrl-C, error, or normal completion).
#
# The dev CSP added here matches the canonical block documented in
# `docs/_audits/wave_2/phase_2_walkthrough_master_plan.md` -> Patch 1
# (`'unsafe-inline' 'unsafe-eval'` + `ws://localhost:*` /
# `http://localhost:*` in `connect-src`, drops
# `upgrade-insecure-requests`).
#
# Idempotency: if a previous run was interrupted before restore,
# `web/index.html.prod.bak` will still be on disk. This script
# detects that and restores from backup before applying the dev CSP
# again, so the source tree never ends up with a stale dev CSP.
#
# Default = demo auth (`OPERATOR_WEB_DEMO_AUTH=true`), matching the
# walkthrough doctrine. Pass `-LiveAuth` to wire the live Firebase
# auth source instead (requires `-ProxyBaseUri` or
# `FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI` /
# `FORGE_FLOW_PROXY_BASE_URI` in the secrets file).
#
# Examples:
#   scripts/run_operator_web_dev.ps1
#   scripts/run_operator_web_dev.ps1 -WebPort 8182
#   scripts/run_operator_web_dev.ps1 -Device chrome
#   scripts/run_operator_web_dev.ps1 -LiveAuth -ProxyBaseUri https://proxy.forgeflow.app
#   scripts/run_operator_web_dev.ps1 -PrintCommandOnly
#   scripts/run_operator_web_dev.ps1 -- --dart-define=OPERATOR_WEB_DEMO_SCENARIO=onboarding

param(
  # Named-only parameters. Positional args (anything not bound to a
  # named switch above) flow into `-FlutterArgs` via
  # `ValueFromRemainingArguments`, so a caller can pass
  # `scripts/run_operator_web_dev.ps1 --dart-define=FOO=bar` and the
  # extra arg is forwarded to `flutter run` cleanly.

  # 4-mode runner contract. demo | preview | staging | production.
  # Defaults to `demo` so a forgotten flag does not silently point at
  # production. `-LiveAuth` (below) is retained as a legacy alias that
  # maps to whichever -Mode the caller picked; if both -LiveAuth and
  # -Mode demo are supplied the legacy alias wins (matches old
  # invocations).
  [Parameter()]
  [ValidateSet('demo', 'preview', 'staging', 'production')]
  [string] $Mode = 'demo',

  # Per-branch / per-PR preview slug. Required for -Mode preview unless
  # -ProxyBaseUri is supplied explicitly. The script resolves
  # `forge-flow-preview-<name>-proxy` via `gcloud run services describe`.
  [Parameter()][string] $PreviewName,

  # Operator-web demo scenario - drives initial auth state + fixture
  # seeding. Default `owner-location-completed` lands signed in and
  # post-onboarding so demo is genuinely no-login + no-onboarding.
  # Other valid tokens: owner-business, manager-once, mfa-enrolled,
  # mfa-pending-removal, signed-out-live, owner-location (welcome /
  # token-entry screen).
  [Parameter()][string] $DemoScenario = 'owner-location-completed',

  # Production safety - script refuses -Mode production without this.
  [Parameter()][switch] $IUnderstand,

  [Parameter()][string] $WebPort = '8181',

  [Parameter()][string] $WebHostname = '0.0.0.0',

  # Flutter target device. `web-server` (default) serves the bundle so
  # any browser / LAN device can attach on $WebHostname:$WebPort.
  # `chrome` launches Chrome directly with the Dart debugger attached
  # (hot reload, DevTools) — convenient for local dev. The dev-CSP swap
  # applies identically either way.
  [Parameter()]
  [ValidateSet('web-server', 'chrome')]
  [string] $Device = 'web-server',

  [Parameter()][string] $ProxyBaseUri = $env:FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI,

  # Legacy alias. Setting -LiveAuth forces -Mode staging when -Mode
  # would otherwise be `demo` (back-compat with pre-`-Mode` invocations
  # that did `-LiveAuth -ProxyBaseUri ...`).
  [Parameter()][switch] $LiveAuth,

  [Parameter()][switch] $PrintCommandOnly,

  [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$indexPath = Join-Path $repoRoot 'web\index.html'
$backupPath = Join-Path $repoRoot 'web\index.prod.html.bak'

if (-not (Test-Path -LiteralPath $indexPath)) {
  Write-Host "BLOCKED: web/index.html not found at $indexPath"
  exit 1
}

# Idempotency: if a prior interrupted run left a backup behind, the
# on-disk `web/index.html` may already carry the dev CSP. Restore
# from backup first so we always start the dev-CSP swap from a known
# production-CSP baseline.
function Restore-FromBackup {
  param([string] $Target, [string] $Backup)

  if (Test-Path -LiteralPath $Backup) {
    Copy-Item -LiteralPath $Backup -Destination $Target -Force
    Remove-Item -LiteralPath $Backup -Force
    Write-Host "B-FU-dev-csp: restored production CSP from $Backup"
  }
}

Restore-FromBackup -Target $indexPath -Backup $backupPath

# B-FU-dev-csp: the dev-relaxed CSP block. Kept in sync with
# `scripts/apply_operator_web_dev_csp.sh` (Docker side) + the
# canonical block in
# `docs/_audits/wave_2/phase_2_walkthrough_master_plan.md` Patch 1.
$devCspMeta = @'
<meta http-equiv="Content-Security-Policy" content="
    default-src 'self' 'unsafe-inline' 'unsafe-eval';
    script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://www.gstatic.com https://*.firebaseapp.com;
    style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
    img-src 'self' data: blob: https:;
    font-src 'self' data: https://fonts.gstatic.com;
    connect-src 'self' ws://localhost:* http://localhost:* https://www.gstatic.com https://fonts.gstatic.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net wss://*.firebaseio.com https://admin-proxy.forgeflow.app https://proxy.forgeflow.app https://*.forgeflow.app https://*.run.app;
    frame-src 'self' https://*.firebaseapp.com;
    object-src 'none';
    base-uri 'self';
    form-action 'self';
  ">
'@

function Apply-DevCsp {
  param([string] $Target)

  $html = Get-Content -LiteralPath $Target -Raw
  # Single-line regex with DOTALL so the `.*?` spans the multi-line
  # CSP block. Anchor on the opening `<meta http-equiv=...>` and the
  # closing `">` to avoid greedy matching downstream tags.
  $pattern = '(?s)<meta\s+http-equiv="Content-Security-Policy".*?">'
  $matches = [regex]::Matches($html, $pattern)
  if ($matches.Count -lt 1) {
    Write-Host 'BLOCKED: could not locate CSP <meta> tag in web/index.html'
    exit 1
  }
  $rewritten = [regex]::Replace(
    $html,
    $pattern,
    [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $script:_devCspReplacementCount = ($script:_devCspReplacementCount + 1)
      if ($script:_devCspReplacementCount -eq 1) { return $devCspMeta }
      return $m.Value
    },
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  Set-Content -LiteralPath $Target -Value $rewritten -Encoding UTF8 -NoNewline
  Write-Host "B-FU-dev-csp: applied dev CSP to $Target"
}

# Resolve the proxy URL for non-demo modes. Returns $null for demo
# (caller forces demo-auth + no proxy in that branch). Throws on any
# misconfiguration so the caller never silently lands on the wrong
# backend.
function Resolve-OperatorWebProxyBaseUri {
  param([string] $ResolveMode, [string] $ExplicitBaseUri, [string] $PreviewSlug)

  if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseUri)) {
    return $ExplicitBaseUri
  }
  switch ($ResolveMode) {
    'preview' {
      if ([string]::IsNullOrWhiteSpace($PreviewSlug)) {
        throw '-Mode preview requires either -PreviewName <slug> or -ProxyBaseUri https://...'
      }
      $service = "forge-flow-preview-$PreviewSlug-proxy"
      $gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
      if (-not (Test-Path -LiteralPath $gcloud)) { $gcloud = 'gcloud' }
      Write-Host "Resolving preview proxy URL for $service..."
      $url = & $gcloud run services describe $service `
        --project forge-flow-staging `
        --region northamerica-northeast2 `
        --format='value(status.url)' 2>$null
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($url)) {
        throw "gcloud could not resolve $service. Pass -ProxyBaseUri explicitly or deploy the preview stack first."
      }
      return $url.Trim()
    }
    'staging' {
      if (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_STAGING_PROXY_BASE_URI)) {
        return $env:FORGE_FLOW_STAGING_PROXY_BASE_URI
      }
      throw '-Mode staging requires -ProxyBaseUri or FORGE_FLOW_STAGING_PROXY_BASE_URI (staging *.run.app URLs are not stable across deploys).'
    }
    'production' {
      return 'https://proxy.forgeflow.app'
    }
    default {
      throw "Unsupported mode: $ResolveMode"
    }
  }
}

function Build-FlutterArgs {
  # Legacy alias: pre-`-Mode` callers used `-LiveAuth -ProxyBaseUri ...`
  # to mean "point at staging". Honor that when -Mode wasn't bumped off
  # its default.
  if ($LiveAuth -and $Mode -eq 'demo') {
    $script:Mode = 'staging'
  }

  # Production guardrail: never run pointed at the live proxy without
  # explicit acknowledgement. Mirrors the deploy-script doctrine.
  if ($Mode -eq 'production' -and -not $IUnderstand) {
    Write-Host 'BLOCKED: -Mode production targets the live operator-web proxy (proxy.forgeflow.app). Pass -IUnderstand to confirm.'
    exit 1
  }

  # `0.0.0.0` is right for web-server (LAN/device testing), but Chrome
  # must be pointed at a concrete loopback host or it fails to attach.
  $effectiveWebHostname = $WebHostname
  if ($Device -eq 'chrome' -and $WebHostname -eq '0.0.0.0') {
    $effectiveWebHostname = 'localhost'
  }

  $argsList = @(
    'run',
    '-d', $Device,
    "--web-port=$WebPort",
    "--web-hostname=$effectiveWebHostname",
    '-t', 'lib/main_operator_web.dart'
  )

  if ($Mode -eq 'demo') {
    $argsList += '--dart-define=OPERATOR_WEB_DEMO_AUTH=true'
    if (-not [string]::IsNullOrWhiteSpace($DemoScenario)) {
      $argsList += "--dart-define=OPERATOR_WEB_DEMO_SCENARIO=$DemoScenario"
    }
  } else {
    $resolved = Resolve-OperatorWebProxyBaseUri `
      -ResolveMode $Mode `
      -ExplicitBaseUri $ProxyBaseUri `
      -PreviewSlug $PreviewName
    Write-Host "operator-web -> $Mode -> $resolved"
    $argsList += "--dart-define=OPERATOR_WEB_PROXY_BASE_URI=$resolved"
  }

  if ($FlutterArgs.Count -gt 0) {
    $argsList += $FlutterArgs
  }

  return $argsList
}

$flutterArgsList = Build-FlutterArgs

if ($PrintCommandOnly) {
  Write-Host 'B-FU-dev-csp: dev CSP would be applied to web/index.html (backup at web/index.prod.html.bak) before:'
  Write-Host "flutter $($flutterArgsList -join ' ')"
  Write-Host 'B-FU-dev-csp: production CSP would be restored from backup on exit.'
  exit 0
}

# Take a backup of the production CSP file, then apply the dev CSP.
# The `try / finally` block guarantees restoration on Ctrl-C, error,
# or normal exit.
Copy-Item -LiteralPath $indexPath -Destination $backupPath -Force
Write-Host "B-FU-dev-csp: backed up production index.html to $backupPath"

# Best-effort: also catch Ctrl-C signals (PowerShell's normal
# behaviour fires the `finally` block, but `Stop-Process` from outside
# would still leave the file dirty; the idempotent restore at script
# entry above handles that case).
try {
  Apply-DevCsp -Target $indexPath
  Push-Location $repoRoot
  try {
    & flutter @flutterArgsList
    $flutterExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  exit $flutterExitCode
} finally {
  Restore-FromBackup -Target $indexPath -Backup $backupPath
}
