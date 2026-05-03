# Deploy the Forge Flow audit_anchor daily Cloud Run Job + Cloud Scheduler.
#
# Phase 9.0Σ.f / B43. Pairs with:
#   * infrastructure/cloud_run/audit_anchor_job.yaml — job + scheduler contract.
#   * runbooks/audit_chain_verify_runbook.md — operational procedure, IAM,
#     Secret Manager mapping, rotation pattern.
#   * tool/audit_anchor/main.dart — CLI entry point.
#
# Posture (matches scripts/deploy_staging_proxy.ps1):
#   * Loads $HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1; never prints secret
#     VALUES, only secret env NAMES.
#   * CLAUDE.md "no live Azure mutation in repo" applies — Azure Blob
#     container creation, retention policy locking, and `audit_anchor_role`
#     Postgres role grants require human approval before this script ever
#     runs against a real project.
#   * `-Preflight` switch performs name-only checks and prints the gcloud
#     commands that *would* run; it never mutates Cloud Run, Secret
#     Manager, or Cloud Scheduler.
#   * Idempotent: secret create/update, job deploy, and scheduler create
#     all describe-first / update-fallback so re-running the script is
#     safe. Anchor writes themselves are idempotent in the orchestrator.
#
# Required env names (loaded from the secrets file, NEVER printed):
#   - POSTGRES_URL
#   - AZURE_BLOB_AUDIT_CONTAINER
#   - AZURE_BLOB_AUDIT_ENDPOINT
#   - AZURE_AD_TENANT_ID  (added 9.0Σ.f live-deploy slice — selects the
#                          live AzureBlobAuditAnchorBlobClient over the
#                          fail-closed scaffold rejecter)
#   - AZURE_AD_CLIENT_ID  (added 9.0Σ.f live-deploy slice — federated
#                          credential's app-registration client id)
#
# Secret Manager mapping (name-only convention; values come from env):
#   - POSTGRES_URL                 -> forge-flow-staging-postgres-url
#                                     (reused from deploy_staging_proxy)
#   - AZURE_BLOB_AUDIT_CONTAINER   -> forge-flow-staging-azure-blob-audit-container
#   - AZURE_BLOB_AUDIT_ENDPOINT    -> forge-flow-staging-azure-blob-audit-endpoint
#   - AZURE_AD_TENANT_ID           -> forge-flow-staging-azure-ad-tenant-id
#   - AZURE_AD_CLIENT_ID           -> forge-flow-staging-azure-ad-client-id
#
# Schedule: `55 23 * * *` UTC (daily at 23:55 UTC). Timezone pinned to
# `Etc/UTC` in Cloud Scheduler so DST cannot shift the firing window.
#
# Human approval is required before this script's mutating path runs
# against a real project. Run with `-Preflight` first.

param(
  [string] $Project = 'forge-flow-staging',
  [string] $Region = 'northamerica-northeast2',
  # Cloud Scheduler is not available in northamerica-northeast2 today; keep
  # the trigger in northamerica-northeast1 while the Cloud Run Job remains
  # in $Region.
  [string] $SchedulerLocation = 'northamerica-northeast1',
  [string] $JobName = 'forge-flow-audit-anchor',
  [string] $SchedulerName = 'forge-flow-audit-anchor-daily',
  [string] $ServiceAccount = 'forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com',
  [string] $Image = '',
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  # Secret Manager name prefix. Convention: `forge-flow-<env>-`. Defaults
  # to staging because the proxy already publishes
  # `forge-flow-staging-postgres-url` and we want the job + proxy to
  # share that secret. Override to `forge-flow-production-` (or similar)
  # when targeting production. The trailing dash is required.
  [string] $SecretPrefix = 'forge-flow-staging-',
  # VPC connector name in $Project / $Region. The Job egresses through
  # this connector + the project's NAT router, surfacing as a fixed IP
  # that the Azure Postgres firewall already allowlists. Default reuses
  # the staging proxy's connector — do not invent a new one without a
  # matching firewall rule on the Postgres side.
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

# Schedule contract. Locked at B43: daily 23:55 UTC. Update both this
# constant AND infrastructure/cloud_run/audit_anchor_job.yaml +
# runbooks/audit_chain_verify_runbook.md if the schedule ever changes.
$ScheduleCron = '55 23 * * *'
$ScheduleTimeZone = 'Etc/UTC'

# Required env NAMES (NEVER values). The runbook + audit_anchor.dart
# `AuditAnchorEnvNames.required` are the source of truth for the first
# three entries; `AZURE_AD_*` are required at the *deploy* layer (the
# tool itself treats them as optional so non-prod runs can default to
# the scaffold rejecter, but a Cloud Run deploy without them would
# silently never hit live Azure).
$requiredEnv = @(
  'POSTGRES_URL',
  'AZURE_BLOB_AUDIT_CONTAINER',
  'AZURE_BLOB_AUDIT_ENDPOINT',
  'AZURE_AD_TENANT_ID',
  'AZURE_AD_CLIENT_ID'
)

if (-not $SecretPrefix.EndsWith('-')) {
  Write-Host "BLOCKED: -SecretPrefix '$SecretPrefix' must end with '-'."
  exit 1
}

# Secret Manager mapping. Convention: forge-flow-<env>-<lowercase-env-name>
# with `_` replaced by `-`. The proxy already publishes
# `forge-flow-staging-postgres-url`, so this script reuses that secret
# name to avoid a divergent connection string between job + proxy.
# Suffixes are stable; the prefix toggles per environment via
# `-SecretPrefix`.
$secretSuffix = [ordered] @{
  'POSTGRES_URL'                = 'postgres-url'
  'AZURE_BLOB_AUDIT_CONTAINER'  = 'azure-blob-audit-container'
  'AZURE_BLOB_AUDIT_ENDPOINT'   = 'azure-blob-audit-endpoint'
  'AZURE_AD_TENANT_ID'          = 'azure-ad-tenant-id'
  'AZURE_AD_CLIENT_ID'          = 'azure-ad-client-id'
}
$secretEnv = [ordered] @{}
foreach ($entry in $secretSuffix.GetEnumerator()) {
  $secretEnv[$entry.Key] = "$SecretPrefix$($entry.Value)"
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
  Write-Host (" {0} run jobs deploy {1} --project {2} --region {3} --service-account {4} --image <image> --set-secrets <name=secret:latest,...> --vpc-connector {5} --vpc-egress {6} --quiet" -f $gcloud, $JobName, $Project, $Region, $ServiceAccount, $VpcConnector, $VpcEgress)
  Write-Host (" {0} scheduler jobs describe {1} --project {2} --location {3}" -f $gcloud, $SchedulerName, $Project, $SchedulerLocation)
  Write-Host (" {0} scheduler jobs create http {1} --project {2} --location {3} --schedule '{4}' --time-zone '{5}' --uri https://{6}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/{2}/jobs/{7}:run --http-method POST --oauth-service-account-email {8} --attempt-deadline 3600s" -f $gcloud, $SchedulerName, $Project, $SchedulerLocation, $ScheduleCron, $ScheduleTimeZone, $Region, $JobName, $ServiceAccount)
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
  # The daily firing uses `sweep`, not `anchor`. The image's Dockerfile
  # (`tool/audit_anchor/Dockerfile`) sets `ENTRYPOINT ["/app/audit_anchor"]`
  # and `CMD ["sweep"]` so the deployed command shape takes no
  # `--operator-id` argument and no Dart toolchain is needed at runtime.
  # Do NOT set `--command` / `--args` — that would override the image's
  # entrypoint with `dart run …`, which fails on the distroless runtime
  # (no Dart binary present).
  #
  # `--vpc-connector` + `--vpc-egress all-traffic` route the Job's
  # outbound traffic through the staging static-IP egress
  # (`34.130.85.86`) so the Azure Postgres firewall rule
  # `AllowGcpCloudRunStaticEgress` on `forge-flow-staging-pg` admits
  # the connection. Same connector the staging proxy uses; reusing it
  # keeps the firewall allowlist a single line. See
  # `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  # 'Dev UX prerequisite — cross-cloud egress' for the full pattern.
  & $gcloud run jobs $jobVerb $JobName `
    --project $Project `
    --region $Region `
    --service-account $ServiceAccount `
    --image $Image `
    --set-secrets $secretAssignments `
    --vpc-connector $VpcConnector `
    --vpc-egress $VpcEgress `
    --max-retries 0 `
    --task-timeout 3600s `
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
    --attempt-deadline 3600s `
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
    --attempt-deadline 3600s `
    --quiet
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host 'Deployment complete. Name-only prerequisites available:'
Write-Host " - Cloud Run Job: $JobName"
Write-Host " - Cloud Scheduler: $SchedulerName ($ScheduleCron $ScheduleTimeZone)"
foreach ($name in $requiredEnv) {
  Write-Host " - $name (Secret Manager backed)"
}
Write-Host ' - audit_anchor_role Postgres role (out-of-band, see runbook)'
Write-Host ' - Azure Blob immutable container (out-of-band, see runbook)'
