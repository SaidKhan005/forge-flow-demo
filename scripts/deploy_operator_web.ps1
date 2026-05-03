# Phase 11W.0 — Deploy the Forge & Flow Operator Web Console (Flutter
# Web) to Cloud Run.
#
# This is the operator-facing web console that lives at
# `app.forgeflow.app`. It is intentionally a separate Cloud Run service
# from the operator-app proxy (`forge-flow-staging-proxy`, deployed by
# `scripts/deploy_staging_proxy.ps1`) and the F&F Operations Console
# (`forge-flow-admin-console`, deployed by
# `scripts/deploy_admin_console.ps1`) so each web surface scales,
# rolls out, and fails independently — and so this script never
# touches the operator deploy or the admin deploy.
#
# Default = LIVE Firebase auth. The deployed bundle calls
# `Firebase.initializeApp(options: kOperatorWebFirebaseOptions)` with
# the Dart options mirrored from `web/firebase-config.js`, and the
# onboarding click path runs against the live Phase 9 proxy routes.
# Live deploys must compile in the operator-web proxy base URI through
# `OPERATOR_WEB_PROXY_BASE_URI`; the script refuses to publish a live
# build that would fall back to fixtures.
#
# Demo opt-in (NOT FOR PRODUCTION): pass `-DemoMode`. The deploy
# emits a loud warning and requires the operator to type
# `DEPLOY DEMO OPERATOR WEB AUTH` to confirm — demo auth on a public
# Cloud Run URL is a privilege bypass and should only ever ship to
# an internal / IAM-locked sandbox service.
#
# Examples:
#   scripts/deploy_operator_web.ps1 -ProxyBaseUri https://proxy.forgeflow.app
#   scripts/deploy_operator_web.ps1 -PrintCommandOnly
#   scripts/deploy_operator_web.ps1 -DryRun
#   scripts/deploy_operator_web.ps1 -DemoMode -Service forge-flow-operator-web-sandbox
#
# Notes:
# - Cloud Build is invoked with `Dockerfile.operator_web`. The
#   Dockerfile overlays the operator-web web shell (`web/operator/*`)
#   onto `web/` inside the build container so the compiled bundle
#   carries the correct `<title>` + manifest. The on-disk source tree
#   stays untouched.
# - For local Flutter Web testing, run
#   `flutter build web --target=lib/main_operator_web.dart --output=build/operator_web --dart-define=OPERATOR_WEB_DEMO_AUTH=true`
#   from the repo root. The local build will use the existing `web/`
#   shell (admin-console title) — that's expected; the deploy build
#   swaps in the operator-web shell.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $Service = 'forge-flow-operator-web',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $ArtifactRepository = 'forge-flow-cloud-run',
  [string] $ProxyBaseUri = $env:FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI,
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [switch] $DemoMode,
  [switch] $SkipApiEnable,
  [switch] $PrintCommandOnly,
  [switch] $DryRun
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

# Fall back to the shared FORGE_FLOW_PROXY_BASE_URI if the
# operator-web-specific override isn't set; the operator-web console
# talks to the same advisor proxy as the mobile operator app.
if ([string]::IsNullOrWhiteSpace($ProxyBaseUri)) {
  if (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI)) {
    $ProxyBaseUri = $env:FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI
  } elseif (-not [string]::IsNullOrWhiteSpace($env:FORGE_FLOW_PROXY_BASE_URI)) {
    $ProxyBaseUri = $env:FORGE_FLOW_PROXY_BASE_URI
  }
}

# Resolve the demo flag. Live is the default; demo requires an
# explicit acknowledgement so a forgotten flag never lands a
# fixture-login operator-web shell on a public URL.
$operatorWebDemoAuth = 'false'
if ($DemoMode) {
  Write-Host ''
  Write-Host '################################################################'
  Write-Host '#  WARNING — about to deploy DEMO operator-web auth.           #'
  Write-Host '#                                                              #'
  Write-Host '#  Demo mode swaps the Firebase auth source for the in-memory  #'
  Write-Host '#  walkthrough source. On a public --allow-unauthenticated     #'
  Write-Host '#  Cloud Run service this is a privilege bypass. Only proceed  #'
  Write-Host '#  if the target service is an internal / IAM-locked sandbox.  #'
  Write-Host '################################################################'
  Write-Host ''
  Write-Host "Target service:  $Service"
  Write-Host "Target project:  $Project"
  Write-Host "Target region:   $Region"
  Write-Host ''
  if ($DryRun -or $PrintCommandOnly) {
    Write-Host 'Dry-run/print mode active — skipping interactive confirmation, but a real deploy would refuse to proceed without "DEPLOY DEMO OPERATOR WEB AUTH".'
  } else {
    $confirmation = Read-Host 'Type "DEPLOY DEMO OPERATOR WEB AUTH" to proceed, anything else to abort'
    if ($confirmation -ne 'DEPLOY DEMO OPERATOR WEB AUTH') {
      Write-Host 'Aborted; demo deploy was not confirmed.'
      exit 1
    }
  }
  $operatorWebDemoAuth = 'true'
} else {
  if ([string]::IsNullOrWhiteSpace($ProxyBaseUri)) {
    Write-Host 'BLOCKED: live operator-web deploy requires OPERATOR_WEB_PROXY_BASE_URI.'
    Write-Host 'Pass -ProxyBaseUri or set FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI / FORGE_FLOW_PROXY_BASE_URI in the secrets file.'
    if (-not ($PrintCommandOnly -or $DryRun)) {
      exit 1
    }
  } else {
    Write-Host "Deploying LIVE Firebase auth (OPERATOR_WEB_DEMO_AUTH=$operatorWebDemoAuth)."
    Write-Host "Operator-web proxy base URI: $ProxyBaseUri"
  }
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

$cloudBuildConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "forge-flow-operator-web-cloudbuild-$PID.yaml"
$cloudBuildConfig = @(
  'steps:',
  "- name: 'gcr.io/cloud-builders/docker'",
  '  args:',
  "  - 'build'",
  "  - '-f'",
  "  - 'Dockerfile.operator_web'",
  "  - '--build-arg'",
  "  - $(Quote-CloudBuildYamlValue "OPERATOR_WEB_DEMO_AUTH=$operatorWebDemoAuth")",
  "  - '--build-arg'",
  "  - $(Quote-CloudBuildYamlValue "OPERATOR_WEB_PROXY_BASE_URI=$ProxyBaseUri")",
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

if ($PrintCommandOnly -or $DryRun) {
  Write-Host "Set-Content -LiteralPath $cloudBuildConfigPath -Value <cloudbuild-yaml-with-docker-build-args>"
  Write-Host "$gcloud $($cloudBuildArgs -join ' ')"
  Write-Host "$gcloud $($cloudRunArgs -join ' ')"
  if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry-run preflight: command set assembled cleanly (above). No Cloud Build invocation.'
  }
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

$serviceUri = & $gcloud run services describe $Service `
  --project $Project `
  --region $Region `
  --format 'value(status.url)'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ([string]::IsNullOrWhiteSpace($serviceUri)) {
  Write-Host 'BLOCKED: operator-web deploy returned no URL.'
  exit 1
}

if ($DemoMode) {
  Write-Host "Operator Web Console (DEMO AUTH) deployed: $serviceUri"
} else {
  Write-Host "Operator Web Console (live Firebase auth) deployed: $serviceUri"
}
