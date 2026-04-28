# Unified Forge Flow local secret loader (names only).
#
# Dot-source this script from the repo root:
#   . scripts/use_forge_flow_secrets.ps1
#
# It loads `$HOME\.forge_flow\forge_flow.secrets.ps1` by default, or the
# path in `FORGE_FLOW_SECRETS_FILE` when set. It never prints secret values.

$ErrorActionPreference = 'Stop'

$envFile = [Environment]::GetEnvironmentVariable('FORGE_FLOW_SECRETS_FILE')
if ([string]::IsNullOrWhiteSpace($envFile)) {
  $envFile = Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'
}

if (-not (Test-Path -LiteralPath $envFile)) {
  Write-Warning "Forge Flow secrets file missing: $envFile"
  Write-Host 'Create the local non-repo secrets file, then retry.'
  return
}

. $envFile

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('FIREBASE_WEB_API_KEY'))) {
  $googleServicesPath = Join-Path $repoRoot 'android\app\src\forgeflow\google-services.json'
  if (Test-Path -LiteralPath $googleServicesPath) {
    $googleServices = Get-Content -LiteralPath $googleServicesPath -Raw |
      ConvertFrom-Json
    foreach ($client in @($googleServices.client)) {
      foreach ($apiKey in @($client.api_key)) {
        $key = [string] $apiKey.current_key
        if (-not [string]::IsNullOrWhiteSpace($key)) {
          [Environment]::SetEnvironmentVariable('FIREBASE_WEB_API_KEY', $key, 'Process')
          break
        }
      }
      if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('FIREBASE_WEB_API_KEY'))) {
        break
      }
    }
  }
}

foreach ($name in @(
  'POSTGRES_URL',
  'POSTGRES_ADMIN_URL',
  'POSTGRES_PRODUCTION_ADMIN_URL',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_WEB_API_KEY',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'ANTHROPIC_API_KEY',
  'VOYAGE_API_KEY'
)) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    Write-Host "${name}: MISSING"
  } else {
    Write-Host "${name}: PRESENT (name only - value not inspected)"
  }
}
