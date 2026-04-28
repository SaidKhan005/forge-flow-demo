# Deploy the Forge Flow staging advisor proxy to Cloud Run.
#
# The script loads values from the unified non-repo secrets file, verifies
# required env names by presence only, writes a temporary env file for gcloud,
# deploys the service, then stores the resulting proxy URI back into the
# non-repo secrets loader as FORGE_FLOW_PROXY_BASE_URI.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-staging-proxy',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'),
  [switch] $SkipApiEnable
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
if (-not (Test-Path -LiteralPath $gcloud)) {
  $gcloud = 'gcloud'
}

function Assert-PresentEnv {
  param([string[]] $Names)

  $missing = @()
  foreach ($name in $Names) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
      $missing += $name
    }
  }

  if ($missing.Count -gt 0) {
    Write-Host 'BLOCKED: missing required env names:'
    foreach ($name in $missing) {
      Write-Host " - $name"
    }
    exit 1
  }
}

function ConvertTo-SingleQuotedYamlValue {
  param([string] $Value)
  return "'$($Value.Replace("'", "''"))'"
}

if (-not (Test-Path -LiteralPath $SecretsFile)) {
  Write-Host 'BLOCKED: missing required env names:'
  Write-Host ' - forge_flow.secrets.ps1'
  exit 1
}

. $SecretsFile

$requiredEnv = @(
  'ANTHROPIC_API_KEY',
  'VOYAGE_API_KEY',
  'POSTGRES_URL',
  'POSTGRES_ADMIN_URL',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_AUTH_SMOKE_PASSWORD'
)
Assert-PresentEnv -Names $requiredEnv

if (-not $SkipApiEnable) {
  & $gcloud services enable `
    run.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    --project $Project `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$tempEnvFile = Join-Path ([System.IO.Path]::GetTempPath()) ("forge-flow-cloud-run-env-{0}.yaml" -f ([Guid]::NewGuid()))
try {
  $envYaml = @(
    "ANTHROPIC_API_KEY: $(ConvertTo-SingleQuotedYamlValue $env:ANTHROPIC_API_KEY)",
    "VOYAGE_API_KEY: $(ConvertTo-SingleQuotedYamlValue $env:VOYAGE_API_KEY)",
    "POSTGRES_URL: $(ConvertTo-SingleQuotedYamlValue $env:POSTGRES_URL)",
    "POSTGRES_ADMIN_URL: $(ConvertTo-SingleQuotedYamlValue $env:POSTGRES_ADMIN_URL)",
    "FIREBASE_PROJECT_ID: $(ConvertTo-SingleQuotedYamlValue $env:FIREBASE_PROJECT_ID)"
  )
  [System.IO.File]::WriteAllLines($tempEnvFile, $envYaml)

  Push-Location $repoRoot
  try {
    & $gcloud run deploy $Service `
      --project $Project `
      --region $Region `
      --source . `
      --service-account $ServiceAccount `
      --allow-unauthenticated `
      --no-invoker-iam-check `
      --env-vars-file $tempEnvFile `
      --min-instances 0 `
      --max-instances 2 `
      --quiet
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally {
    Pop-Location
  }
} finally {
  if (Test-Path -LiteralPath $tempEnvFile) {
    Remove-Item -LiteralPath $tempEnvFile -Force
  }
}

$proxyUri = & $gcloud run services describe $Service `
  --project $Project `
  --region $Region `
  --format 'value(status.url)'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ([string]::IsNullOrWhiteSpace($proxyUri)) {
  Write-Host 'BLOCKED: missing required env names:'
  Write-Host ' - deployed staging proxy URL'
  exit 1
}

$secretsText = [System.IO.File]::ReadAllText($SecretsFile)
$assignmentPattern = '(?m)^\s*\$env:FORGE_FLOW_PROXY_BASE_URI\s*=.*$'
$assignment = "`$env:FORGE_FLOW_PROXY_BASE_URI = '$($proxyUri.Replace("'", "''"))'"
if ([regex]::IsMatch($secretsText, $assignmentPattern)) {
  $secretsText = [regex]::Replace($secretsText, $assignmentPattern, $assignment)
} else {
  if (-not $secretsText.EndsWith("`n")) {
    $secretsText += "`r`n"
  }
  $secretsText += "`r`n# Cloud Run staging proxy base URI for Firebase-auth app smoke.`r`n$assignment`r`n"
}
[System.IO.File]::WriteAllText($SecretsFile, $secretsText)

Write-Host 'Deployment complete. Name-only prerequisites available:'
Write-Host ' - deployed staging proxy URL'
Write-Host ' - FORGE_FLOW_PROXY_BASE_URI'
Write-Host ' - FIREBASE_PROJECT_ID'
Write-Host ' - POSTGRES_URL'
Write-Host ' - POSTGRES_ADMIN_URL'
