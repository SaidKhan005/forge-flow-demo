# Phase 11a.11c.6 - Azure Staging Apply Result

## Current Update (2026-04-26)

Status is now **accepted for 11a database infrastructure, with staging
limitations**. The older PARTIAL wording below is retained as the original
first-pass report: B1ms staging still has 7-day backups and no built-in
PgBouncer, but Production1 closes those production-only gaps. See
`phase_11a_production1_provisioning_result.md`.

Follow-up work after the first staging report applied the Contextual
Retrieval / cost-telemetry migration, loaded the staging corpus, ran Voyage
embeddings, applied AGE projection/index artifacts, ran the AGE benchmark,
evaluated DiskANN vs HNSW at the current tiny corpus size, registered
pg_partman maintenance, and passed the RLS-leading-column audit. Current
staging live-load status is recorded in
`phase_11a_11e_staging_live_load_result.md`.

**Original first-pass status:** PARTIAL. Azure staging was live and useful
for downstream work, but the first-pass report still had open gaps:
production provisioning, the AGE benchmark,
DiskANN-vs-HNSW, Contextual Retrieval / cost-telemetry schema, and
the RLS/index audits were still out at the time. Those gaps are now
closed or explicitly resolved in the follow-up closure section below.

**Generated:** 2026-04-26.

## Azure Resources

- Subscription: `Azure subscription 1`
- Resource group: `forge-flow-staging-rg`
- Region: `Canada Central`
- Server: `forge-flow-staging-pg`
- FQDN: `forge-flow-staging-pg.postgres.database.azure.com`
- PostgreSQL: `16.13`
- SKU: `Standard_B1ms`
- Database: `forgeflow`

The local connection file is outside the repo at
`$HOME\.forge_flow\forge_flow.secrets.ps1`. It sets `POSTGRES_URL` and
`POSTGRES_ADMIN_URL` and must not be committed or pasted into chat.

## Server Parameters

- `azure.extensions`:
  `age,vector,pg_diskann,pg_cron,pg_partman,pg_stat_statements,pgcrypto`
- `shared_preload_libraries`:
  `age,pg_cron,pg_stat_statements`
- Restart applied; no pending restart for `shared_preload_libraries`.

`pgmq` was planned but is not exposed in this server's
`azure.extensions` allowlist. The queue-provider choice is now locked:
in-DB queues use `FOR UPDATE SKIP LOCKED`; HTTP-delivery queues use
Cloud Tasks.

## Extension Verification

Installed in `forgeflow`:

- `age 1.6.0`
- `vector 0.8.2`
- `pg_diskann 0.6.4`
- `pg_partman 5.3.1`
- `pg_stat_statements 1.10`
- `pgcrypto 1.3`

Installed in `postgres`:

- `pg_cron 1.6`

Smoke checks passed:

- pgvector cosine distance query returned a finite value.
- AGE Cypher create/return/drop smoke graph succeeded.

## Schema Apply

Applied all `db/migrations/*.sql` in order:

- `202604250000_advisor_roles.sql`
- `202604250001_advisor_corpus_storage_schema.sql`
- `202604250002_advisor_embedding_contract.sql`
- `202604250003_advisor_vector_search.sql`
- `202604250004_advisor_proxy_usage_counters.sql`
- `202604250005_advisor_cloud_foundation.sql`

Verification showed:

- `service_role` and `authenticated` roles exist.
- All sixteen advisor/cloud-foundation tables are present with RLS enabled.
- `advisor_source_chunks.embedding` is `vector(1024)`.

## Gaps Discovered Live (2026-04-26)

These two gaps were real on first-pass staging and had to be closed before
production opened. Production1 now closes them with General Purpose
`Standard_D2ds_v5`, 35-day backup retention, and a verified PgBouncer
endpoint. Staging remains intentionally cheaper and therefore does not
test pooling behavior.

### Backup retention: 7 days on staging vs 35 days production target

Staging backups retain 7 days (Burstable B1ms default). Production
must be configured with **35-day point-in-time recovery** before any
operator data lands. Tracked as a pre-production checklist item;
production provisioning will set `--backup-retention 35`.

### PgBouncer: unavailable on Burstable B1ms

Azure's built-in PgBouncer transaction-mode pooling is gated to
General Purpose and Memory Optimized tiers â€” Burstable B1ms does not
expose it. Staging therefore skips pooling entirely. This means:

- Staging is not a faithful pooling-behavior rehearsal for the proxy.
- Production provisioning **must** select General Purpose
  (`Standard_D2ds_v5` or higher) so built-in PgBouncer is available.
  This is now an explicit production-tier constraint, not a
  preference.

## Original First-Pass Remaining Work

This list is retained as first-pass history. Every item below is closed or
explicitly resolved in "Follow-Up Closure".

- Production Azure Postgres provisioning was not done at first pass.
- AGE projection artifacts were not applied yet.
- AGE benchmark at 1K/10K synthetic operator scale was not done.
- DiskANN-vs-HNSW benchmark was not done.
- Contextual Retrieval / cost-telemetry schema additions were not done.
- RLS/index performance audits were not done.

## Follow-Up Closure (2026-04-26)

- Production1 provisioning is done on General Purpose `Standard_D2ds_v5`
  with 35-day backup retention recorded from the provisioning run.
- Production PgBouncer endpoint smoke passed (`select 1` through port 6432).
- Contextual Retrieval / cost-telemetry schema additions are applied to
  staging and production.
- AGE projection and AGE index strategy are applied to staging.
- AGE smoke traversal passed on staging.
- AGE benchmark passed the 500 ms / 1000 ms p95 gates on staging.
- DiskANN availability and candidate-index creation were verified on staging.
  Launch decision: keep HNSW as authoritative until the corpus is large enough
  for a meaningful DiskANN benchmark.
- RLS-leading-column audit reports 0 violations on staging and production
  after `202604250007_advisor_rls_index_hardening.sql`.
- pg_partman is registered for `public.usage_logs` and the hourly pg_cron
  maintenance job is active on staging and production.

Anthropic credits were later added; Claude smoke and Contextual Retrieval
context generation are now accepted in
`phase_11a_11e_staging_live_load_result.md`.
