# Deploy the Forge Flow advisor proxy to Cloud Run.
#
# The script loads values from the unified non-repo secrets file, verifies
# required env names by presence only, syncs required secret values into
# Secret Manager, deploys the service with Secret Manager env references, then
# stores the resulting proxy URI back into the non-repo secrets loader under
# the env var named by -ProxyBaseUriEnvVarName (default FORGE_FLOW_PROXY_BASE_URI).
#
# Multi-environment posture (matches scripts/deploy_audit_anchor_job.ps1):
#   * Defaults target staging. Override -Project / -Region / -Service /
#     -ServiceAccount / -SecretPrefix / -ProxyBaseUriEnvVarName /
#     -FirebaseGoogleServicesPath / -VpcConnector for production1 or any
#     other environment.
#   * -SecretPrefix MUST end with '-'. Convention: 'forge-flow-<env>-'.
#   * Secret name suffixes are stable; the prefix toggles per environment.
#   * Each non-staging environment requires its own pre-provisioned
#     Secret Manager namespace and (if the proxy reads FIREBASE_WEB_API_KEY
#     from a per-flavor google-services.json) its own
#     -FirebaseGoogleServicesPath override.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-staging-proxy',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  # Secret Manager name prefix. Convention: 'forge-flow-<env>-'. Trailing
  # '-' is required. Defaults to staging so existing call sites keep
  # working; override to 'forge-flow-production-' for production1.
  [string] $SecretPrefix = 'forge-flow-staging-',
  # Env var name written back into the secrets file with the deployed
  # proxy URL. Defaults to the staging variable; production deploys
  # should use a distinct name (e.g. 'FORGE_FLOW_PROXY_BASE_URI_PROD1').
  [string] $ProxyBaseUriEnvVarName = 'FORGE_FLOW_PROXY_BASE_URI',
  # Optional source env-var names to copy into the generic runtime names after
  # the secrets file is sourced. Production deploys should pass
  # POSTGRES_PRODUCTION_URL / POSTGRES_PRODUCTION_ADMIN_URL here so a staging
  # canonical loader cannot accidentally seed production Secret Manager with
  # staging DSNs.
  [string] $PostgresUrlEnvVarName = '',
  [string] $PostgresAdminUrlEnvVarName = '',
  [string] $FirebaseProjectId = '',
  # Path to the Firebase google-services.json this deploy should pull
  # FIREBASE_WEB_API_KEY from when the env var isn't already set.
  # Empty (default) resolves to the staging flutter flavor at
  # 'android\app\src\forgeflow\google-services.json'. Production deploys
  # should pass the matching per-flavor file (e.g. 'forgeflowProd1').
  [string] $FirebaseGoogleServicesPath = '',
  # Declared proxy environment. Staging must pass this explicitly so
  # HARD-C admin CORS startup checks do not treat an unset value as
  # production-equivalent.
  [string] $ProxyEnvironment = 'staging',
  # Optional comma-separated admin origins. Values may include entries
  # that end in :* (for example http://127.0.0.1:*) because the proxy
  # matcher supports exact origins plus dev/staging port wildcards.
  [string] $AdminCorsAllowedOrigins = $env:ADMIN_CORS_ALLOWED_ORIGINS,
  # Optional static-egress connector for Cloud Run. Required on first deploy
  # for any environment that reaches Azure Postgres through the firewall
  # allowlist. Leave empty only when the service already has the correct
  # connector or the target environment deliberately has no Azure dependency.
  [string] $VpcConnector = '',
  [string] $VpcEgress = 'all-traffic',
  [int] $MinInstances = 1,
  [int] $MaxInstances = 2,
  [switch] $DeferStartupDatabase,
  [switch] $SkipApiEnable,
  [switch] $SkipSecretManagerSync
)

if (-not $SecretPrefix.EndsWith('-')) {
  Write-Host "BLOCKED: -SecretPrefix '$SecretPrefix' must end with '-'."
  exit 1
}
if (
  -not [string]::IsNullOrWhiteSpace($VpcConnector) -and
  [string]::IsNullOrWhiteSpace($VpcEgress)
) {
  Write-Host 'BLOCKED: -VpcEgress is required when -VpcConnector is set.'
  exit 1
}
if ($MaxInstances -lt 1) {
  Write-Host 'BLOCKED: -MaxInstances must be at least 1.'
  exit 1
}
$normalizedProxyEnvironment = $ProxyEnvironment.Trim().ToLowerInvariant()
if ($DeferStartupDatabase -and $normalizedProxyEnvironment -eq 'prod') {
  Write-Host 'BLOCKED: -DeferStartupDatabase is not allowed with -ProxyEnvironment prod.'
  exit 1
}

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

function Assert-ServiceAccountProject {
  param(
    [string] $DeployProject,
    [string] $DeployServiceAccount
  )

  if (
    $DeployServiceAccount -match '@(?<serviceAccountProject>[^.]+)\.iam\.gserviceaccount\.com$' -and
    $Matches.serviceAccountProject -ne $DeployProject
  ) {
    Write-Host 'BLOCKED: Cloud Run service account project does not match deploy project.'
    Write-Host " - deploy project: $DeployProject"
    Write-Host " - service account: $DeployServiceAccount"
    exit 1
  }
}

Assert-ServiceAccountProject `
  -DeployProject $Project `
  -DeployServiceAccount $ServiceAccount

function Resolve-FirebaseWebApiKey {
  $current = [Environment]::GetEnvironmentVariable('FIREBASE_WEB_API_KEY')
  if (
    -not [string]::IsNullOrWhiteSpace($current) -and
    [string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)
  ) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)) {
    $googleServicesPath = Join-Path $repoRoot 'android\app\src\forgeflow\google-services.json'
  } else {
    $googleServicesPath = $FirebaseGoogleServicesPath
  }
  if (-not [System.IO.Path]::IsPathRooted($googleServicesPath)) {
    $googleServicesPath = Join-Path $repoRoot $googleServicesPath
  }
  if (-not (Test-Path -LiteralPath $googleServicesPath)) {
    if (-not [string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)) {
      Write-Host "BLOCKED: Firebase google-services config not found: $googleServicesPath"
      exit 1
    }
    return
  }

  $googleServices = Get-Content -LiteralPath $googleServicesPath -Raw |
    ConvertFrom-Json
  $googleServicesProject = [string] $googleServices.project_info.project_id
  if (
    -not [string]::IsNullOrWhiteSpace($googleServicesProject) -and
    $googleServicesProject -ne $Project
  ) {
    Write-Host 'BLOCKED: Firebase google-services project_id does not match deploy project.'
    Write-Host " - deploy project: $Project"
    Write-Host " - google-services project_id: $googleServicesProject"
    Write-Host " - config path: $googleServicesPath"
    exit 1
  }
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
if (-not [string]::IsNullOrWhiteSpace($FirebaseProjectId)) {
  [Environment]::SetEnvironmentVariable('FIREBASE_PROJECT_ID', $FirebaseProjectId, 'Process')
} elseif ([string]::IsNullOrWhiteSpace($env:FIREBASE_PROJECT_ID)) {
  [Environment]::SetEnvironmentVariable('FIREBASE_PROJECT_ID', $Project, 'Process')
}
if ($env:FIREBASE_PROJECT_ID -ne $Project) {
  Write-Host 'BLOCKED: FIREBASE_PROJECT_ID does not match deploy project.'
  Write-Host " - deploy project: $Project"
  Write-Host " - FIREBASE_PROJECT_ID: $env:FIREBASE_PROJECT_ID"
  Write-Host 'Pass -FirebaseProjectId for production deploys when the shared secrets loader defaults to another environment.'
  exit 1
}
if (-not [string]::IsNullOrWhiteSpace($PostgresUrlEnvVarName)) {
  $postgresUrlValue = [Environment]::GetEnvironmentVariable($PostgresUrlEnvVarName)
  if ([string]::IsNullOrWhiteSpace($postgresUrlValue)) {
    Write-Host 'BLOCKED: missing required env names:'
    Write-Host " - $PostgresUrlEnvVarName"
    exit 1
  }
  [Environment]::SetEnvironmentVariable('POSTGRES_URL', $postgresUrlValue, 'Process')
}
if (-not [string]::IsNullOrWhiteSpace($PostgresAdminUrlEnvVarName)) {
  $postgresAdminUrlValue = [Environment]::GetEnvironmentVariable($PostgresAdminUrlEnvVarName)
  if ([string]::IsNullOrWhiteSpace($postgresAdminUrlValue)) {
    Write-Host 'BLOCKED: missing required env names:'
    Write-Host " - $PostgresAdminUrlEnvVarName"
    exit 1
  }
  [Environment]::SetEnvironmentVariable('POSTGRES_ADMIN_URL', $postgresAdminUrlValue, 'Process')
}
if (
  -not $PSBoundParameters.ContainsKey('AdminCorsAllowedOrigins') -and
  -not [string]::IsNullOrWhiteSpace($env:ADMIN_CORS_ALLOWED_ORIGINS)
) {
  $AdminCorsAllowedOrigins = $env:ADMIN_CORS_ALLOWED_ORIGINS
}
if (-not $SkipSecretManagerSync) {
  Resolve-FirebaseWebApiKey
}

$requiredEnv = @(
  'FIREBASE_PROJECT_ID'
)
if (-not $SkipSecretManagerSync) {
  $requiredEnv += @(
    'ANTHROPIC_API_KEY',
    'VOYAGE_API_KEY',
    'POSTGRES_URL',
    'POSTGRES_ADMIN_URL',
    'FIREBASE_WEB_API_KEY',
    'SERVICE_PRINCIPAL_JWT_SECRET',
    'FIREBASE_AUTH_SMOKE_PASSWORD',
    # PR #260 (8.framework.proxy-config-vendor-app-credentials) added
    # PGCRYPTO_ENVELOPE_KEY to ProxySecretNames.required. The proxy
    # refuses to boot when this name is missing, so the deploy must
    # source it from Secret Manager alongside the other required
    # secrets above.
    'PGCRYPTO_ENVELOPE_KEY',
    # 8.framework.typed-app-credentials-humanity-qbt-7shifts-libro-publicbaseuri
    # added PUBLIC_BASE_URI to ProxySecretNames.required. Mirrors the
    # webhook host the per-tenant location config resolver presents
    # to vendors; the proxy boot fails closed when this name is
    # missing.
    'PUBLIC_BASE_URI'
  )
}
Assert-PresentEnv -Names $requiredEnv

# Secret name suffixes are stable across environments. The prefix
# toggles per env via -SecretPrefix. Convention mirrors
# scripts/deploy_audit_anchor_job.ps1 (lines 112-122) so a single
# rotation can sync proxy + job secrets under the same env namespace.
$secretSuffix = [ordered] @{
  'ANTHROPIC_API_KEY'             = 'anthropic-api-key'
  'VOYAGE_API_KEY'                = 'voyage-api-key'
  'POSTGRES_URL'                  = 'postgres-url'
  'POSTGRES_ADMIN_URL'            = 'postgres-admin-url'
  'FIREBASE_WEB_API_KEY'          = 'firebase-web-api-key'
  'SERVICE_PRINCIPAL_JWT_SECRET'  = 'service-principal-jwt-secret'
  # Phase 8 framework — pgcrypto symmetric envelope key required by
  # ProxySecretNames.required (PR #260). The proxy fails closed at
  # boot without it.
  'PGCRYPTO_ENVELOPE_KEY'         = 'pgcrypto-envelope-key'
  # Phase 8 framework — public base URI required by
  # ProxySecretNames.required (typed-app-credentials amendment). The
  # binder consumes this through ProxyConfig.publicBaseUri to build
  # the per-tenant location config resolver. Per-environment value:
  # staging deploys point at the staging URL; production points at
  # the canonical production URL. The proxy fails closed at boot
  # without it.
  'PUBLIC_BASE_URI'               = 'public-base-uri'
}
$secretEnv = [ordered] @{}
foreach ($entry in $secretSuffix.GetEnumerator()) {
  $secretEnv[$entry.Key] = "$SecretPrefix$($entry.Value)"
}

# Phase 8 framework — optional vendor app-credential secrets. Each
# entry is wired into Cloud Run --set-secrets ONLY when the matching
# env var is present in the local secrets file. Absent entries are
# skipped so the proxy boots in environments where a given vendor
# isn't yet configured. The connector binders gate their own
# activation on `ProxyConfig.has<Vendor>AppCredentials`.
$optionalSecretSuffix = [ordered] @{
  # Aloha NCR Voyix OAuth client_credentials bundle (4 secrets).
  'ALOHA_NCR_VOYIX_CLIENT_ID'        = 'aloha-ncr-voyix-client-id'
  'ALOHA_NCR_VOYIX_CLIENT_SECRET'    = 'aloha-ncr-voyix-client-secret'
  'ALOHA_NCR_VOYIX_APPLICATION_KEY'  = 'aloha-ncr-voyix-application-key'
  'ALOHA_NCR_VOYIX_ORGANIZATION_ID'  = 'aloha-ncr-voyix-organization-id'
  # Square OAuth + webhook host bundle (3 secrets).
  'SQUARE_CLIENT_ID'                 = 'square-client-id'
  'SQUARE_CLIENT_SECRET'             = 'square-client-secret'
  'SQUARE_NOTIFICATION_URL_HOST'     = 'square-notification-url-host'
  # Clover app-level credentials bundle (2 secrets).
  'CLOVER_APP_TOKEN'                 = 'clover-app-token'
  'CLOVER_APP_ID'                    = 'clover-app-id'
  # 8.framework.typed-app-credentials-humanity-qbt-7shifts-libro-publicbaseuri:
  # Humanity OAuth bundle (2 secrets).
  'HUMANITY_CLIENT_ID'               = 'humanity-client-id'
  'HUMANITY_CLIENT_SECRET'           = 'humanity-client-secret'
  # QuickBooks Time (Intuit) OAuth bundle (2 secrets).
  'QUICKBOOKS_TIME_CLIENT_ID'        = 'quickbooks-time-client-id'
  'QUICKBOOKS_TIME_CLIENT_SECRET'    = 'quickbooks-time-client-secret'
  # 7shifts OAuth bundle (2 secrets).
  'SEVEN_SHIFTS_CLIENT_ID'           = 'seven-shifts-client-id'
  'SEVEN_SHIFTS_CLIENT_SECRET'       = 'seven-shifts-client-secret'
  # Libro OAuth bundle (2 secrets).
  'LIBRO_CLIENT_ID'                  = 'libro-client-id'
  'LIBRO_CLIENT_SECRET'              = 'libro-client-secret'
}
# Build the optional secret env map only for entries that actually
# have a local value. Missing entries do not fail the deploy — they
# simply do not show up in --set-secrets, and ProxySecretNames.optional
# handles their absence at boot.
$optionalSecretEnv = [ordered] @{}
$optionalSecretSkipped = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $optionalSecretSuffix.GetEnumerator()) {
  $value = [Environment]::GetEnvironmentVariable($entry.Key)
  if ([string]::IsNullOrWhiteSpace($value)) {
    $optionalSecretSkipped.Add($entry.Key)
    continue
  }
  $optionalSecretEnv[$entry.Key] = "$SecretPrefix$($entry.Value)"
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
  foreach ($entry in $optionalSecretEnv.GetEnumerator()) {
    Sync-SecretManagerSecret `
      -SecretName $entry.Value `
      -Value ([Environment]::GetEnvironmentVariable($entry.Key))
  }
}

# Required secrets always show up in --set-secrets. Optional vendor
# secrets only show up when the matching env var was present locally;
# missing entries do not fail the deploy so the proxy can still boot
# in environments that have not configured a given vendor yet.
$combinedSecretEnv = [ordered] @{}
foreach ($entry in $secretEnv.GetEnumerator()) {
  $combinedSecretEnv[$entry.Key] = $entry.Value
}
foreach ($entry in $optionalSecretEnv.GetEnumerator()) {
  $combinedSecretEnv[$entry.Key] = $entry.Value
}
$secretAssignments = (
  $combinedSecretEnv.GetEnumerator() |
    ForEach-Object { "$($_.Key)=$($_.Value):latest" }
) -join ','

function Join-AdminCorsAllowedOrigins {
  param(
    [string] $ConfiguredOrigins,
    [string[]] $RequiredOrigins
  )

  $origins = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
  )
  foreach ($entry in (($ConfiguredOrigins -split ',') + $RequiredOrigins)) {
    $origin = ([string] $entry).Trim()
    if ([string]::IsNullOrWhiteSpace($origin)) { continue }
    if ($seen.Add($origin)) {
      $origins.Add($origin)
    }
  }
  return ($origins -join ',')
}

$firebaseActionCorsOrigins = @(
  "https://$Project.firebaseapp.com",
  "https://$Project.web.app"
)
$effectiveAdminCorsAllowedOrigins = Join-AdminCorsAllowedOrigins `
  -ConfiguredOrigins $AdminCorsAllowedOrigins `
  -RequiredOrigins $firebaseActionCorsOrigins

$envAssignments = [ordered] @{
  'FIREBASE_PROJECT_ID' = $env:FIREBASE_PROJECT_ID
  'PROXY_ENVIRONMENT' = $ProxyEnvironment
  'GCP_PROJECT_ID' = $Project
  'CLOUD_RUN_REGION' = $Region
  'CLOUD_RUN_SERVICE_NAME' = $Service
}
if (-not [string]::IsNullOrWhiteSpace($effectiveAdminCorsAllowedOrigins)) {
  $envAssignments['ADMIN_CORS_ALLOWED_ORIGINS'] =
    $effectiveAdminCorsAllowedOrigins
}
if ($DeferStartupDatabase) {
  $envAssignments['PROXY_DEFER_STARTUP_DATABASE'] = 'true'
}

function ConvertTo-YamlSingleQuotedValue {
  param([string] $Value)

  return "'" + ($Value -replace "'", "''") + "'"
}

$envVarsFile = Join-Path ([System.IO.Path]::GetTempPath()) (
  "forge-flow-proxy-env-{0}.yaml" -f ([Guid]::NewGuid())
)
$envVarsContent = (
  $envAssignments.GetEnumerator() |
    ForEach-Object {
      "$($_.Key): $(ConvertTo-YamlSingleQuotedValue ([string] $_.Value))"
    }
) -join "`n"

$deployArgs = @(
  'run', 'deploy', $Service,
  '--project', $Project,
  '--region', $Region,
  '--source', '.',
  '--service-account', $ServiceAccount,
  '--allow-unauthenticated',
  '--no-invoker-iam-check',
  '--env-vars-file', $envVarsFile,
  '--set-secrets', $secretAssignments,
  '--min-instances', $MinInstances,
  '--max-instances', $MaxInstances
)
if (-not [string]::IsNullOrWhiteSpace($VpcConnector)) {
  $deployArgs += @(
    '--vpc-connector', $VpcConnector,
    '--vpc-egress', $VpcEgress
  )
}
$deployArgs += '--quiet'

Push-Location $repoRoot
try {
  [System.IO.File]::WriteAllText($envVarsFile, $envVarsContent)
  & $gcloud @deployArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $gcloud run services update-traffic $Service `
    --project $Project `
    --region $Region `
    --to-latest `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  if (Test-Path -LiteralPath $envVarsFile) {
    Remove-Item -LiteralPath $envVarsFile -Force
  }
  Pop-Location
}

$proxyUri = & $gcloud run services describe $Service `
  --project $Project `
  --region $Region `
  --format 'value(status.url)'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ([string]::IsNullOrWhiteSpace($proxyUri)) {
  Write-Host 'BLOCKED: missing required env names:'
  Write-Host " - deployed proxy URL ($Service)"
  exit 1
}

$secretsText = [System.IO.File]::ReadAllText($SecretsFile)
$assignmentPattern = "(?m)^\s*\`$env:$([regex]::Escape($ProxyBaseUriEnvVarName))\s*=.*`$"
$assignment = "`$env:$ProxyBaseUriEnvVarName = '$($proxyUri.Replace("'", "''"))'"
if ([regex]::IsMatch($secretsText, $assignmentPattern)) {
  $secretsText = [regex]::Replace($secretsText, $assignmentPattern, $assignment)
} else {
  if (-not $secretsText.EndsWith("`n")) {
    $secretsText += "`r`n"
  }
  $secretsText += "`r`n# Cloud Run proxy base URI ($Project / $Service) for Firebase-auth app smoke.`r`n$assignment`r`n"
}
[System.IO.File]::WriteAllText($SecretsFile, $secretsText)

Write-Host 'Deployment complete. Name-only prerequisites available:'
Write-Host " - deployed proxy URL ($Service)"
Write-Host " - $ProxyBaseUriEnvVarName"
Write-Host ' - FIREBASE_PROJECT_ID'
Write-Host ' - FIREBASE_WEB_API_KEY'
Write-Host ' - SERVICE_PRINCIPAL_JWT_SECRET'
Write-Host ' - POSTGRES_URL'
Write-Host ' - POSTGRES_ADMIN_URL'
Write-Host ' - PGCRYPTO_ENVELOPE_KEY'
Write-Host ' - PUBLIC_BASE_URI'
Write-Host ' - ADMIN_CORS_ALLOWED_ORIGINS includes Firebase auth action hosts'
Write-Host ' - Cloud Run secret env refs backed by Secret Manager'
Write-Host " - Cloud Run min/max instances: $MinInstances/$MaxInstances"
if ($DeferStartupDatabase) {
  Write-Host ' - PROXY_DEFER_STARTUP_DATABASE=true (startup DB checks and background consumers deferred)'
}
if ($optionalSecretEnv.Count -gt 0) {
  Write-Host ' - Optional vendor app credentials wired:'
  foreach ($entry in $optionalSecretEnv.GetEnumerator()) {
    Write-Host "    - $($entry.Key)"
  }
}
if ($optionalSecretSkipped.Count -gt 0) {
  Write-Host ' - Optional vendor app credentials skipped (env not set; connector binders fail their own activation):'
  foreach ($name in $optionalSecretSkipped) {
    Write-Host "    - $name"
  }
}
if (-not [string]::IsNullOrWhiteSpace($VpcConnector)) {
  Write-Host " - VPC connector: $VpcConnector ($VpcEgress)"
}
