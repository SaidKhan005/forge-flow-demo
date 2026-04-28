# Deploy the Forge Flow staging advisor proxy to Cloud Run.
#
# The script loads values from the unified non-repo secrets file, verifies
# required env names by presence only, syncs required secret values into
# Secret Manager, deploys the service with Secret Manager env references, then
# stores the resulting proxy URI back into the non-repo secrets loader as
# FORGE_FLOW_PROXY_BASE_URI.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-staging-proxy',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'),
  [switch] $SkipApiEnable,
  [switch] $SkipSecretManagerSync
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

function Resolve-FirebaseWebApiKey {
  $current = [Environment]::GetEnvironmentVariable('FIREBASE_WEB_API_KEY')
  if (-not [string]::IsNullOrWhiteSpace($current)) {
    return
  }

  $googleServicesPath = Join-Path $repoRoot 'android\app\src\forgeflow\google-services.json'
  if (-not (Test-Path -LiteralPath $googleServicesPath)) {
    return
  }

  $googleServices = Get-Content -LiteralPath $googleServicesPath -Raw |
    ConvertFrom-Json
  foreach ($client in @($googleServices.client)) {
    foreach ($apiKey in @($client.api_key)) {
      $key = [string] $apiKey.current_key
      if (-not [string]::IsNullOrWhiteSpace($key)) {
        [Environment]::SetEnvironmentVariable('FIREBASE_WEB_API_KEY', $key, 'Process')
        return
      }
    }
  }
}

if (-not (Test-Path -LiteralPath $SecretsFile)) {
  Write-Host 'BLOCKED: missing required env names:'
  Write-Host ' - forge_flow.secrets.ps1'
  exit 1
}

. $SecretsFile
Resolve-FirebaseWebApiKey

$requiredEnv = @(
  'ANTHROPIC_API_KEY',
  'VOYAGE_API_KEY',
  'POSTGRES_URL',
  'POSTGRES_ADMIN_URL',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_WEB_API_KEY',
  'FIREBASE_AUTH_SMOKE_PASSWORD'
)
Assert-PresentEnv -Names $requiredEnv

$secretEnv = [ordered] @{
  'ANTHROPIC_API_KEY' = 'forge-flow-staging-anthropic-api-key'
  'VOYAGE_API_KEY' = 'forge-flow-staging-voyage-api-key'
  'POSTGRES_URL' = 'forge-flow-staging-postgres-url'
  'POSTGRES_ADMIN_URL' = 'forge-flow-staging-postgres-admin-url'
  'FIREBASE_WEB_API_KEY' = 'forge-flow-staging-firebase-web-api-key'
}

function Sync-SecretManagerSecret {
  param(
    [string] $SecretName,
    [string] $Value
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $gcloud secrets describe $SecretName `
      --project $Project `
      --quiet *> $null
    $describeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($describeExitCode -ne 0) {
    & $gcloud secrets create $SecretName `
      --project $Project `
      --replication-policy automatic `
      --quiet
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  $tempSecretFile = Join-Path ([System.IO.Path]::GetTempPath()) (
    "forge-flow-secret-{0}.txt" -f ([Guid]::NewGuid())
  )
  try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempSecretFile, $Value, $utf8NoBom)
    & $gcloud secrets versions add $SecretName `
      --project $Project `
      --data-file $tempSecretFile `
      --quiet
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally {
    if (Test-Path -LiteralPath $tempSecretFile) {
      Remove-Item -LiteralPath $tempSecretFile -Force
    }
  }

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $gcloud secrets add-iam-policy-binding $SecretName `
      --project $Project `
      --member "serviceAccount:$ServiceAccount" `
      --role roles/secretmanager.secretAccessor `
      --quiet *> $null
    $iamExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($iamExitCode -ne 0) { exit $iamExitCode }
}

if (-not $SkipApiEnable) {
  & $gcloud services enable `
    run.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    secretmanager.googleapis.com `
    --project $Project `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not $SkipSecretManagerSync) {
  foreach ($entry in $secretEnv.GetEnumerator()) {
    Sync-SecretManagerSecret `
      -SecretName $entry.Value `
      -Value ([Environment]::GetEnvironmentVariable($entry.Key))
  }
}

$secretAssignments = (
  $secretEnv.GetEnumerator() |
    ForEach-Object { "$($_.Key)=$($_.Value):latest" }
) -join ','
$envAssignments = "FIREBASE_PROJECT_ID=$env:FIREBASE_PROJECT_ID"

Push-Location $repoRoot
try {
  & $gcloud run deploy $Service `
    --project $Project `
    --region $Region `
    --source . `
    --service-account $ServiceAccount `
    --allow-unauthenticated `
    --no-invoker-iam-check `
    --set-env-vars $envAssignments `
    --set-secrets $secretAssignments `
    --min-instances 0 `
    --max-instances 2 `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
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
Write-Host ' - FIREBASE_WEB_API_KEY'
Write-Host ' - POSTGRES_URL'
Write-Host ' - POSTGRES_ADMIN_URL'
Write-Host ' - Cloud Run secret env refs backed by Secret Manager'
