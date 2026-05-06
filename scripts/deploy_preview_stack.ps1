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

function Assert-PreviewRuntimeChecks {
  param(
    [string] $ProxyUrl,
    [string] $AdminUrl
  )

  $readyz = Invoke-WebRequest -UseBasicParsing -Uri "$ProxyUrl/readyz"
  if ($readyz.StatusCode -ne 200) {
    Write-Host "BLOCKED: preview proxy /readyz returned $($readyz.StatusCode)"
    exit 1
  }

  $preflightHeaders = @{
    Origin = $AdminUrl
    'Access-Control-Request-Method' = 'GET'
    'Access-Control-Request-Headers' = 'authorization,content-type'
  }
  $preflight = Invoke-WebRequest `
    -UseBasicParsing `
    -Method OPTIONS `
    -Uri "$ProxyUrl/v1/admin/operators" `
    -Headers $preflightHeaders
  if ($preflight.StatusCode -ne 204) {
    Write-Host "BLOCKED: preview CORS preflight returned $($preflight.StatusCode)"
    exit 1
  }

  [pscustomobject] @{
    ReadyzStatusCode = $readyz.StatusCode
    CorsPreflightStatusCode = $preflight.StatusCode
  }
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
Write-Host "Proxy base env var: $proxyEnvName"
Write-Host "Min instances: $MinInstances"
if ($SecretPrefix -eq 'forge-flow-staging-') {
  Write-Host 'Database mode: staging secrets, read-only smoke unless exact write approval is given.'
} elseif ($SecretPrefix -eq 'forge-flow-preview-') {
  Write-Host 'Database mode: preview secrets.'
} else {
  Write-Host "Database mode: custom secret prefix $SecretPrefix"
}

function Invoke-PreviewProxyDeploy {
  param([string] $CorsOrigins = '')

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
    MinInstances = $MinInstances
  }
  if (-not [string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)) {
    $proxyArgs.FirebaseGoogleServicesPath = $FirebaseGoogleServicesPath
  }
  if (-not [string]::IsNullOrWhiteSpace($VpcConnector)) {
    $proxyArgs.VpcConnector = $VpcConnector
    $proxyArgs.VpcEgress = $VpcEgress
  }
  if (-not [string]::IsNullOrWhiteSpace($CorsOrigins)) {
    $proxyArgs.AdminCorsAllowedOrigins = $CorsOrigins
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

if ($PrintCommandOnly) {
  Write-Host 'Would deploy preview proxy, preview admin, then redeploy proxy with admin CORS.'
  Write-Host "Proxy script: $(Join-Path $PSScriptRoot 'deploy_staging_proxy.ps1')"
  Write-Host "Admin script: $(Join-Path $PSScriptRoot 'deploy_admin_console.ps1')"
  exit 0
}

Write-Host 'Deploying preview proxy.'
Invoke-PreviewProxyDeploy -CorsOrigins (Join-OriginList -Origins @($AdminCorsAllowedOrigins))

$proxyUrl = Get-ServiceUrl -Service $proxyService
$proxyTuple = Get-CloudRunServiceTuple -Service $proxyService
Assert-CloudRunReadyTraffic -Service $proxyService -Tuple $proxyTuple
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
$adminTuple = Get-CloudRunServiceTuple -Service $adminService
Assert-CloudRunReadyTraffic -Service $adminService -Tuple $adminTuple
Write-Host "Preview admin URL: $adminUrl"

Write-Host 'Updating preview proxy CORS with the preview admin origin.'
Invoke-PreviewProxyDeploy -CorsOrigins (Join-OriginList -Origins @(
  $AdminCorsAllowedOrigins,
  $adminUrl
))

$finalProxyUrl = Get-ServiceUrl -Service $proxyService
$proxyRevision = Get-ReadyRevision -Service $proxyService
$adminRevision = Get-ReadyRevision -Service $adminService
$proxyTuple = Get-CloudRunServiceTuple -Service $proxyService
Assert-CloudRunReadyTraffic -Service $proxyService -Tuple $proxyTuple
$runtimeChecks = Assert-PreviewRuntimeChecks `
  -ProxyUrl $finalProxyUrl `
  -AdminUrl $adminUrl

Write-Host 'Preview deployment complete.'
Write-Host " - proxy service: $proxyService"
Write-Host " - proxy revision: $proxyRevision"
Write-Host " - proxy traffic: $($proxyTuple.TrafficRevision) / $($proxyTuple.TrafficPercent)%"
Write-Host " - proxy URL: $finalProxyUrl"
Write-Host " - admin service: $adminService"
Write-Host " - admin revision: $adminRevision"
Write-Host " - admin traffic: $($adminTuple.TrafficRevision) / $($adminTuple.TrafficPercent)%"
Write-Host " - admin URL: $adminUrl"
Write-Host " - proxy /readyz: $($runtimeChecks.ReadyzStatusCode)"
Write-Host " - admin CORS preflight: $($runtimeChecks.CorsPreflightStatusCode)"
Write-Host " - proxy base env var: $proxyEnvName"
Write-Host " - share/test URL: ${adminUrl}?cache_bust=preview-$safeName-$(Get-Date -Format yyyyMMddHHmmss)"
