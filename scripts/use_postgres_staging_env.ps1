# Phase 11a.11c.5 - Postgres staging env loader (names only).
#
# Replaces scripts/use_supabase_staging_env.ps1. Helper for a developer
# to source POSTGRES_URL and POSTGRES_ADMIN_URL into the current shell
# from their local secret store.
#
# Hard rules:
#   * This script does NOT read .env.local, .env.local.example, or
#     any other repo file for values. The values must come from a
#     local secret store (1Password CLI, Azure Key Vault CLI, or a
#     gitignored shell profile fragment outside the repo).
#   * This script does NOT echo secret values. It only confirms which
#     env names ended up exposed in the calling shell.
#   * Sourcing pattern (PowerShell): dot-source so the assignments
#     survive in the parent session:
#         . scripts/use_postgres_staging_env.ps1
#   * Failure paths use `return`, not `exit`. A dot-sourced script
#     that calls `exit` would terminate the caller's interactive
#     PowerShell session; `return` exits this script's scope only.
#
# Wiring path (operator implements once, locally):
#   1. Generate a non-repo file (e.g. `~\.forge_flow.staging.ps1`)
#      that sets `$env:POSTGRES_URL = '...'` and
#      `$env:POSTGRES_ADMIN_URL = '...'`. That file lives outside the
#      repo and is the ONLY place the values appear in plain text.
#   2. Point `FORGE_FLOW_STAGING_ENV_FILE` at it (export it from your
#      shell profile so it persists across sessions).
#   3. Dot-source this script; it sources the operator's file and
#      reports the env names that became available.

$ErrorActionPreference = 'Stop'

$envFile = [Environment]::GetEnvironmentVariable('FORGE_FLOW_STAGING_ENV_FILE')

if ([string]::IsNullOrWhiteSpace($envFile)) {
  Write-Warning 'FORGE_FLOW_STAGING_ENV_FILE: MISSING'
  Write-Host 'Set it to the absolute path of your local non-repo env file before sourcing this script.'
  return
}

if (-not (Test-Path -LiteralPath $envFile)) {
  Write-Warning "FORGE_FLOW_STAGING_ENV_FILE points at a path that does not exist: $envFile"
  Write-Host 'Create the file in your local secret store and retry.'
  return
}

# Dot-source the operator's local env file so its `$env:...` assignments
# land in the caller's session. The file must do its own assignments.
# This script never parses values out of it.
. $envFile

# Report names only. Never values.
foreach ($name in 'POSTGRES_URL', 'POSTGRES_ADMIN_URL') {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    Write-Host "${name}: MISSING after sourcing $envFile"
  } else {
    Write-Host "${name}: PRESENT (name only - value not inspected)"
  }
}
