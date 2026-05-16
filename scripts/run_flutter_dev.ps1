# Run a Forge Flow Flutter flavor with local dev secrets loaded.
#
# Mirrors the 4-mode shape used by `scripts/run_operator_web_dev.ps1` and
# `scripts/run_admin_console_dev.ps1`:
#
#   -Mode demo        Writer-side demo. No proxy. MockReplayDataSourceProvider
#                     seeds standard SQLite tables under DemoScope (HP #2).
#   -Mode preview     Per-branch Cloud Run preview. Resolves
#                     `forge-flow-preview-<slug>-proxy` URL via `gcloud run
#                     services describe` when `-PreviewName <slug>` is set,
#                     otherwise requires `-ProxyBaseUri`.
#   -Mode staging     Shared staging proxy. Requires `-ProxyBaseUri` or
#                     `$env:FORGE_FLOW_PROXY_BASE_URI` from the secrets file.
#   -Mode production  Production proxy at https://proxy.forgeflow.app. Hard
#                     blast-radius gate; `-IUnderstand` required or the script
#                     exits 1 before invoking `flutter`.
#
# Legacy back-compat: the pre-Mode invocation `run_flutter_dev.ps1 -App
# forgeflow -UseFirebaseAuth` (no -Mode) maps to `-Mode staging` so existing
# callers / docs keep working. Demo is the default `-Mode` when neither
# `-Mode` nor `-UseFirebaseAuth` is set.
#
# Demo mode emits `--dart-define=kDemoMode=true` AND
# `--dart-define=FORGE_FLOW_DEMO_MODE=true` because
# `lib/screens/auth/login_screen.dart` reads both names. Demo runs do NOT
# require `FORGE_FLOW_PROXY_BASE_URI` in the secrets file.
#
# Examples:
#   scripts/run_flutter_dev.ps1 -App forgeflow                                  # demo (default, no proxy)
#   scripts/run_flutter_dev.ps1 -App forgeflow -Mode preview -PreviewName ux-nav
#   scripts/run_flutter_dev.ps1 -App forgeflow -Mode staging -ProxyBaseUri https://forge-flow-staging-proxy-XXXX-nn.a.run.app
#   scripts/run_flutter_dev.ps1 -App forgeflow -Mode production -IUnderstand
#   scripts/run_flutter_dev.ps1 -App barrio    -Mode demo                       # paused; runs but warns
#   scripts/run_flutter_dev.ps1 -App forgeflow -UseFirebaseAuth                 # legacy -> staging
#   scripts/run_flutter_dev.ps1 -App forgeflow -PrintCommandOnly
#
# This is for local development only. Production provider keys stay server-side.

param(
  [ValidateSet('forgeflow', 'barrio')]
  [string] $App = 'forgeflow',

  [ValidateSet('demo', 'preview', 'staging', 'production')]
  [string] $Mode = 'demo',

  [string] $PreviewName,

  [switch] $IUnderstand,

  [string] $Device,

  [switch] $NoProviderKeys,

  [switch] $UseFirebaseAuth,

  [string] $ProxyBaseUri,

  [switch] $PrintCommandOnly,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultSecretsFile = Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'
$secretsFile = [Environment]::GetEnvironmentVariable('FORGE_FLOW_SECRETS_FILE')
if ([string]::IsNullOrWhiteSpace($secretsFile)) {
  $secretsFile = $defaultSecretsFile
}

# Legacy back-compat: pre-Mode callers do `-App forgeflow -UseFirebaseAuth`
# expecting it to hit the deployed proxy. Map that to staging when -Mode is
# still on its default. Mirror of run_operator_web_dev.ps1's -LiveAuth trick.
# Must run BEFORE the secrets-file gate so demo mode does not require a
# secrets file (HP #2: writer-side switch, no proxy needed).
$modeExplicit = $PSBoundParameters.ContainsKey('Mode')
if (-not $modeExplicit -and $UseFirebaseAuth) {
  $Mode = 'staging'
}

# Source the secrets file when present. Required for preview / staging /
# production (they need FORGE_FLOW_PROXY_BASE_URI and ANTHROPIC_API_KEY).
# Optional for demo mode: HP #2 writer-side switch needs no proxy + no
# provider keys to run a local walkthrough.
if (Test-Path -LiteralPath $secretsFile) {
  . $secretsFile
} elseif ($Mode -eq 'demo') {
  Write-Host "Note: secrets file missing at $secretsFile. -Mode demo does not require it; continuing."
} else {
  Write-Warning "Forge Flow secrets file missing: $secretsFile"
  Write-Host 'Create or restore the unified local secrets file, then retry, or pass -Mode demo for a no-secrets walkthrough.'
  exit 1
}

if ($App -eq 'barrio') {
  Write-Warning 'Barrio is paused (see CLAUDE.md "Paused" / memory/project_barrio_paused.md). Running anyway, but no merges should target Barrio runtime.'
}

if ([string]::IsNullOrWhiteSpace($ProxyBaseUri)) {
  $ProxyBaseUri = $env:FORGE_FLOW_PROXY_BASE_URI
}

function Resolve-FlutterProxyBaseUri {
  param([string] $TargetMode)

  switch ($TargetMode) {
    'demo' {
      # Demo mode does not use a proxy; the MockReplayDataSourceProvider
      # writes SQLite directly. Return empty so the caller skips emitting
      # `--dart-define=FORGE_FLOW_PROXY_BASE_URI=...`.
      return ''
    }
    'preview' {
      if (-not [string]::IsNullOrWhiteSpace($script:ProxyBaseUri)) {
        return $script:ProxyBaseUri
      }
      if ([string]::IsNullOrWhiteSpace($script:PreviewName)) {
        Write-Host 'BLOCKED: -Mode preview requires either -PreviewName <slug> (auto-resolves the Cloud Run preview proxy URL) or an explicit -ProxyBaseUri.'
        exit 1
      }
      $serviceName = "forge-flow-preview-$script:PreviewName-proxy"
      Write-Host "Resolving $serviceName URL via gcloud run services describe..."
      $resolved = & gcloud run services describe $serviceName `
        --project forge-flow-staging `
        --region northamerica-northeast2 `
        --format='value(status.url)' 2>$null
      if ([string]::IsNullOrWhiteSpace($resolved)) {
        Write-Host "BLOCKED: could not resolve Cloud Run URL for $serviceName. Pass -ProxyBaseUri or deploy the preview stack first (scripts/deploy_preview_stack.ps1)."
        exit 1
      }
      return $resolved.Trim()
    }
    'staging' {
      if ([string]::IsNullOrWhiteSpace($script:ProxyBaseUri)) {
        Write-Warning 'FORGE_FLOW_PROXY_BASE_URI is missing from the unified local secrets file.'
        Write-Host "Expected it in: $script:secretsFile"
        Write-Host 'Run scripts/deploy_staging_proxy.ps1, pass -ProxyBaseUri, or add the deployed proxy URI outside the repo.'
        exit 1
      }
      return $script:ProxyBaseUri
    }
    'production' {
      if (-not $script:IUnderstand) {
        Write-Host 'BLOCKED: -Mode production targets the live operator-facing proxy at https://proxy.forgeflow.app. Re-run with -IUnderstand to confirm you intend a production-pointing local dev session.'
        exit 1
      }
      if (-not [string]::IsNullOrWhiteSpace($script:ProxyBaseUri)) {
        return $script:ProxyBaseUri
      }
      return 'https://proxy.forgeflow.app'
    }
    default {
      Write-Host "BLOCKED: unknown -Mode '$TargetMode'."
      exit 1
    }
  }
}

$resolvedProxy = Resolve-FlutterProxyBaseUri -TargetMode $Mode

$target = if ($App -eq 'barrio') {
  'lib/main_barrio.dart'
} else {
  'lib/main_forgeflow.dart'
}

$argsList = @('run', '--flavor', $App, '-t', $target)

if (-not [string]::IsNullOrWhiteSpace($Device)) {
  $argsList += @('-d', $Device)
}

if (-not $NoProviderKeys) {
  if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
    if ($Mode -eq 'demo') {
      # Demo runs swap in MockReplayDataSourceProvider + mocked LLM providers
      # via kDemoMode; the live ANTHROPIC_API_KEY is not exercised. Silently
      # skip the dart-define so a no-secrets demo run is friction-free.
      Write-Host 'Note: ANTHROPIC_API_KEY is empty. -Mode demo does not require it; continuing without the dart-define.'
    } else {
      Write-Warning 'ANTHROPIC_API_KEY is missing from the unified local secrets file.'
      Write-Host "Expected it in: $secretsFile"
      Write-Host 'Use -NoProviderKeys to run without the local Anthropic Settings check, or -Mode demo for a no-secrets walkthrough.'
      exit 1
    }
  } else {
    $argsList += "--dart-define=ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
  }
}

if ($Mode -eq 'demo') {
  # HP #2: writer-side switch. Both flag names are read by
  # lib/screens/auth/login_screen.dart's _demoOperatorSignInEnabled
  # (`bool.fromEnvironment('kDemoMode') || bool.fromEnvironment('FORGE_FLOW_DEMO_MODE')`),
  # so demo mode emits both for forwards/backwards compatibility.
  $argsList += '--dart-define=kDemoMode=true'
  $argsList += '--dart-define=FORGE_FLOW_DEMO_MODE=true'
} else {
  # preview / staging / production all wire the live Firebase Auth path
  # to the resolved proxy URL.
  $argsList += '--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true'
  $argsList += "--dart-define=FORGE_FLOW_PROXY_BASE_URI=$resolvedProxy"
}

if ($FlutterArgs.Count -gt 0) {
  $argsList += $FlutterArgs
}

if ($PrintCommandOnly) {
  $sanitized = foreach ($arg in $argsList) {
    if ($arg.StartsWith('--dart-define=ANTHROPIC_API_KEY=')) {
      '--dart-define=ANTHROPIC_API_KEY=***'
    } elseif ($arg.StartsWith('--dart-define=FORGE_FLOW_PROXY_BASE_URI=')) {
      '--dart-define=FORGE_FLOW_PROXY_BASE_URI=***'
    } else {
      $arg
    }
  }
  Write-Host "flutter $($sanitized -join ' ')"
  exit 0
}

Push-Location $repoRoot
try {
  & flutter @argsList
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
