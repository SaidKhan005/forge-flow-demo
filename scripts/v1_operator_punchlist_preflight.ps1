# V1 launch operator punchlist read-only preflight.
#
# This script checks local/tooling readiness for the operator-owned V1 launch
# punchlist items. It never prints secret values and does not mutate cloud,
# DNS, Firebase, provider, or database state.

param(
  [string] $SecretsFile = (Join-Path $HOME '.forge_flow\secrets\runtime\forge_flow.secrets.ps1'),
  [switch] $SkipSecrets,
  [switch] $IncludeDns,
  [switch] $IncludeCloudReadOnly
)

$ErrorActionPreference = 'Stop'

$script:Blocked = 0
$script:Warnings = 0

function Add-Result([string] $Status, [string] $Name, [string] $Detail = '') {
  $prefix = "[$Status] $Name"
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $prefix = "$prefix - $Detail"
  }
  Write-Host $prefix
  if ($Status -eq 'BLOCKED') {
    $script:Blocked += 1
  } elseif ($Status -eq 'WARN') {
    $script:Warnings += 1
  }
}

function Test-Tool([string] $Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $cmd) {
    Add-Result 'BLOCKED' "tool:$Name" 'not found on PATH'
  } else {
    Add-Result 'PASS' "tool:$Name" $cmd.Source
  }
}

function Test-RepoFile([string] $Path) {
  if (Test-Path -LiteralPath $Path) {
    Add-Result 'PASS' "file:$Path"
  } else {
    Add-Result 'BLOCKED' "file:$Path" 'missing'
  }
}

function Test-JsonProjectId([string] $Path, [string] $ExpectedProjectId) {
  if (-not (Test-Path -LiteralPath $Path)) {
    Add-Result 'BLOCKED' "firebase-config:$Path" 'missing'
    return
  }
  try {
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $actualProjectId = [string] $config.projectId
    if ([string]::IsNullOrWhiteSpace($actualProjectId)) {
      $actualProjectId = [string] $config.project_info.project_id
    }
    if ($actualProjectId -eq $ExpectedProjectId) {
      Add-Result 'PASS' "firebase-config:$Path" $ExpectedProjectId
    } else {
      Add-Result 'BLOCKED' "firebase-config:$Path" "expected $ExpectedProjectId, got $actualProjectId"
    }
  } catch {
    Add-Result 'BLOCKED' "firebase-config:$Path" $_.Exception.Message
  }
}

function Test-TextContains([string] $Path, [string] $Pattern, [string] $Name) {
  if (-not (Test-Path -LiteralPath $Path)) {
    Add-Result 'BLOCKED' $Name "missing: $Path"
    return
  }
  $text = Get-Content -LiteralPath $Path -Raw
  if ($text.Contains($Pattern)) {
    Add-Result 'PASS' $Name
  } else {
    Add-Result 'BLOCKED' $Name "missing expected text: $Pattern"
  }
}

function Test-EnvAny([string] $Name, [string[]] $EnvNames) {
  $present = @()
  foreach ($envName in $EnvNames) {
    $value = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $present += $envName
    }
  }
  if ($present.Count -gt 0) {
    Add-Result 'PASS' "env:$Name" ("present: {0}" -f ($present -join ', '))
  } else {
    Add-Result 'BLOCKED' "env:$Name" ("missing one of: {0}" -f ($EnvNames -join ', '))
  }
}

function Invoke-ReadOnly([string] $Name, [scriptblock] $Command) {
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $global:LASTEXITCODE = 0
    $output = & $Command 2>&1
    $success = $?
    $exitCode = $global:LASTEXITCODE
    if (-not $success) {
      Add-Result 'WARN' $Name 'command reported failure'
    } elseif ($exitCode -ne $null -and $exitCode -ne 0) {
      Add-Result 'WARN' $Name "exit $exitCode"
    } else {
      Add-Result 'PASS' $Name
    }
    if ($output) {
      $output | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
    }
  } catch {
    Add-Result 'WARN' $Name $_.Exception.Message
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
  Write-Host 'V1 operator punchlist preflight (read-only)'
  Write-Host "Repo: $repoRoot"

  Test-Tool 'gcloud'
  Test-Tool 'firebase'
  Test-Tool 'az'
  Test-Tool 'psql'

  if ($SkipSecrets) {
    Add-Result 'INFO' 'secrets' 'skipped by -SkipSecrets'
  } elseif (Test-Path -LiteralPath $SecretsFile) {
    try {
      . $SecretsFile
      Add-Result 'PASS' 'secrets-file' 'loaded; values not printed'
    } catch {
      Add-Result 'BLOCKED' 'secrets-file' $_.Exception.Message
    }
  } else {
    Add-Result 'BLOCKED' 'secrets-file' "missing: $SecretsFile"
  }

  Test-RepoFile 'docs\_execution\2026-05-05_v1_launch_punchlist.md'
  Test-RepoFile 'docs\phases\phase_production_cutover\production1_staging_parity_baseline_2026-05-03.md'
  Test-RepoFile 'runbooks\phase_9_production1_migration_apply_runbook.md'
  Test-RepoFile 'docs\phases\phase_9_8\phase_9_8_inbound_vendor_tcs_draft.md'
  Test-RepoFile 'docs\phases\phase_9_8\phase_9_8_email_provider_slice.md'
  Test-RepoFile 'docs\phases\phase_8_live_rollout\phase_8_live_rollout_plan.md'
  Test-RepoFile 'runbooks\v1_operator_launch_punchlist_runbook.md'
  Test-RepoFile 'scripts\v1_operator_punchlist_preflight.ps1'
  Test-RepoFile 'android\app\src\forgeflowProd1\google-services.json'
  Test-RepoFile 'android\app\src\barrioProd1\google-services.json'
  Test-RepoFile 'ios\Runner\Firebase\GoogleService-Info-ForgeFlow-Production1.plist'
  Test-RepoFile 'ios\Runner\Firebase\GoogleService-Info-Barrio-Production1.plist'
  Test-RepoFile 'web\firebase-config.production1.js'

  Test-JsonProjectId 'web\firebase-config.production1.js' 'forge-flow-production1'
  Test-JsonProjectId 'android\app\src\forgeflowProd1\google-services.json' 'forge-flow-production1'
  Test-JsonProjectId 'android\app\src\barrioProd1\google-services.json' 'forge-flow-production1'
  Test-TextContains `
    'ios\Runner\Firebase\GoogleService-Info-ForgeFlow-Production1.plist' `
    '<string>forge-flow-production1</string>' `
    'ios:forgeflow-production1-plist-project'
  Test-TextContains `
    'ios\Runner\Firebase\GoogleService-Info-Barrio-Production1.plist' `
    '<string>forge-flow-production1</string>' `
    'ios:barrio-production1-plist-project'

  if ($env:FIREBASE_CONFIG_ENVIRONMENT -in @('production1', 'prod1')) {
    Add-Result 'PASS' 'ios-production-build-env' $env:FIREBASE_CONFIG_ENVIRONMENT
  } else {
    Add-Result 'INFO' 'ios-production-build-env' 'set FIREBASE_CONFIG_ENVIRONMENT=production1 before iOS production archive'
  }

  Test-RepoFile 'db\migrations\202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql'
  Test-RepoFile 'db\migrations\202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql'

  foreach ($vendorPath in @(
      'docs\integrations\lightspeed_lsk\partnership_status.md',
      'docs\integrations\lightspeed_lsk\live_verification_checklist.md',
      'docs\integrations\libro\partnership_status.md',
      'docs\integrations\libro\live_verification_checklist.md',
      'docs\integrations\quickbooks_time\partnership_status.md',
      'docs\integrations\quickbooks_time\live_verification_checklist.md'
    )) {
    Test-RepoFile $vendorPath
  }

  if (Test-Path -LiteralPath '.firebaserc') {
    try {
      $firebaseRc = Get-Content -LiteralPath '.firebaserc' -Raw | ConvertFrom-Json
      if ($firebaseRc.projects.production -eq 'forge-flow-production1') {
        Add-Result 'PASS' '.firebaserc production alias' 'forge-flow-production1'
      } else {
        Add-Result 'WARN' '.firebaserc production alias' 'not yet present; expected after production Firebase apps/configs are reviewed'
      }
    } catch {
      Add-Result 'WARN' '.firebaserc parse' $_.Exception.Message
    }
  } else {
    Add-Result 'WARN' '.firebaserc' 'missing'
  }

  Test-EnvAny 'production-postgres-admin-url' @(
    'POSTGRES_PRODUCTION_ADMIN_URL',
    'POSTGRES_ADMIN_URL'
  )
  Test-EnvAny 'operator-web-proxy-base-uri' @(
    'FORGE_FLOW_OPERATOR_WEB_PROXY_BASE_URI',
    'FORGE_FLOW_PROXY_BASE_URI_PROD1',
    'FORGE_FLOW_PROXY_BASE_URI'
  )
  Test-EnvAny 'sendgrid-production-key' @(
    'SENDGRID_API_KEY'
  )
  Test-EnvAny 'email-from-address' @(
    'EMAIL_FROM_ADDRESS'
  )

  if ($IncludeDns) {
    foreach ($hostName in @('app.forgeflow.app', 'mail.forgeflow.app')) {
      Invoke-ReadOnly "dns:A:$hostName" {
        Resolve-DnsName -Name $hostName -Type A -ErrorAction Stop |
          Select-Object Name, Type, IPAddress |
          Format-Table -AutoSize | Out-String
      }
    }
    foreach ($txtName in @('mail.forgeflow.app', '_dmarc.forgeflow.app')) {
      Invoke-ReadOnly "dns:TXT:$txtName" {
        Resolve-DnsName -Name $txtName -Type TXT -ErrorAction Stop |
          Select-Object Name, Type, Strings |
          Format-Table -AutoSize | Out-String
      }
    }
  } else {
    Add-Result 'INFO' 'dns' 'skipped; pass -IncludeDns for read-only DNS checks'
  }

  if ($IncludeCloudReadOnly) {
    Invoke-ReadOnly 'gcloud:production1-project' {
      gcloud projects describe forge-flow-production1 --format='table(projectId,lifecycleState,projectNumber)' --quiet
    }
    Invoke-ReadOnly 'firebase:production1-apps' {
      firebase apps:list --project forge-flow-production1
    }
    Invoke-ReadOnly 'gcloud:production1-cloud-run-services' {
      gcloud run services list --project forge-flow-production1 --region northamerica-northeast2 --format='table(metadata.name,status.url)' --quiet
    }
    Invoke-ReadOnly 'gcloud:production-secret-names' {
      gcloud secrets list --project forge-flow-production1 --filter='name~forge-flow-production-' --format='table(name)' --quiet
    }
  } else {
    Add-Result 'INFO' 'cloud-read-only' 'skipped; pass -IncludeCloudReadOnly to query GCP/Firebase state'
  }

  Write-Host ''
  if ($script:Blocked -gt 0) {
    Write-Host "Result: BLOCKED ($script:Blocked blocker(s), $script:Warnings warning(s))."
    exit 1
  }
  if ($script:Warnings -gt 0) {
    Write-Host "Result: WARN ($script:Warnings warning(s), no blockers)."
    exit 0
  }
  Write-Host 'Result: PASS.'
} finally {
  Pop-Location
}
