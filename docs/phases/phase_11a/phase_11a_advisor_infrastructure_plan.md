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
- `security.env.1`: local secrets consolidated outside the repo under
  `$HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1`; `.env.local` remains ignored
  if recreated, and examples are sanitized.
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
  secrets live outside the repo at `$HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1`, AGE /
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

## Accepted Slice References

`11a` is closed. This section is a navigation map only; active work has moved
to `11A.0`.

- `11a.11c.5`: Azure/Postgres retarget accepted. Current source of truth:
  `db/migrations/`, `scripts/postgres_staging_*.ps1`,
  `scripts/use_postgres_staging_env.ps1`, `docker-compose.dev.yml`,
  `tool/advisor_proxy/`, `tool/advisor_corpus/`, and related tests.
- `11a.11c.6`: Azure staging/prod schema accepted with staging limitations
  documented in `docs/archive/phases/phase_11a/phase_11a_11c6_azure_staging_apply_result.md`
  and production closure documented in
  `docs/archive/phases/phase_11a/phase_11a_production1_provisioning_result.md`.
- `11a.11c.6a-b`: schema hardening, Contextual Retrieval telemetry,
  RLS-leading-index hardening, AGE projection/index artifacts, benchmark
  harness, and DiskANN/HNSW decision harness accepted. Current source of truth:
  `db/migrations/202604250006_advisor_contextual_retrieval_telemetry.sql`,
  `db/migrations/202604250007_advisor_rls_index_hardening.sql`,
  `tool/advisor_corpus/`, and `test/advisor_corpus_manifest_test.dart`.
- `11a.11d`: proxy counter/idempotency/health/cost-lever scaffold accepted.
  Current source of truth: `tool/advisor_proxy/` and
  `test/advisor_proxy_test.dart`.
- `11a.11e`: staging live corpus, Contextual Retrieval, embedding refresh,
  AGE, vector/rerank, and Claude smoke accepted. Current source of truth:
  `docs/archive/phases/phase_11a/phase_11a_11e_staging_live_load_result.md`.

## After `11a.11c-e`

Phase 11A Operations Console foundation status is tracked in
`docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.
As of 2026-05-03, `11A.0` through `11A.5` are accepted and `11A.6`
remains the next cost/dependency observability surface:

- `11A.0` Flutter for Web bootstrap
- `11A.1` operator/location management
- `11A.2` pricing tier admin
- `11A.3` corpus admin
- `11A.4` integration management
- `11A.5` debug console (accepted)
- `11A.6` observability dashboard (remaining)

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
