# Deploy the Forge Flow projection_retry_worker Cloud Run Job
# + Cloud Scheduler trigger.
#
# Posture mirrors the other Forge Flow worker deploy scripts:
#   * loads $HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1
#   * never prints secret values
#   * supports -Preflight for name-only dry runs
#   * deploys a Cloud Run Job, not a Service
#   * pins production to runOnce, not daemon

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $SchedulerLocation = 'northamerica-northeast1',
  [string] $JobName = 'forge-flow-projection-retry',
  [string] $SchedulerName = 'forge-flow-projection-retry-trigger',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $Image = '',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [string] $SecretPrefix = 'forge-flow-staging-',
  [string] $VpcConnector = 'ff-staging-proxy-egress',
  [string] $VpcEgress = 'all-traffic',
  [switch] $Preflight,
  [switch] $SkipApiEnable,
  [switch] $SkipSecretManagerSync
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gcloud = Join-Path $HOME 'AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
if (-not (Test-Path -LiteralPath $gcloud)) {
  $gcloud = 'gcloud'
}

$ScheduleCron = '*/5 * * * *'
$ScheduleTimeZone = 'Etc/UTC'

$requiredEnv = @('POSTGRES_URL')

if (-not $SecretPrefix.EndsWith('-')) {
  Write-Host "BLOCKED: -SecretPrefix '$SecretPrefix' must end with '-'."
  exit 1
}

$secretEnv = [ordered] @{
  'POSTGRES_URL' = "${SecretPrefix}postgres-url"
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

function Write-PreflightHeader {
  Write-Host '=== Preflight (no live mutation) ==='
  Write-Host "Project:         $Project"
  Write-Host "Region:          $Region"
  Write-Host "Scheduler loc.:  $SchedulerLocation"
  Write-Host "Job name:        $JobName"
  Write-Host "Scheduler name:  $SchedulerName"
  Write-Host "Service account: $ServiceAccount"
  Write-Host "Schedule:        $ScheduleCron ($ScheduleTimeZone)"
  Write-Host 'Required env NAMES (values resolved at runtime, never printed):'
  foreach ($name in $requiredEnv) {
    Write-Host " - $name"
  }
  Write-Host 'Secret Manager mapping (NAME -> SECRET):'
  foreach ($entry in $secretEnv.GetEnumerator()) {
    Write-Host (" - {0} -> {1}" -f $entry.Key, $entry.Value)
  }
}

if (-not (Test-Path -LiteralPath $SecretsFile)) {
  Write-Host 'BLOCKED: missing required env names:'
  Write-Host ' - forge_flow.secrets.ps1'
  exit 1
}

. $SecretsFile

Assert-PresentEnv -Names $requiredEnv

if ($Preflight) {
  Write-PreflightHeader
  Write-Host ''
  Write-Host 'Would execute (dry-run, no mutation):'
  Write-Host (" {0} services enable run.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com --project {1} --quiet" -f $gcloud, $Project)
  foreach ($entry in $secretEnv.GetEnumerator()) {
    Write-Host (" {0} secrets describe {1} --project {2}" -f $gcloud, $entry.Value, $Project)
    Write-Host (" {0} secrets versions add {1} --project {2} --data-file <temp file from `$env:{3}> (value never printed)" -f $gcloud, $entry.Value, $Project, $entry.Key)
  }
  Write-Host (" {0} run jobs deploy {1} --project {2} --region {3} --service-account {4} --image <image> --command /app/projection_retry_worker --args runOnce --set-secrets <name=secret:latest,...> --vpc-connector {5} --vpc-egress {6} --quiet" -f $gcloud, $JobName, $Project, $Region, $ServiceAccount, $VpcConnector, $VpcEgress)
  Write-Host (" {0} scheduler jobs create http {1} --project {2} --location {3} --schedule '{4}' --time-zone '{5}' --uri https://{6}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/{2}/jobs/{7}:run --http-method POST --oauth-service-account-email {8} --attempt-deadline 600s" -f $gcloud, $SchedulerName, $Project, $SchedulerLocation, $ScheduleCron, $ScheduleTimeZone, $Region, $JobName, $ServiceAccount)
  Write-Host ''
  Write-Host 'Preflight complete. Re-run without -Preflight to apply.'
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Image)) {
  Write-Host 'BLOCKED: -Image is required for a non-preflight run.'
  Write-Host 'Provide an Artifact Registry image URI built from this repo.'
  exit 1
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
    cloudscheduler.googleapis.com `
    secretmanager.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
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

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  & $gcloud run jobs describe $JobName `
    --project $Project `
    --region $Region `
    --quiet *> $null
  $jobDescribeExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}

$jobVerb = if ($jobDescribeExit -eq 0) { 'update' } else { 'deploy' }

Push-Location $repoRoot
try {
  & $gcloud run jobs $jobVerb $JobName `
    --project $Project `
    --region $Region `
    --service-account $ServiceAccount `
    --image $Image `
    --command /app/projection_retry_worker `
    --args runOnce `
    --set-secrets $secretAssignments `
    --vpc-connector $VpcConnector `
    --vpc-egress $VpcEgress `
    --max-retries 0 `
    --task-timeout 600s `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}

$jobRunUri = "https://$Region-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$Project/jobs/$JobName`:run"

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  & $gcloud scheduler jobs describe $SchedulerName `
    --project $Project `
    --location $SchedulerLocation `
    --quiet *> $null
  $schedulerDescribeExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}

if ($schedulerDescribeExit -eq 0) {
  & $gcloud scheduler jobs update http $SchedulerName `
    --project $Project `
    --location $SchedulerLocation `
    --schedule $ScheduleCron `
    --time-zone $ScheduleTimeZone `
    --uri $jobRunUri `
    --http-method POST `
    --oauth-service-account-email $ServiceAccount `
    --attempt-deadline 600s `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  & $gcloud scheduler jobs create http $SchedulerName `
    --project $Project `
    --location $SchedulerLocation `
    --schedule $ScheduleCron `
    --time-zone $ScheduleTimeZone `
    --uri $jobRunUri `
    --http-method POST `
    --oauth-service-account-email $ServiceAccount `
    --attempt-deadline 600s `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host 'Deployment complete. Name-only prerequisites available:'
Write-Host " - Cloud Run Job: $JobName"
Write-Host " - Cloud Scheduler: $SchedulerName ($ScheduleCron $ScheduleTimeZone)"
foreach ($name in $requiredEnv) {
  Write-Host " - $name (Secret Manager backed)"
}
Write-Host ' - Worker mode: runOnce'
