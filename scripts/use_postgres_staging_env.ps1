# Phase 11a.11c.5 - Postgres staging env loader (names only).
#
# Replaces scripts/use_supabase_staging_env.ps1. Helper for a developer
# to source POSTGRES_URL and POSTGRES_ADMIN_URL into the current shell
# from the unified local secret store.
#
# Hard rules:
#   * This script does NOT read .env.local, .env.local.example, or
#     any other repo file for values. The values must come from a
#     local secret store (1Password CLI, Azure Key Vault CLI, or a
#     shell profile fragment outside the repo).
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
#   1. Keep local secrets in `$HOME\.forge_flow\forge_flow.secrets.ps1`.
#      That file lives outside the repo and is the ONLY plain-text env
#      loader for provider, Postgres, and Firebase local secrets.
#   2. Optionally point `FORGE_FLOW_STAGING_ENV_FILE` at a different
#      local secret loader. If unset, this script defaults to the
#      unified Forge Flow path.
#   3. Dot-source this script; it sources the operator's file and
#      reports the env names that became available.

$ErrorActionPreference = 'Stop'

$envFile = [Environment]::GetEnvironmentVariable('FORGE_FLOW_STAGING_ENV_FILE')
if ([string]::IsNullOrWhiteSpace($envFile)) {
  $envFile = Join-Path $HOME '.forge_flow\forge_flow.secrets.ps1'
}

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
