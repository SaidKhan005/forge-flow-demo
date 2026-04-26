# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-26
Status: Active - Azure/AGE live infrastructure sequence
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
- Next slice: `11a.11c.5`, code-only repo tooling re-target to Azure.
- Next live slice: `11a.11c.6`, Azure provisioning, extension verification,
  schema apply (incl. `chunk_context` column for Contextual Retrieval +
  `tsvector` BM25 column on chunks), AGE projection apply, and AGE
  benchmark.

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

## Active Slice Contracts

### `11a.11c.5` - Repo Tooling Re-target To Azure

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
- `scripts/supabase_*.ps1` -> `scripts/azure_pg_*.ps1`
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

Setup:

- Azure subscription/account with permission to create PostgreSQL Flexible
  Server.
- Resource group for staging/prod.
- Staging server in Canada Central, PG 16.
- Production server in Canada Central, PG 16.
- Staging may use Burstable B2s; production should use General Purpose D2s_v3
  or higher unless the user explicitly chooses a lower-cost MVP tier.
- `azure.extensions` allowlist: AGE, VECTOR, PG_DISKANN, PGMQ, PG_CRON,
  PG_STAT_STATEMENTS.
- `shared_preload_libraries`: AGE, pg_cron, pg_stat_statements.
- Firewall rule for Cloud Run egress IPs or Private Link.
- PITR enabled, 35-day retention.
- Built-in PgBouncer transaction pooling enabled.

Verification:

- `CREATE EXTENSION IF NOT EXISTS age CASCADE;`
- AGE Cypher smoke query.
- `CREATE EXTENSION IF NOT EXISTS vector;`
- pgvector cosine smoke query.
- `CREATE EXTENSION IF NOT EXISTS pg_diskann;` if available on selected tier.
- `CREATE EXTENSION IF NOT EXISTS pgmq;` (Phase 12 prerequisite; verify
  availability now to avoid surprises).
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
    $$SELECT partman.run_maintenance(p_analyze := true)$$
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
- pgmq + pg_cron + pg_partman verified available.
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

### `11a.11d` - Proxy Counter Wiring + Smoke + Cost-Discipline Levers 1-2

Runs after Azure DB is live.

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

Runs after proxy/DB wiring is ready.

- Corpus build pipeline runs against Azure-backed Postgres/proxy.
- Pipeline is idempotent and resumable.
- Voyage rate limits handled with backoff and jitter.
- All current chunks load with content-addressed IDs preserved.
- Embeddings stamped with provider/model/dimension.
- AGE graph projection runs at production scale.
- Vector search and Voyage rerank smoke queries return expected candidates.
- Old inactive chunks remain available for replay.

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
