# Phase 11a Production1 Provisioning Result

Date: 2026-04-26
Status: PRODUCTION SHELL PROVISIONED; SCHEMA VERIFIED; NO OPERATOR DATA LOADED

## Summary

Production1 exists as an Azure Postgres Flexible Server shell with the advisor
schema applied and verified. It is intentionally empty: no corpus chunks,
embeddings, operator records, or production user data were loaded.

No secret values are recorded here.

## Azure Resource

- Resource group: `forge-flow-production1-rg`
- Server: `forge-flow-production1-pg`
- Region: Canada Central
- PostgreSQL: 16
- SKU/tier: `Standard_D2ds_v5`, General Purpose
- Database: `forgeflow`
- Backup retention: 35 days
- Local non-repo env file: `C:\Users\saidu\.forge_flow.production1.ps1`

Production uses General Purpose because Azure's built-in PgBouncer is not
available on Burstable staging tier.

## Extensions

Verified in `forgeflow`:

- `age 1.6.0`
- `vector 0.8.2`
- `pg_diskann 0.6.4`
- `pg_partman 5.3.1`
- `pg_stat_statements 1.10`
- `pgcrypto 1.3`

Verified in `postgres`:

- `pg_cron 1.6`

`pgmq` is not required and is not on the Azure allowlist. The queue decision
remains `FOR UPDATE SKIP LOCKED` for in-DB queues and Cloud Tasks for HTTP
delivery queues.

## Schema Verification

Applied all current `db/migrations/*.sql` through:

- `202604250007_advisor_rls_index_hardening.sql`

Read-only verification:

- `prod_select_1=1`
- `prod_pgbouncer_select_1=1`
- RLS-enabled advisor/cloud relations: 16
- `advisor_source_chunks.embedding`: `vector(1024)`
- `advisor_source_chunks` rows: 0
- RLS-leading-column index audit: 0 violations
- `pg_partman` config rows for `public.usage_logs`: 1
- Active `pg_cron` maintenance job targeting `forgeflow`: 1

Verification artifact:
`build/advisor_corpus/production_schema_verification.txt`

## Caveats

- The final Codex shell did not have `az` on PATH, so the last sanity pass
  rechecked the live database endpoints with `psql` rather than re-querying
  Azure resource metadata.
- The generated production database password was reset after an earlier local
  env-file syntax issue exposed part of the first generated value in a parse
  error. The current env file loads without printing values.
- This is a paid Azure resource.

## Not Done

- No production corpus load.
- No production embeddings.
- No production AGE projection data.
- No Cloud Run/proxy production traffic.
- No operator/customer data.

