# Phase 11a.11c.5 - Postgres staging preflight (read-only, name-only).
#
# Replaces scripts/supabase_staging_preflight.ps1. Reports whether the
# env names required for a staging Postgres apply are exported. Never
# echoes a value, never connects to a DB, never runs a migration.
#
# Exit codes:
#   0 - every required env name is present
#   1 - at least one required env name is missing
#
# What this script does NOT do:
#   * Read .env.local / .env.local.example
#   * Print env values
#   * Connect to Postgres
#   * Run any migration
#   * Verify the target is staging (the operator owns that decision;
#     this script is a gate, not a guarantor)

$ErrorActionPreference = 'Stop'

$required = @('POSTGRES_URL', 'POSTGRES_ADMIN_URL')

$missing = @()
foreach ($name in $required) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    Write-Host "${name}: MISSING"
    $missing += $name
  } else {
    Write-Host "${name}: PRESENT (name only - value not inspected)"
  }
}

Write-Host '---'
if ($missing.Count -gt 0) {
  Write-Host "BLOCKED - $($missing.Count) required env name(s) missing: $($missing -join ', ')"
  Write-Host 'Run scripts/use_postgres_staging_env.ps1 first to source them from your local secret store.'
  exit 1
}

Write-Host 'OK - all required env names present. Staging-vs-production confirmation is the operator''s next step.'
exit 0
