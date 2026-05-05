# Deploy an isolated Forge & Flow admin preview stack.
#
# The preview stack uses separate Cloud Run services from shared staging so
# branch and UX acceptance work can run end to end without routing shared
# staging users onto an experimental revision.
#
# Default service names:
#   - forge-flow-preview-proxy
#   - forge-flow-preview-admin-console
#
# The proxy deploy has a dependency loop with the frontend:
#   - the frontend build needs the proxy URL compiled into ADMIN_PROXY_BASE_URI
#   - the proxy CORS allow-list needs the frontend Cloud Run origin
#
# This wrapper handles that loop:
#   1. deploy preview proxy
#   2. discover preview proxy URL
#   3. deploy preview admin frontend against that proxy
#   4. discover preview admin URL
#   5. redeploy preview proxy with the preview admin origin allowed
#   6. verify Ready revisions, 100% traffic, /readyz, and browser-origin CORS
#      preflight

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $PreviewName = 'preview',
  [string] $AdminService = '',
  [string] $ProxyService = '',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $ArtifactRepository = 'forge-flow-cloud-run',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [string] $SecretPrefix = 'forge-flow-staging-',
  [string] $ProxyBaseUriEnvVarName = '',
  [string] $AdminCorsAllowedOrigins = $env:ADMIN_CORS_ALLOWED_ORIGINS,
  [string] $VpcConnector = 'ff-staging-proxy-egress',
  [string] $VpcEgress = 'all-traffic',
  [int] $MinInstances = 0,
  [switch] $SkipApiEnable,
  [switch] $SkipSecretManagerSync,
  [switch] $PrintCommandOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$deployProxyScript = Join-Path $PSScriptRoot 'deploy_staging_proxy.ps1'
$deployAdminScript = Join-Path $PSScriptRoot 'deploy_admin_console.ps1'
$gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
if (-not (Test-Path -LiteralPath $gcloud)) {
  $gcloud = 'gcloud'
}

function ConvertTo-CloudRunSlug {
  param([string] $Value)

  $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-'
  $slug = $slug -replace '-+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = 'preview'
  }
  if ($slug.Length -gt 24) {
    $slug = $slug.Substring(0, 24).Trim('-')
  }
  return $slug
}

function Join-OriginList {
  param([string[]] $Origins)

  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
  )
  $clean = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Origins) {
    foreach ($candidate in (([string] $entry) -split ',')) {
      $origin = $candidate.Trim()
      if ([string]::IsNullOrWhiteSpace($origin)) { continue }
      if ($seen.Add($origin)) {
        $clean.Add($origin)
      }
    }
  }
  return ($clean -join ',')
}

function Get-CloudRunServiceTuple {
  param([string] $Service)

  $value = & $gcloud run services describe $Service `
    --project $Project `
    --region $Region `
    --format 'value(status.latestReadyRevisionName,status.traffic[0].revisionName,status.traffic[0].percent,status.url)'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $parts = $value -split "`t"
  [pscustomobject] @{
    LatestReadyRevision = $parts[0]
    TrafficRevision = $parts[1]
    TrafficPercent = $parts[2]
    Url = $parts[3]
  }
}

function Assert-CloudRunReadyTraffic {
  param(
    [string] $Service,
    [object] $Tuple
  )

  if ([string]::IsNullOrWhiteSpace($Tuple.LatestReadyRevision)) {
    Write-Host "BLOCKED: $Service does not have a latest Ready revision."
    exit 1
  }
  if ($Tuple.TrafficRevision -ne $Tuple.LatestReadyRevision) {
    Write-Host "BLOCKED: $Service traffic revision is not latest Ready."
    Write-Host " - latest Ready: $($Tuple.LatestReadyRevision)"
    Write-Host " - traffic revision: $($Tuple.TrafficRevision)"
    exit 1
  }
  if ([string] $Tuple.TrafficPercent -ne '100') {
    Write-Host "BLOCKED: $Service is not serving 100% traffic."
    Write-Host " - traffic percent: $($Tuple.TrafficPercent)"
    exit 1
  }
}

function Invoke-PreviewProxyDeploy {
  param([string] $CorsOrigins)

  $proxyDeployArgs = @(
    '-Project', $Project,
    '-Region', $Region,
    '-Service', $ProxyService,
    '-ServiceAccount', $ServiceAccount,
    '-SecretsFile', $SecretsFile,
    '-SecretPrefix', $SecretPrefix,
    '-ProxyBaseUriEnvVarName', $ProxyBaseUriEnvVarName,
    '-ProxyEnvironment', 'staging',
    '-MinInstances', $MinInstances
  )
  if (-not [string]::IsNullOrWhiteSpace($CorsOrigins)) {
    $proxyDeployArgs += @('-AdminCorsAllowedOrigins', $CorsOrigins)
  }
  if (-not [string]::IsNullOrWhiteSpace($VpcConnector)) {
    $proxyDeployArgs += @('-VpcConnector', $VpcConnector, '-VpcEgress', $VpcEgress)
  }
  if ($SkipApiEnable) { $proxyDeployArgs += '-SkipApiEnable' }
  if ($SkipSecretManagerSync) { $proxyDeployArgs += '-SkipSecretManagerSync' }

  if ($env:FORGE_FLOW_PREVIEW_DEBUG_ARGS -eq 'true') {
    Write-Host 'Preview proxy deploy args:'
    foreach ($arg in $proxyDeployArgs) {
      Write-Host " - $arg"
    }
  }

  & powershell -ExecutionPolicy Bypass -File $deployProxyScript @proxyDeployArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$slug = ConvertTo-CloudRunSlug -Value $PreviewName
if ([string]::IsNullOrWhiteSpace($AdminService)) {
  $AdminService = "forge-flow-$slug-admin-console"
}
if ([string]::IsNullOrWhiteSpace($ProxyService)) {
  $ProxyService = "forge-flow-$slug-proxy"
}
if ([string]::IsNullOrWhiteSpace($ProxyBaseUriEnvVarName)) {
  $envSlug = ($slug.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
  $ProxyBaseUriEnvVarName = "FORGE_FLOW_${envSlug}_PROXY_BASE_URI"
}

foreach ($serviceName in @($AdminService, $ProxyService)) {
  if ($serviceName.Length -gt 63) {
    Write-Host "BLOCKED: Cloud Run service name exceeds 63 chars: $serviceName"
    exit 1
  }
  if ($serviceName -notmatch '^[a-z][a-z0-9-]*[a-z0-9]$') {
    Write-Host "BLOCKED: invalid Cloud Run service name: $serviceName"
    exit 1
  }
}

Write-Host 'Preview stack target:'
Write-Host " - project: $Project"
Write-Host " - region: $Region"
Write-Host " - preview name: $slug"
Write-Host " - admin service: $AdminService"
Write-Host " - proxy service: $ProxyService"
Write-Host " - proxy secret prefix: $SecretPrefix"
Write-Host " - proxy env var sink: $ProxyBaseUriEnvVarName"
Write-Host " - min instances: $MinInstances"
Write-Host ''

if ($PrintCommandOnly) {
  Write-Host 'Would deploy preview proxy, preview admin, then redeploy proxy with admin CORS.'
  Write-Host "Proxy script: $deployProxyScript"
  Write-Host "Admin script: $deployAdminScript"
  exit 0
}

$initialCorsOrigins = Join-OriginList -Origins @($AdminCorsAllowedOrigins)
Invoke-PreviewProxyDeploy -CorsOrigins $initialCorsOrigins
$proxyTuple = Get-CloudRunServiceTuple -Service $ProxyService
Assert-CloudRunReadyTraffic -Service $ProxyService -Tuple $proxyTuple

$adminDeployArgs = @(
  '-Project', $Project,
  '-Region', $Region,
  '-Service', $AdminService,
  '-ServiceAccount', $ServiceAccount,
  '-ArtifactRepository', $ArtifactRepository,
  '-AdminProxyBaseUri', $proxyTuple.Url,
  '-SecretsFile', $SecretsFile
)
if ($SkipApiEnable) { $adminDeployArgs += '-SkipApiEnable' }

& powershell -ExecutionPolicy Bypass -File $deployAdminScript @adminDeployArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$adminTuple = Get-CloudRunServiceTuple -Service $AdminService
Assert-CloudRunReadyTraffic -Service $AdminService -Tuple $adminTuple
$finalCorsOrigins = Join-OriginList -Origins @(
  $AdminCorsAllowedOrigins,
  $adminTuple.Url
)
Invoke-PreviewProxyDeploy -CorsOrigins $finalCorsOrigins
$proxyTuple = Get-CloudRunServiceTuple -Service $ProxyService
Assert-CloudRunReadyTraffic -Service $ProxyService -Tuple $proxyTuple

$readyz = Invoke-WebRequest -UseBasicParsing -Uri "$($proxyTuple.Url)/readyz"
if ($readyz.StatusCode -ne 200) {
  Write-Host "BLOCKED: preview proxy /readyz returned $($readyz.StatusCode)"
  exit 1
}

$preflightHeaders = @{
  Origin = $adminTuple.Url
  'Access-Control-Request-Method' = 'GET'
  'Access-Control-Request-Headers' = 'authorization,content-type'
}
$preflight = Invoke-WebRequest `
  -UseBasicParsing `
  -Method OPTIONS `
  -Uri "$($proxyTuple.Url)/v1/admin/operators" `
  -Headers $preflightHeaders
if ($preflight.StatusCode -ne 204) {
  Write-Host "BLOCKED: preview CORS preflight returned $($preflight.StatusCode)"
  exit 1
}

Write-Host ''
Write-Host 'Preview stack deployed and verified:'
Write-Host " - admin URL: $($adminTuple.Url)"
Write-Host " - proxy URL: $($proxyTuple.Url)"
Write-Host " - admin revision: $($adminTuple.LatestReadyRevision)"
Write-Host " - admin traffic: $($adminTuple.TrafficRevision) / $($adminTuple.TrafficPercent)%"
Write-Host " - proxy revision: $($proxyTuple.LatestReadyRevision)"
Write-Host " - proxy traffic: $($proxyTuple.TrafficRevision) / $($proxyTuple.TrafficPercent)%"
Write-Host " - proxy /readyz: $($readyz.StatusCode)"
Write-Host " - admin CORS preflight: $($preflight.StatusCode)"
Write-Host ''
Write-Host "Share/test URL: $($adminTuple.Url)?cache_bust=preview-$slug-$(Get-Date -Format yyyyMMddHHmmss)"
