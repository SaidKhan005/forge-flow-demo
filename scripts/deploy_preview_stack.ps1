# Deploy an isolated Forge Flow preview proxy and admin console pair.
#
# This wrapper keeps preview deploys off the shared staging services by
# deriving distinct Cloud Run service names from -PreviewName. It uses
# the same deploy primitives as staging, but writes the proxy URL into a
# preview-specific env var in the local non-repo secrets file.

param(
  [Parameter(Mandatory = $true)]
  [string] $PreviewName,
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $ArtifactRepository = 'forge-flow-cloud-run',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [string] $SecretPrefix = 'forge-flow-staging-',
  [string] $FirebaseGoogleServicesPath = '',
  [string] $VpcConnector = '',
  [string] $VpcEgress = 'all-traffic',
  [switch] $SkipApiEnable,
  [switch] $SkipSecretManagerSync
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
if (-not (Test-Path -LiteralPath $gcloud)) {
  $gcloud = 'gcloud'
}

function Normalize-PreviewName {
  param([string] $Name)

  $lower = $Name.Trim().ToLowerInvariant()
  $safe = [regex]::Replace($lower, '[^a-z0-9-]+', '-')
  $safe = [regex]::Replace($safe, '-+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    Write-Host 'BLOCKED: -PreviewName must contain at least one letter or number.'
    exit 1
  }
  return $safe
}

function Get-ServiceUrl {
  param([string] $Service)

  $url = & $gcloud run services describe $Service `
    --project $Project `
    --region $Region `
    --format 'value(status.url)'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Host "BLOCKED: Cloud Run service '$Service' returned no URL."
    exit 1
  }
  return $url
}

function Get-ReadyRevision {
  param([string] $Service)

  $revision = & $gcloud run services describe $Service `
    --project $Project `
    --region $Region `
    --format 'value(status.latestReadyRevisionName)'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  return $revision
}

$safeName = Normalize-PreviewName -Name $PreviewName
$proxyService = "forge-flow-preview-$safeName-proxy"
$adminService = "forge-flow-preview-$safeName-admin"
if ($proxyService.Length -gt 63 -or $adminService.Length -gt 63) {
  Write-Host 'BLOCKED: preview service names must be 63 characters or fewer.'
  Write-Host " - $proxyService"
  Write-Host " - $adminService"
  exit 1
}

$proxyEnvName = 'FORGE_FLOW_PREVIEW_' + ($safeName.ToUpperInvariant() -replace '-', '_') + '_PROXY_BASE_URI'
$proxyEnvironment = "preview-$safeName"

Write-Host "Preview proxy service: $proxyService"
Write-Host "Preview admin service: $adminService"
Write-Host "Secret prefix: $SecretPrefix"
if ($SecretPrefix -eq 'forge-flow-staging-') {
  Write-Host 'Database mode: staging secrets, read-only smoke unless exact write approval is given.'
} elseif ($SecretPrefix -eq 'forge-flow-preview-') {
  Write-Host 'Database mode: preview secrets.'
} else {
  Write-Host "Database mode: custom secret prefix $SecretPrefix"
}

function Invoke-PreviewProxyDeploy {
  param([string] $AdminCorsAllowedOrigins = '')

  $proxyScript = Join-Path $PSScriptRoot 'deploy_staging_proxy.ps1'
  $proxyArgs = @{
    Project = $Project
    Region = $Region
    Service = $proxyService
    ServiceAccount = $ServiceAccount
    SecretsFile = $SecretsFile
    SecretPrefix = $SecretPrefix
    ProxyBaseUriEnvVarName = $proxyEnvName
    ProxyEnvironment = $proxyEnvironment
    MinInstances = 0
  }
  if (-not [string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)) {
    $proxyArgs.FirebaseGoogleServicesPath = $FirebaseGoogleServicesPath
  }
  if (-not [string]::IsNullOrWhiteSpace($VpcConnector)) {
    $proxyArgs.VpcConnector = $VpcConnector
    $proxyArgs.VpcEgress = $VpcEgress
  }
  if (-not [string]::IsNullOrWhiteSpace($AdminCorsAllowedOrigins)) {
    $proxyArgs.AdminCorsAllowedOrigins = $AdminCorsAllowedOrigins
  }
  if ($SkipApiEnable) {
    $proxyArgs.SkipApiEnable = $true
  }
  if ($SkipSecretManagerSync) {
    $proxyArgs.SkipSecretManagerSync = $true
  }

  & $proxyScript @proxyArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host 'Deploying preview proxy.'
Invoke-PreviewProxyDeploy

$proxyUrl = Get-ServiceUrl -Service $proxyService
Write-Host "Preview proxy URL: $proxyUrl"

Write-Host 'Deploying preview admin console.'
$adminScript = Join-Path $PSScriptRoot 'deploy_admin_console.ps1'
$adminArgs = @{
  Project = $Project
  Region = $Region
  Service = $adminService
  ServiceAccount = $ServiceAccount
  ArtifactRepository = $ArtifactRepository
  AdminProxyBaseUri = $proxyUrl
  SecretsFile = $SecretsFile
}
if ($SkipApiEnable) {
  $adminArgs.SkipApiEnable = $true
}
& $adminScript @adminArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$adminUrl = Get-ServiceUrl -Service $adminService
Write-Host "Preview admin URL: $adminUrl"

Write-Host 'Updating preview proxy CORS with the preview admin origin.'
Invoke-PreviewProxyDeploy -AdminCorsAllowedOrigins $adminUrl

$finalProxyUrl = Get-ServiceUrl -Service $proxyService
$proxyRevision = Get-ReadyRevision -Service $proxyService
$adminRevision = Get-ReadyRevision -Service $adminService

Write-Host 'Preview deployment complete.'
Write-Host " - proxy service: $proxyService"
Write-Host " - proxy revision: $proxyRevision"
Write-Host " - proxy URL: $finalProxyUrl"
Write-Host " - admin service: $adminService"
Write-Host " - admin revision: $adminRevision"
Write-Host " - admin URL: $adminUrl"
Write-Host " - proxy base env var: $proxyEnvName"
