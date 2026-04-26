# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-26
Status: Accepted - Azure/AGE live infrastructure sequence complete
Owner: Future advisor infrastructure lane

This is the compact active execution plan. Full pre-lean history is archived at
`docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`.

## Current Truth

- `11a` owns the backend substrate for the advisor: corpus ingestion,
  knowledge graph, vector search, rerank, proxy boundary, usage enforcement,
  and live cloud DB wiring.
- Local/repo scaffold through `11a.12c` is complete.
- Apache AGE is mandatory. The linked Supabase staging project cannot provide
  AGE, so the live Postgres host is migrating to Azure Database for PostgreSQL
  Flexible Server, Canada Central, PG 16.
- `11a.11c.4` completed the decision lock and docs lean-out.
- **Retrieval pattern locked 2026-04-26**: Modular Adaptive Agentic RAG.
  Haiku query classifier → Anthropic Contextual Retrieval (vector + BM25 +
  RRF + Voyage rerank) for methodology Q&A; AGE traversal for causal/
  multi-hop and Phase 12 workflows; SQL for personal metrics. AGE
  infrastructure live at `11a.11c.6`; advisor hot-path graph traversal
  lights up incrementally at `11b.2` and Phase 12. Detail in
  `phase_11a_decision_register.md` Architecture Lock + Retrieval Posture.
- **Five cost-discipline levers locked** (Hard Promise #9): prompt caching
  default-on, tier routing, response cache + Memorystore (deferred to
  `11b.1`), pre-computed summaries (deferred to `11b.1`), Anthropic Batch
  API (deferred to Phase 12.0).
- Last accepted infrastructure action: `11a.11e` staging live retrieval
  accepted end-to-end. Anthropic generated 233 chunk contexts, Voyage
  refreshed 233 context-enriched embeddings, vector/rerank smokes passed, and
  Claude answer smoke returned `end_turn`.
- Current blocker: none inside 11a. Production remains intentionally empty;
  production corpus/operator data load belongs to a later explicit cutover
  gate.

## Fetch Notes

For normal `11a` prompts, read this file plus the runtime/test files named by
the slice. Add `phase_11a_decision_register.md` only when the prompt needs
decision rationale, human setup choices, or parked future constraints.

Historical Supabase docs retained for traceability in
`docs/archive/phases/phase_11a/`:

- `phase_11a_11b_cloud_db_apply_readiness.md`
- `phase_11a_11c2_staging_apply_report.md`
- `phase_11a_11c3_staging_apply_report.md`
- `phase_11a_11c3_staging_apply_result.md`

Treat those as Supabase-historical after the Azure pivot.

## Goal

Build the backend substrate for the agentic advisor:

- founder-authored methodology and SOP corpus
- AGE knowledge graph with provenance
- pgvector candidate retrieval
- Voyage rerank
- Claude answer runtime readiness
- Cloud Run proxy boundary for all provider calls
- per-operator usage enforcement, caps, idempotency, and health checks

No operator-facing chat UI ships from 11a. Phase 11b owns that UX.

## Non-Negotiables

- No vendor/provider secrets in Flutter.
- Corpus content is Markdown only and founder-synthesized; no licensed
  third-party content.
- **AGE infrastructure must be live before `11b` opens** (revised 2026-04-26).
  Live traversal in advisor hot path lights up incrementally at `11b.2`
  (causal queries) and Phase 12 (workflow definitions + staff coaching
  relational queries). Advisor `11b` launch retrieval is Anthropic
  Contextual Retrieval.
- Per-operator scoping is designed in from day one with `(operator_id,
  location_id)`, RLS, and repository/proxy access. `staff_id` axis added
  in `11b.1` schema-foundation slice.
- The graph and corpus advise; they do not replace canonical operational facts,
  locked plans, target authority, or permission truth.
- Advisor posture is recommendation-only.
- **AI cost is metered by class** (Hard Promise #9): every retrieval +
  synthesis + workflow surface logs `query_class`, `cache_hit`,
  `llm_tier`, `model_used`, `batch_mode` in `usage_logs` and is
  meterable per `(operator_id, location_id, staff_id NULL,
  workflow_id NULL, usage_class)` in `usage_caps`.

## Completed Snapshot

- `11a.0-11a.7`: corpus manifest, materializer, Postgres schema/load prep,
  local load, Voyage embedding prep/execution.
- `11a.8`: vector metadata, HNSW cosine index, `advisor_search_chunks`.
- `11a.9`: fake-tested Voyage rerank seam.
- `11a.10a`: Cloud Run-ready proxy scaffold with auth/scope guard.
- `11a.10b`: usage guard, token/rate/monthly caps, fail-closed store seam,
  `/v1/usage-smoke`, usage migration.
- `11a.11a`: content-addressed chunks, active/inactive semantics, stale chunk
  deactivation including zero-current-chunk docs.
- `11a.11b`: Supabase readiness blocker capture, now historical.
- `11a.11c.1`: cloud foundation migration with identity/support tables,
  partitioned `usage_logs`, `usage_caps`, `proxy_requests`, `feature_flags`,
  `fx_rates`, RLS stubs, and composite ownership FKs.
- `11a.11c.2-3`: Supabase staging preflight/apply verification, now historical
  because AGE is unavailable there.
- `security.env.1`: `.env.local` private/ignored; examples sanitized.
- `11a.12a-c`: local-only corpus admin Settings preview scaffold, superseded
  for real admin UX by Phase 11A.
- `11a.11c.4`: lean tracker / phase-doc recontextualization and Azure decision
  lock.
- `11a.11c.5`: Supabase-to-Azure/Postgres code-only retarget accepted:
  migrations now live under `db/migrations`, generic Postgres role bootstrap
  exists, Supabase CLI assumptions are removed, and Postgres staging scripts +
  local AGE/pgvector dev scaffold are in place.
- `11a.11c.6` staging provision/apply partial accepted: Azure staging server
  `forge-flow-staging-pg` in Canada Central is live on PG 16, connection
  secrets live outside the repo at `$HOME\.forge_flow.staging.ps1`, AGE /
  pgvector / pg_diskann / pg_partman / pg_stat_statements / pgcrypto are
  installed in `forgeflow`, pg_cron is installed in `postgres`, all six
  `db/migrations` applied, RLS tables verified, pgvector smoke passed, and AGE
  Cypher smoke passed. `pgmq` is not exposed in this server's extension
  allowlist; the queue path is now locked to `FOR UPDATE SKIP LOCKED` for
  in-DB queues and Cloud Tasks for HTTP-delivery queues.
- `11a.11c.6` live-constraint doc sweep accepted: `pgmq` is removed from
  the required extension path, in-DB queues use `FOR UPDATE SKIP LOCKED`,
  HTTP-delivery queues use Cloud Tasks, and PgBouncer is tied to a General
  Purpose+ production tier.
- `11a.11c.6a`: local schema-hardening migration/tests accepted. Added
  `chunk_context`, `corpus_version`, BM25 `tsvector` + GIN index, usage
  telemetry rollup dimensions, pg_partman maintenance scaffold, and
  RLS-leading-index audit SQL. No live apply.
- `11a.11c.6b`: local AGE projection artifacts/tests accepted. Added AGE
  index strategy SQL, p95 benchmark harness, and DiskANN/HNSW decision harness
  without applying live indexes or running live benchmarks.
- `11a.11d`: local proxy counter / idempotency / health / cost-lever scaffold
  accepted. Added `/health` dependency-check seam, `/v1/advisor-smoke`
  idempotency/cap/provider scaffold, usage-log UPSERT SQL contract,
  prompt-cache block builder, tier routing, and meta-only logging guard.
  No live DB mutation or provider call.
- `11a.11c.6/11a.11e` live DB follow-up: staging has the corpus loaded
  (8 documents, 233 chunks), 233 ready Voyage embeddings, BM25 vectors
  populated, AGE projection/index strategy applied, AGE smoke traversal
  passing, vector/rerank smokes passing, AGE p95 benchmark passing, pg_partman
  + pg_cron maintenance active, and RLS-leading-column audit at 0 violations.
- `11a.production1`: Production1 Azure Postgres shell exists on General
  Purpose `Standard_D2ds_v5`, 35-day backup retention, built-in PgBouncer
  smoke passing, all migrations through
  `202604250007_advisor_rls_index_hardening.sql` applied, RLS audit at
  0 violations, and no operator/corpus data loaded.
- Anthropic Contextual Retrieval context generation and Claude answer-runtime
  smoke accepted after credits were added.

## Active Slice Contracts

### `11a.11c.5` - Repo Tooling Re-target To Azure

Status: Accepted 2026-04-26.

Code-only. No live DB calls.

Scope:

- Move `supabase/migrations/*.sql` to `db/migrations/*.sql` preserving filename
  order and SQL content.
- Add an Azure/generic-Postgres role bootstrap before the existing migrations
  so Supabase-era policy roles still exist on Azure (`service_role` and
  `authenticated` at minimum). Existing RLS policy semantics must not silently
  disappear during the host migration.
- Replace Supabase local/project assumptions with generic Postgres + AGE +
  pgvector local dev assumptions.
- Replace Supabase staging scripts with Azure/Postgres scripts.
- Rename env/secret naming from `SUPABASE_*` to `POSTGRES_*` / `AZURE_*`.
- Update proxy/corpus code, comments, tests, and docs that reference Supabase as
  the active Postgres host.
- Keep historical Supabase reports readable and clearly superseded.

Expected file families:

- `supabase/migrations/*` -> `db/migrations/*`
- new `db/migrations/202604250000_advisor_roles.sql` or equivalent first
  migration for compatibility roles
- `supabase/config.toml`
- `docker-compose.dev.yml`
- `scripts/supabase_*.ps1` -> `scripts/postgres_staging_*.ps1` plus
  `scripts/use_postgres_staging_env.ps1`
- `tool/advisor_proxy/*`
- `tool/advisor_corpus/*`
- `lib/services/advisor_corpus_admin_service.dart`
- `test/advisor_proxy_test.dart`
- `test/advisor_corpus_manifest_test.dart`
- `package.json` / `package-lock.json` if Supabase CLI dependency is present

Acceptance:

- Existing tests pass.
- `dart analyze` is clean for touched Dart targets.
- No live DB, provider, or Azure calls.
- No tracker updates by Claude.
- No commits.

Human setup for this slice:

- None for `11a.11c.5`; it is code-only.
- `11a.11c.6` will require Azure access and live provisioning decisions.

### `11a.11c.6` - Azure Provisioning + Apply + AGE Benchmark

Live slice. Do not start until `11a.11c.5` accepts.

Status: **accepted for 11a database infrastructure, with staging limitations**
as of 2026-04-26. See
`phase_11a_11c6_azure_staging_apply_result.md`,
`phase_11a_11e_staging_live_load_result.md`, and
`phase_11a_production1_provisioning_result.md`. Staging remains B1ms
with 7-day backups and no built-in PgBouncer; Production1 closes the
production-only gaps with General Purpose `Standard_D2ds_v5`, 35-day
backup retention, and PgBouncer smoke passing. `pgmq` is not exposed
in Azure; queues stay on `FOR UPDATE SKIP LOCKED` / Cloud Tasks.

Setup:

- Azure subscription/account with permission to create PostgreSQL Flexible
  Server.
- Resource group for staging/prod.
- Staging server in Canada Central, PG 16.
- Production server in Canada Central, PG 16.
- **Production tier minimum: General Purpose (`Standard_D2ds_v5` or
  higher).** Required because Azure's built-in PgBouncer transaction-
  mode pooling is gated to General Purpose and Memory Optimized
  tiers; Burstable does not expose it. Staging may continue on
  Burstable (`Standard_B1ms` is in use today), but staging then does
  not test PgBouncer behavior — pooling rehearsal happens against
  production tier or above.
- `azure.extensions` allowlist: `age`, `vector`, `pg_diskann`,
  `pg_cron`, `pg_partman`, `pg_stat_statements`, `pgcrypto`. `pgmq`
  is **not** in this list — live verification on the staging server
  on 2026-04-26 confirmed Azure does not expose it. The Phase 12
  queue path uses `SELECT ... FOR UPDATE SKIP LOCKED` for in-DB
  queues and Cloud Tasks for HTTP-delivery queues; do not
  reintroduce `pgmq` as a required extension without a new
  live-hosting decision.
- `shared_preload_libraries`: `age`, `pg_cron`, `pg_stat_statements`.
  Live path uses `pg_cron` to call pg_partman hourly; no `pg_partman_bgw`
  preload is required for the accepted path.
- Firewall rule for Cloud Run egress IPs or Private Link.
- PITR enabled. **Staging: 7-day retention is acceptable for the
  partial slice.** Production: 35-day retention is a pre-production
  checklist item that must land before any operator data is written;
  apply via `--backup-retention 35` at provisioning time.
- Built-in PgBouncer transaction pooling enabled — production only
  (General Purpose+ tier requirement above). Staging on Burstable
  B1ms skips pooling entirely.

Verification:

- `CREATE EXTENSION IF NOT EXISTS age CASCADE;`
- AGE Cypher smoke query.
- `CREATE EXTENSION IF NOT EXISTS vector;`
- pgvector cosine smoke query.
- `CREATE EXTENSION IF NOT EXISTS pg_diskann;` if available on selected tier.
- `CREATE EXTENSION IF NOT EXISTS pg_cron;` (precompute + scheduled
  workflow runner prerequisite).
- `CREATE EXTENSION IF NOT EXISTS pg_partman;` (NEW per Lock 2 in
  decision register Production Hardening Locks). Allowlist via
  `azure.extensions`. Used to automate `usage_logs` partition creation
  + dropping.
- Apply all `db/migrations/*`.
- Apply `7.57.4` AGE projection artifacts.
- Apply or evaluate `11a.8` pgvector index artifacts; **evaluate DiskANN
  swap (Lock 1)**: run benchmark vs HNSW on production-scale corpus,
  build `idx_chunks_diskann` and drop HNSW if DiskANN wins.
- Apply schema additions for Anthropic Contextual Retrieval +
  cost-discipline telemetry:
  - `advisor_source_chunks.chunk_context TEXT` (Haiku-generated 50-100
    token context prepended at indexing time per Anthropic Contextual
    Retrieval pattern)
  - `advisor_source_chunks.tsv tsvector GENERATED ALWAYS AS (...)` for
    BM25 sparse retrieval leg
  - GIN index on `tsv` for BM25 lookup
  - `advisor_source_chunks.corpus_version` for cache-key invalidation
  - Telemetry columns on `usage_logs`: `query_class`, `cache_hit`,
    `llm_tier`, `model_used`, `batch_mode`, `circuit_state`,
    `fallback_used`
- **Apply AGE index strategy (Lock 3)**: BTree on `id` for every vertex
  table; BTree on `start_id` and `end_id` for every edge table; GIN on
  most-queried property paths (`Concept.name` etc.). Document the rule
  for future graph schemas.
- **Apply RLS performance discipline (Lock 4)**: every fact-table index
  has `operator_id` (or `(operator_id, location_id)`) as the leading
  column. Audit query against `pg_indexes` confirms.
- **Schedule `pg_partman` maintenance** (Lock 2):
  ```sql
  SELECT cron.schedule(
    'partman_maintenance', '0 * * * *',
    $$SELECT public.run_maintenance(p_analyze := true)$$
  );
  ```
- Run AGE benchmark at 1K and 10K operator-scale synthetic data.
- Insert default `graph_retrieval_mode` feature flag (resilience
  fallback only; advisor 11b launches with Modular Adaptive RAG, not
  graph-first as default).

Acceptance:

- Azure staging and production schemas match.
- AGE is live and smoke-tested.
- pgvector is live and smoke-tested.
- pg_diskann verified available (or documented as unavailable on chosen
  tier). DiskANN-vs-HNSW benchmark documented; chosen index live.
- pg_cron + pg_partman verified available. `pgmq` is **not** an
  Azure extension on this host (live-verified 2026-04-26); the
  Phase 12 queue path is locked to `FOR UPDATE SKIP LOCKED` for
  in-DB queues and Cloud Tasks for HTTP-delivery queues, not pgmq.
- AGE projection smoke traversal succeeds.
- AGE indexes (BTree on id/start_id/end_id, GIN on hot property paths)
  applied to every vertex/edge table; documented.
- AGE benchmark result documented (isolated p95 ≤ 500ms, 10x concurrent
  p95 ≤ 1000ms). If benchmark fails, tier upgrade is evaluated before
  flipping the resilience fallback to vector-only.
- Schema additions for Contextual Retrieval and cost-discipline
  telemetry applied.
- RLS-leading-column audit passes (every operator-scoped fact-table
  index leads with `operator_id` or `(operator_id, location_id)`).
- `pg_partman` registered for `usage_logs`; hourly maintenance scheduled.

#### `11a.11c.6a` - Local Schema-Hardening Migration

Status: Accepted 2026-04-26.

Runs before AGE projection / benchmark work. Local-only; no Azure apply.

Scope:

- Add a new deterministic migration under `db/migrations/` for:
  - `advisor_source_chunks.chunk_context TEXT`
  - BM25 `tsvector` generated column + GIN index on `advisor_source_chunks`
  - `advisor_source_chunks.corpus_version`
  - cost/telemetry columns on `usage_logs`: `query_class`, `cache_hit`,
    `llm_tier`, `model_used`, `batch_mode`, `circuit_state`,
    `fallback_used`
- Include SQL comments documenting Contextual Retrieval and cost telemetry.
- Add pg_partman registration / cron-maintenance SQL scaffold if safe in a
  migration, or a companion verification SQL doc if it must stay operator-run.
- Add RLS/index audit SQL scaffold proving operator-scoped fact-table indexes
  lead with `operator_id` or `(operator_id, location_id)`.
- Add migration tests that assert the new columns, indexes, comments, and
  audit/scaffold SQL are present.

Acceptance:

- Migration is local and deterministic; no live Azure/Postgres command.
- Tests assert Contextual Retrieval columns and BM25 index.
- Tests assert cost telemetry columns on `usage_logs`.
- Tests assert pg_partman maintenance/audit SQL is represented.
- Tests assert RLS-leading-column audit coverage exists.

#### `11a.11c.6b` - AGE Projection + Benchmark + DiskANN Decision Harness

Status: Accepted 2026-04-26.

Local-first. Do not apply to live Azure until the generated artifacts and
benchmark harness accept locally.

Scope:

- Locate existing `7.57.4` AGE projection artifacts and current advisor graph
  seed/edge tables.
- Produce deterministic SQL artifacts for AGE projection apply/smoke:
  graph creation, vertex/edge label creation, seed projection, smoke traversal,
  and cleanup/replay guidance.
- Add AGE index strategy SQL for every projected vertex/edge table:
  BTree on `id`, BTree on `start_id`/`end_id` for edges, and GIN on hot
  property paths such as `Concept.name`.
- Add a local benchmark harness/runbook for 1K and 10K synthetic
  operator-scale AGE traversal, with pass thresholds preserved from the
  parent gate (isolated p95 <= 500ms, 10x concurrent p95 <= 1000ms).
- Add a DiskANN-vs-HNSW decision harness over `advisor_source_chunks` that
  records candidate index DDL, benchmark inputs, and the decision report path;
  do not drop HNSW in this slice.

Acceptance:

- Local artifacts are deterministic and tested.
- AGE projection SQL includes indexes and smoke traversal.
- Benchmark harness is runnable after live operator approval but is not run
  by default.
- DiskANN/HNSW decision harness is present and does not mutate live indexes.

### `11a.11d` - Proxy Counter Wiring + Smoke + Cost-Discipline Levers 1-2

Status: Accepted 2026-04-26 as a local/fake-tested scaffold. Live Postgres
store/provider execution remains gated.

- Idempotency check on every proxy request using `proxy_requests`.
- Atomic UPSERT into `usage_logs` with telemetry columns
  (`query_class`, `cache_hit`, `llm_tier`, `model_used`, `batch_mode`).
- Cap lookup from `usage_caps`.
- Refusal payload includes cap status.
- `/health` runs three real queries: Postgres `SELECT 1`, AGE Cypher MATCH,
  and pgvector similarity. Returns 200 only if all succeed.
- `/v1/...` URL versioning remains locked.
- Meta-only request logging by default.
- Full-content logging requires per-operator opt-in flag.
- Smoke tests cover over-cap, idempotent retry, and counter concurrency without
  provider calls.
- **Cost-discipline lever 1 (prompt caching) wired**: `LLMProvider.complete()`
  marks stable system-prompt + tool-definition + corpus-context blocks
  with Anthropic cache breakpoints. Per-corpus-version cache key
  (`advisor_source_chunks.corpus_version`) invalidates on corpus change.
- **Cost-discipline lever 2 (tier routing) enforced**: every advisor
  call goes through `LLMProvider.complete(..., tier)`. Default tier
  resolved from `operators.subscription_tier` (Basic→Haiku-only;
  Premium+→tier-conditional Sonnet). Tracked in `usage_logs.llm_tier`.

### `11a.11e` - Corpus + Embedding Live Load

Status: Accepted 2026-04-26.
See `phase_11a_11e_staging_live_load_result.md`.

Runs after proxy/DB wiring is ready.

- Corpus build pipeline ran against Azure-backed staging Postgres.
- Pipeline load was idempotent with content-addressed IDs preserved.
- Voyage rate limits were handled with small batches / delay under the
  account's current reduced limit.
- All current chunks loaded: 8 documents, 233 chunks.
- Embeddings stamped with provider/model/dimension: 233 ready
  `voyage-4-large` embeddings at 1024 dimensions.
- AGE graph projection runs on staging and smoke traversal returns 233
  Document -> Chunk pairs.
- Vector search and Voyage rerank smoke queries return expected candidates.
- Old inactive chunks remain available for replay through active/inactive
  semantics.
- Anthropic Contextual Retrieval context generation populated
  `chunk_context` for all 233 active staging chunks.
- Voyage embeddings were refreshed from context + text inputs.
- Claude answer-runtime smoke returned `end_turn` with a citation-bearing
  answer from the top reranked candidate.

## After `11a.11c-e`

Open Phase 11A Operations Console foundation:

- `11A.0` Flutter for Web bootstrap
- `11A.1` operator/location management
- `11A.2` pricing tier admin
- `11A.3` corpus admin
- `11A.4` integration management
- `11A.5` debug console
- `11A.6` observability dashboard

Then resume the tracker cadence at `9.8`.

## Source Material

- `docs/Knowledge_graph_docs/corpus_manifest.yaml`
- `docs/archive/reference/Rag_Architecture.svg`
- `docs/archive/phases/phase_11a/phase_11a_0_corpus_manifest_ingestion_contract.md`
- `docs/archive/phases/phase_11a/phase_11a_1_manifest_validator_chunk_plan.md`
- `docs/archive/phases/phase_11a/phase_11a_2_ingestion_record_materializer.md`
- `docs/archive/phases/phase_11a/phase_11a_3_supabase_corpus_storage_schema.md`
- `docs/archive/phases/phase_11a/phase_11a_4_db_loader_dry_run.md`
- `docs/archive/phases/phase_11a/phase_11a_5_local_db_load_verification.md`
- `docs/archive/phases/phase_11a/phase_11a_6_embedding_contract_provider_prep.md`
- `docs/archive/phases/phase_11a/phase_11a_7_embedding_execution_local_load.md`
- `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md`
