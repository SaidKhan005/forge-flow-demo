# Phase 11A.0 — Deploy the F&F Operations Console (Flutter Web) to
# Cloud Run.
#
# This is the admin-only console that lives at `admin.forgeflow.app`.
# It is intentionally a separate Cloud Run service from the operator
# proxy (`forge-flow-staging-proxy`, deployed by
# `scripts/deploy_staging_proxy.ps1`) so the admin surface scales,
# rolls out, and fails independently of the operator runtime — and
# so this script never touches the operator deploy.
#
# Default = LIVE Firebase admin auth. The deployed bundle calls
# `Firebase.initializeApp(options: kAdminFirebaseOptions)` with the
# Dart options mirrored from `web/firebase-config.js`, and the gate
# admits `is_super_admin: true` / `is_ff_support: true` Firebase
# identities only; everything else fail-closes to the forbidden
# surface. Live deploys must also compile in the admin proxy base URI
# through `ADMIN_PROXY_BASE_URI`; the script refuses to publish a live
# build that would fall back to fixtures. The script refuses to publish
# demo auth onto a public `--allow-unauthenticated` Cloud Run service
# silently.
#
# Demo opt-in (NOT FOR PRODUCTION): pass `-DemoMode`. The deploy
# emits a loud warning and requires the operator to type
# `DEPLOY DEMO ADMIN AUTH` to confirm — demo auth on a public
# Cloud Run URL is a privilege bypass and should only ever ship to
# an internal / IAM-locked sandbox service. `-DemoMode` does not
# bypass the warning even with `-Force`; the operator must
# acknowledge.
#
# Examples:
#   scripts/deploy_admin_console.ps1 -AdminProxyBaseUri https://admin-proxy.forgeflow.app
#   scripts/deploy_admin_console.ps1 -PrintCommandOnly
#   scripts/deploy_admin_console.ps1 -DemoMode -Service forge-flow-admin-sandbox
#   scripts/deploy_admin_console.ps1 -SharePreview -Service forge-flow-admin-share-preview

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-admin-console',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $ArtifactRepository = 'forge-flow-cloud-run',
  [string] $AdminProxyBaseUri = $env:FORGE_FLOW_ADMIN_PROXY_BASE_URI,
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [switch] $DemoMode,
  [switch] $SharePreview,
  [switch] $SkipApiEnable,
  [switch] $PrintCommandOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
if (-not (Test-Path -LiteralPath $gcloud)) {
  $gcloud = 'gcloud'
}

if (Test-Path -LiteralPath $SecretsFile) {
  . $SecretsFile
}

if ([string]::IsNullOrWhiteSpace($AdminProxyBaseUri)) {
  if (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_ADMIN_PROXY_BASE_URI)) {
    $AdminProxyBaseUri = $env:FORGE_FLOW_ADMIN_PROXY_BASE_URI
  } elseif (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_PROXY_BASE_URI)) {
    $AdminProxyBaseUri = $env:FORGE_FLOW_PROXY_BASE_URI
  }
}

# Resolve the demo flag. Live is the default; demo requires an
# explicit acknowledgement so a forgotten flag never lands a
# fixture-login admin shell on a public URL.
$adminDemoAuth = 'false'
$adminSharePreview = 'false'
if ($SharePreview -and $DemoMode) {
  Write-Host 'BLOCKED: use either -SharePreview or -DemoMode, not both.'
  exit 1
}
if ($SharePreview) {
  $adminDemoAuth = 'true'
  $adminSharePreview = 'true'
  $AdminProxyBaseUri = ''
  Write-Host 'Deploying SHARE PREVIEW admin console.'
  Write-Host ' - no Firebase login'
  Write-Host ' - seeded in-memory demo data only'
  Write-Host ' - read-only ff_support session'
  Write-Host ' - no admin proxy base URI compiled into the bundle'
} elseif ($DemoMode) {
  Write-Host ''
  Write-Host '################################################################'
  Write-Host '#  WARNING — about to deploy DEMO admin auth to Cloud Run.     #'
  Write-Host '#                                                              #'
  Write-Host '#  Demo mode swaps the Firebase admin gate for fixture logins  #'
  Write-Host '#  (super.admin@forgeflow.test, support@forgeflow.test, ...).  #'
  Write-Host '#  On a public --allow-unauthenticated Cloud Run service this  #'
  Write-Host '#  is a privilege bypass. Only proceed if the target service   #'
  Write-Host '#  is an internal / IAM-locked sandbox.                        #'
  Write-Host '################################################################'
  Write-Host ''
  Write-Host "Target service:  $Service"
  Write-Host "Target project:  $Project"
  Write-Host "Target region:   $Region"
  Write-Host ''
  $confirmation = Read-Host 'Type "DEPLOY DEMO ADMIN AUTH" to proceed, anything else to abort'
  if ($confirmation -ne 'DEPLOY DEMO ADMIN AUTH') {
    Write-Host 'Aborted; demo deploy was not confirmed.'
    exit 1
  }
  $adminDemoAuth = 'true'
} else {
  if ([string]::IsNullOrWhiteSpace($AdminProxyBaseUri)) {
    Write-Host 'BLOCKED: live admin console deploy requires ADMIN_PROXY_BASE_URI.'
    Write-Host 'Pass -AdminProxyBaseUri or set FORGE_FLOW_ADMIN_PROXY_BASE_URI / FORGE_FLOW_PROXY_BASE_URI in the secrets file.'
    exit 1
  }
  Write-Host "Deploying LIVE Firebase admin auth (ADMIN_DEMO_AUTH=$adminDemoAuth)."
  Write-Host "Admin proxy base URI: $AdminProxyBaseUri"
}

$imageTag = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
$image = "$Region-docker.pkg.dev/$Project/$ArtifactRepository/${Service}:$imageTag"

$cloudRunArgs = @(
  'run', 'deploy', $Service,
  '--project', $Project,
  '--region', $Region,
  '--image', $image,
  '--service-account', $ServiceAccount,
  '--allow-unauthenticated',
  '--no-invoker-iam-check',
  '--min-instances', '0',
  '--max-instances', '2',
  '--port', '8080',
  '--quiet'
)

function Quote-CloudBuildYamlValue([string] $Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

$cloudBuildConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-flow-admin-console-cloudbuild-$PID.yaml"
$cloudBuildConfig = @(
  'steps:',
  "- name: 'gcr.io/cloud-builders/docker'",
  '  args:',
  "  - 'build'",
  "  - '-f'",
  "  - 'Dockerfile.admin_console'",
  "  - '--build-arg'",
  "  - $(Quote-CloudBuildYamlValue "ADMIN_DEMO_AUTH=$adminDemoAuth")",
  "  - '--build-arg'",
  "  - $(Quote-CloudBuildYamlValue "ADMIN_SHARE_PREVIEW=$adminSharePreview")",
  "  - '--build-arg'",
  "  - $(Quote-CloudBuildYamlValue "ADMIN_PROXY_BASE_URI=$AdminProxyBaseUri")",
  "  - '-t'",
  "  - $(Quote-CloudBuildYamlValue $image)",
  "  - '.'",
  'images:',
  "- $(Quote-CloudBuildYamlValue $image)"
) -join "`n"

$cloudBuildArgs = @(
  'builds', 'submit', $repoRoot,
  '--project', $Project,
  '--config', $cloudBuildConfigPath,
  '--quiet'
)

if ($PrintCommandOnly) {
  Write-Host "Set-Content -LiteralPath $cloudBuildConfigPath -Value <cloudbuild-yaml-with-docker-build-args>"
  Write-Host "$gcloud $($cloudBuildArgs -join ' ')"
  Write-Host "$gcloud $($cloudRunArgs -join ' ')"
  exit 0
}

if (-not $SkipApiEnable) {
  & $gcloud services enable `
    run.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    --project $Project `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  & $gcloud artifacts repositories describe $ArtifactRepository `
    --project $Project `
    --location $Region `
    --quiet *> $null
  $artifactRepositoryDescribeExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($artifactRepositoryDescribeExitCode -ne 0) {
  & $gcloud artifacts repositories create $ArtifactRepository `
    --project $Project `
    --location $Region `
    --repository-format docker `
    --description 'Forge Flow Cloud Run images' `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Push-Location $repoRoot
try {
  Set-Content -LiteralPath $cloudBuildConfigPath -Value $cloudBuildConfig -Encoding UTF8
  & $gcloud @cloudBuildArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  & $gcloud @cloudRunArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  if (Test-Path -LiteralPath $cloudBuildConfigPath) {
    Remove-Item -LiteralPath $cloudBuildConfigPath -Force
  }
  Pop-Location
}

$adminUri = & $gcloud run services describe $Service `
  --project $Project `
  --region $Region `
  --format 'value(status.url)'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ([string]::IsNullOrWhiteSpace($adminUri)) {
  Write-Host 'BLOCKED: admin console deploy returned no URL.'
  exit 1
}

if ($DemoMode) {
  Write-Host "Admin console (DEMO AUTH) deployed: $adminUri"
} elseif ($SharePreview) {
  Write-Host "Admin console (SHARE PREVIEW, fixture data only) deployed: $adminUri"
} else {
  Write-Host "Admin console (live Firebase auth) deployed: $adminUri"
}
