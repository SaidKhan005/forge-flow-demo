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
#   scripts/run_operator_web_dev.ps1 -LiveAuth -ProxyBaseUri https://proxy.forgeflow.app
#   scripts/run_operator_web_dev.ps1 -PrintCommandOnly
#   scripts/run_operator_web_dev.ps1 -- --dart-define=OPERATOR_WEB_DEMO_SCENARIO=onboarding

param(
  # Named-only parameters. Positional args (anything not bound to a
  # named switch above) flow into `-FlutterArgs` via
  # `ValueFromRemainingArguments`, so a caller can pass
  # `scripts/run_operator_web_dev.ps1 --dart-define=FOO=bar` and the
  # extra arg is forwarded to `flutter run` cleanly.
  [Parameter()][string] $WebPort = '8181',

  [Parameter()][string] $WebHostname = '0.0.0.0',

  [Parameter()][string] $ProxyBaseUri = $env:FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI,

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

function Build-FlutterArgs {
  $argsList = @(
    'run',
    '-d', 'web-server',
    "--web-port=$WebPort",
    "--web-hostname=$WebHostname",
    '-t', 'lib/main_operator_web.dart'
  )

  if ($LiveAuth) {
    if ([string]::IsNullOrWhiteSpace($ProxyBaseUri)) {
      if (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_PROXY_BASE_URI)) {
        $script:ProxyBaseUri = $env:FORGE_FLOW_PROXY_BASE_URI
      }
    }
    if ([string]::IsNullOrWhiteSpace($script:ProxyBaseUri)) {
      Write-Host 'BLOCKED: -LiveAuth requires -ProxyBaseUri or FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI / FORGE_FLOW_PROXY_BASE_URI.'
      exit 1
    }
    $argsList += "--dart-define=OPERATOR_WEB_PROXY_BASE_URI=$script:ProxyBaseUri"
  } else {
    $argsList += '--dart-define=OPERATOR_WEB_DEMO_AUTH=true'
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
