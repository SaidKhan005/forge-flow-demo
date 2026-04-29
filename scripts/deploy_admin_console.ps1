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
# surface. The script refuses to publish demo auth onto a public
# `--allow-unauthenticated` Cloud Run service silently.
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
#   scripts/deploy_admin_console.ps1
#   scripts/deploy_admin_console.ps1 -PrintCommandOnly
#   scripts/deploy_admin_console.ps1 -DemoMode -Service forge-flow-admin-sandbox

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-admin-console',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'),
  [switch] $DemoMode,
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

# Resolve the demo flag. Live is the default; demo requires an
# explicit acknowledgement so a forgotten flag never lands a
# fixture-login admin shell on a public URL.
$adminDemoAuth = 'false'
if ($DemoMode) {
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
  Write-Host "Deploying LIVE Firebase admin auth (ADMIN_DEMO_AUTH=$adminDemoAuth)."
}

$cloudRunArgs = @(
  'run', 'deploy', $Service,
  '--project', $Project,
  '--region', $Region,
  '--source', '.',
  '--service-account', $ServiceAccount,
  '--allow-unauthenticated',
  '--no-invoker-iam-check',
  '--min-instances', '0',
  '--max-instances', '2',
  '--port', '8080',
  '--quiet',
  '--dockerfile', 'Dockerfile.admin_console',
  '--build-env-vars', "ADMIN_DEMO_AUTH=$adminDemoAuth"
)

if ($PrintCommandOnly) {
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

Push-Location $repoRoot
try {
  & $gcloud @cloudRunArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
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
} else {
  Write-Host "Admin console (live Firebase auth) deployed: $adminUri"
}
