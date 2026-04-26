# Run a Forge Flow Flutter flavor with local dev secrets loaded.
#
# Examples:
#   scripts/run_flutter_dev.ps1 -App forgeflow
#   scripts/run_flutter_dev.ps1 -App barrio -Device chrome
#   scripts/run_flutter_dev.ps1 -App forgeflow -PrintCommandOnly
#
# This is for local development only. Production provider keys stay server-side.

param(
  [ValidateSet('forgeflow', 'barrio')]
  [string] $App = 'forgeflow',

  [string] $Device,

  [switch] $NoProviderKeys,

  [switch] $PrintCommandOnly,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultSecretsFile = Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'
$secretsFile = [Environment]::GetEnvironmentVariable('FORGE_FLOW_SECRETS_FILE')
if ([string]::IsNullOrWhiteSpace($secretsFile)) {
  $secretsFile = $defaultSecretsFile
}

if (-not (Test-Path -LiteralPath $secretsFile)) {
  Write-Warning "Forge Flow secrets file missing: $secretsFile"
  Write-Host 'Create or restore the unified local secrets file, then retry.'
  exit 1
}

. $secretsFile

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
    Write-Warning 'ANTHROPIC_API_KEY is missing from the unified local secrets file.'
    Write-Host "Expected it in: $secretsFile"
    Write-Host 'Use -NoProviderKeys to run without the local Anthropic Settings check.'
    exit 1
  }

  $argsList += "--dart-define=ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
}

if ($FlutterArgs.Count -gt 0) {
  $argsList += $FlutterArgs
}

if ($PrintCommandOnly) {
  $sanitized = foreach ($arg in $argsList) {
    if ($arg.StartsWith('--dart-define=ANTHROPIC_API_KEY=')) {
      '--dart-define=ANTHROPIC_API_KEY=***'
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
