# Deploy the Forge Flow first_connect_backfill_worker Cloud Run Job
# + Cloud Scheduler trigger.
#
# Phase 8 gap-2. Pairs with:
#   * tool/first_connect_backfill_worker/Dockerfile — build context.
#   * tool/first_connect_backfill_worker/README.md — operator runbook
#     (deploy shape, env names, retry-cap + dead-letter semantics,
#     adapter factory follow-up).
#
# Posture (mirrors scripts/deploy_audit_anchor_job.ps1):
#   * Loads $HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1;
#     never prints secret VALUES, only secret env NAMES.
#   * `-Preflight` switch performs name-only checks and prints the
#     gcloud commands that *would* run; it never mutates Cloud Run,
#     Secret Manager, or Cloud Scheduler.
#   * Idempotent: secret create/update, job deploy, and scheduler
#     create all describe-first / update-fallback so re-running the
#     script is safe.
#   * Cloud Run JOB (not Service): Cloud Scheduler fires every 60s,
#     each invocation drains every claimable scope's queue then exits.
#     See README.md "Deploy shape" for the rationale.
#
# Required env names (loaded from the secrets file, NEVER printed):
#   - POSTGRES_URL
#   - PGCRYPTO_ENVELOPE_KEY  (Phase 8 — required by the worker since the
#                              binder builder constructs
#                              `VendorCredentialBroker` against this
#                              key. Mirrors the staging proxy required
#                              list from deploy_staging_proxy.ps1.)
#
# Optional env names (loaded if present, fall back to worker defaults):
#   - FIRST_CONNECT_BACKFILL_WORKER_POLL_SECONDS
#   - FIRST_CONNECT_BACKFILL_WORKER_MAX_JOBS_PER_TICK
#   - FIRST_CONNECT_BACKFILL_WORKER_MAX_ATTEMPTS
#   - FIRST_CONNECT_BACKFILL_WORKER_CLAIM_STALE_SECONDS
#   - FIRST_CONNECT_BACKFILL_WORKER_ID_PREFIX
#   - FF_WEBHOOK_PUBLIC_BASE_URI
#
# Optional vendor app credentials (each connector binder activates only
# when its full bundle is present; absent bundles surface as warn-
# disabled vendors that the backfill worker dead-letters with a clean
# reason):
#   - ALOHA_NCR_VOYIX_CLIENT_ID / _CLIENT_SECRET / _APPLICATION_KEY /
#     _ORGANIZATION_ID
#   - SQUARE_CLIENT_ID / _CLIENT_SECRET / _NOTIFICATION_URL_HOST
#   - CLOVER_APP_TOKEN / _APP_ID
#
# Secret Manager mapping:
#   - POSTGRES_URL          -> forge-flow-staging-postgres-url
#   - PGCRYPTO_ENVELOPE_KEY -> forge-flow-staging-pgcrypto-envelope-key
#                              (same secret the proxy reads;
#                              deploy_staging_proxy.ps1 owns the source
#                              of truth.)
#
# Schedule: `*/1 * * * *` UTC (every minute). The trigger lives in
# northamerica-northeast1 because Cloud Scheduler is not available in
# northamerica-northeast2 today; the Job itself runs in $Region.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  [string] $SchedulerLocation = 'northamerica-northeast1',
  [string] $JobName = 'forge-flow-first-connect-backfill',
  [string] $SchedulerName = 'forge-flow-first-connect-backfill-trigger',
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

# Schedule contract. Locked at 8.gap-2: every minute UTC. Update both
# this constant AND tool/first_connect_backfill_worker/README.md if
# the schedule ever changes.
$ScheduleCron = '*/1 * * * *'
$ScheduleTimeZone = 'Etc/UTC'

# Required env NAMES (NEVER values).
#
# Phase 8 (8.backfill-worker-adapter-factory-wire-in): the worker now
# constructs the binder's per-vendor adapter factories at boot, which
# requires PGCRYPTO_ENVELOPE_KEY for the VendorCredentialBroker. Same
# secret the proxy reads.
$requiredEnv = @(
  'POSTGRES_URL',
  'PGCRYPTO_ENVELOPE_KEY'
)

if (-not $SecretPrefix.EndsWith('-')) {
  Write-Host "BLOCKED: -SecretPrefix '$SecretPrefix' must end with '-'."
  exit 1
}

$secretSuffix = [ordered] @{
  'POSTGRES_URL'          = 'postgres-url'
  'PGCRYPTO_ENVELOPE_KEY' = 'pgcrypto-envelope-key'
}
$secretEnv = [ordered] @{}
foreach ($entry in $secretSuffix.GetEnumerator()) {
  $secretEnv[$entry.Key] = "$SecretPrefix$($entry.Value)"
}

# Phase 8 — optional vendor app credential bundles. Each entry is wired
# into Cloud Run --set-secrets ONLY when the matching env var is
# present in the local secrets file. Absent bundles surface as warn-
# disabled vendors at runtime, and the worker dead-letters claimed
# jobs for those vendors with a clean reason instead of stack-traced
# StateErrors. Mirrors the staging proxy deploy script pattern; the
# secret names are the same so a single rotation can sync both.
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
}
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
  if ($optionalSecretEnv.Count -gt 0) {
    Write-Host 'Optional vendor app credential bundles surfaced locally (will sync):'
    foreach ($entry in $optionalSecretEnv.GetEnumerator()) {
      Write-Host (" - {0} -> {1}" -f $entry.Key, $entry.Value)
    }
  }
  if ($optionalSecretSkipped.Count -gt 0) {
    Write-Host 'Optional vendor app credential bundles skipped (warn-disabled at runtime):'
    foreach ($name in $optionalSecretSkipped) {
      Write-Host " - $name"
    }
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
  Write-Host (" {0} run jobs deploy {1} --project {2} --region {3} --service-account {4} --image <image> --set-secrets <name=secret:latest,...> --vpc-connector {5} --vpc-egress {6} --quiet" -f $gcloud, $JobName, $Project, $Region, $ServiceAccount, $VpcConnector, $VpcEgress)
  Write-Host (" {0} scheduler jobs describe {1} --project {2} --location {3}" -f $gcloud, $SchedulerName, $Project, $SchedulerLocation)
  Write-Host (" {0} scheduler jobs create http {1} --project {2} --location {3} --schedule '{4}' --time-zone '{5}' --uri https://{6}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/{2}/jobs/{7}:run --http-method POST --oauth-service-account-email {8} --attempt-deadline 600s" -f $gcloud, $SchedulerName, $Project, $SchedulerLocation, $ScheduleCron, $ScheduleTimeZone, $Region, $JobName, $ServiceAccount)
  Write-Host ''
  Write-Host 'Preflight complete. Re-run without -Preflight to apply (after human approval).'
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
  # Optional vendor app credentials: only sync entries the local
  # secrets file actually surfaced. Skipped entries already logged via
  # $optionalSecretSkipped.
  foreach ($entry in $optionalSecretEnv.GetEnumerator()) {
    Sync-SecretManagerSecret `
      -SecretName $entry.Value `
      -Value ([Environment]::GetEnvironmentVariable($entry.Key))
  }
}

$secretAssignments = (
  ($secretEnv.GetEnumerator() + $optionalSecretEnv.GetEnumerator()) |
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
  # The minute-level firing uses `runOnce`, not `daemon`. The image's
  # Dockerfile sets ENTRYPOINT ["/app/first_connect_backfill_worker"]
  # and CMD ["daemon"] for local dev; we override with --args to pin
  # production to the bounded one-tick mode (see README.md).
  #
  # --vpc-connector + --vpc-egress all-traffic route the Job's
  # outbound traffic through the staging static-IP egress so the
  # Azure Postgres firewall rule already allow-listing the audit
  # anchor admits this Job too. Same connector the audit_anchor +
  # staging proxy use; reusing it keeps the firewall a single line.
  & $gcloud run jobs $jobVerb $JobName `
    --project $Project `
    --region $Region `
    --service-account $ServiceAccount `
    --image $Image `
    --command /app/first_connect_backfill_worker `
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
foreach ($name in $optionalSecretEnv.Keys) {
  Write-Host " - $name (Secret Manager backed, optional)"
}
foreach ($name in $optionalSecretSkipped) {
  Write-Host " - $name (skipped — vendor will be warn-disabled at runtime)"
}
Write-Host ' - Adapter factory wiring: now backed by the binder builder (PR #268 + this slice).'
