# Phase 11a.11c.5 - Postgres staging setup runbook.
#
# Prints the next-step runbook for the Azure Database for PostgreSQL
# Flexible Server staging instance the advisor migrations target. This
# script does not call Azure, does not connect to any DB, and does not
# echo secret values.

$ErrorActionPreference = 'Stop'

Write-Host '=== Phase 11a.11c.5 Postgres staging setup runbook ==='
Write-Host ''
Write-Host '1. Provision the staging Azure Database for PostgreSQL Flexible Server'
Write-Host '   instance in Canada Central. Postgres 16. Production is a separate instance.'
Write-Host ''
Write-Host '2. Add the extension allowlist on the staging server.'
Write-Host '   Azure exposes `azure.extensions` as the server-parameter allowlist.'
Write-Host '   Current target entries:'
Write-Host '     age                  - graph traversal (advisor 7.57.4 / 11b)'
Write-Host '     vector               - pgvector embeddings (advisor 11a.6a / 11a.8)'
Write-Host '     pg_diskann           - DiskANN ANN index for embeddings'
Write-Host '     pg_cron              - scheduled jobs'
Write-Host '     pg_partman           - declarative partition maintenance'
Write-Host '     pg_stat_statements   - query telemetry'
Write-Host '     pgcrypto             - UUID + crypto helpers'
Write-Host ''
Write-Host '   Note: pgmq was planned, but it was not exposed in this server''s'
Write-Host '   azure.extensions allowlist during staging provisioning.'
Write-Host ''
Write-Host '3. shared_preload_libraries on the staging server must include:'
Write-Host '     age, pg_cron, pg_stat_statements'
Write-Host ''
Write-Host '4. Record connection strings into your unified local non-repo env file:'
Write-Host '     $HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1'
Write-Host '     POSTGRES_URL          - staging application-role connection string'
Write-Host '     POSTGRES_ADMIN_URL    - staging deployment-role connection string'
Write-Host ''
Write-Host '5. Source the env names into your shell:'
Write-Host '     . scripts/use_forge_flow_secrets.ps1'
Write-Host '   or, for staging Postgres only:'
Write-Host '     . scripts/use_postgres_staging_env.ps1'
Write-Host ''
Write-Host '6. Run the preflight to confirm exposure:'
Write-Host '     scripts/postgres_staging_preflight.ps1'
Write-Host ''
Write-Host '7. Apply migrations in order with `psql -v ON_ERROR_STOP=1` against'
Write-Host '   $env:POSTGRES_ADMIN_URL, starting with'
Write-Host '   db/migrations/202604250000_advisor_roles.sql and continuing'
# MIGRATION_CUTOFF_BEGIN
Write-Host '   through 202605050200_phase_10a_3_event_outbox_retention.sql.'
# MIGRATION_CUTOFF_END
Write-Host ''
Write-Host '   The cutoff line above is enforced by tool/migration_cutoff_lint.dart'
Write-Host '   in CI; bumping the cutoff to a newer file is a one-line edit but the'
Write-Host '   lint guarantees the runbook and db/migrations/ never silently drift.'
