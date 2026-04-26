# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-25
Status: Repo scaffold complete - paused for live infrastructure sequencing decision
Owner: Future advisor infrastructure lane

Last review: 2026-04-23 - Backend stack pivoted from Firestore to Supabase Postgres with Apache AGE (graph) + pgvector (vectors). Rationale: native graph traversal via Cypher queries, native vector similarity, SQL for analytics, all in a single Postgres instance. Documented production pattern for "operational analytics + knowledge graph + semantic intelligence in a single engine" per Microsoft Azure's AGE + pgvector architecture guidance.

Current review: 2026-04-25 - `11a.0` established the active Markdown corpus
location, manifest authority, source inclusion/exclusion rules, chunking
profiles, graph node/edge taxonomy, and retrieval provenance contract. `11a.1`
added the local manifest validator plus chunk-plan dry run. `11a.2` added a
deterministic build-only materializer that emits source document, source chunk,
graph node seed, and graph edge hint records under `build/advisor_corpus/`.
`11a.3` added the Supabase/Postgres schema scaffold for those record families,
including extension prep, RLS enablement, indexes, and placeholder policies.
`11a.4` added deterministic build-only SQL load preparation: ordered upsert
files plus a load manifest under `build/advisor_corpus/load/`. `11a.5` loaded
those records into a local Supabase Postgres container and verified counts,
pending embedding state, RLS enablement, and reference integrity. `11a.6`
added a dry-run embedding job preparer, then `11a.6a` revised the provider
contract to the Claude-aligned lane: Claude/Anthropic for future advisor
answers, Voyage `voyage-4-large` for embeddings, Voyage `rerank-2.5` for
candidate reranking, and `vector(1024)` in pgvector.
Local Voyage embedding generation is now complete and loaded into the local
Supabase/Postgres container. `11a.8` added generated SQL for versioned
embedding metadata, HNSW cosine indexing, and `advisor_search_chunks` scoped
candidate retrieval. Cloud database apply, rerank calls, AGE live apply, MCP
tools, and agent UX remain future 11a/11b work.

Current review: 2026-04-25 - `7.57` stabilization is complete. `7.57.4`
added deterministic AGE projection and CPLH smoke-traversal SQL artifacts from
the staged graph seed tables. Codex local verification could not run Supabase
because the `supabase` CLI is unavailable in this environment; generated
artifacts carry an explicit `AGE_BLOCKER` path. `11a` resumed at `11a.8`.
`11a.8` added provider-safe vector metadata, HNSW cosine indexing, and the
`advisor_search_chunks` scoped candidate-retrieval SQL function.
`11a.9` added a fake-tested rerank smoke path through `RerankProvider` while
preserving citation/provenance metadata. `11a.10a` added the pure Dart
Cloud Run-ready proxy scaffold: secrets-by-name config, interface-based JWT
verification, operator/location guard, `/healthz`, and a protected scope smoke
route. `11a.10b` added launch-tier proxy usage enforcement scaffolding:
request-token cap, per-minute rate cap, monthly cost cap, machine-readable
refusals, fail-closed counter-store seam, `/v1/usage-smoke`, and an
RLS-enabled usage counter migration. It does not call live providers or
databases. `11a.11a` added content-addressed source chunk IDs plus
active/inactive stale-chunk semantics so changed corpus content gets a new
chunk ID, old chunks remain replayable but inactive, zero-current-chunk docs
still deactivate prior chunks, and vector search returns only active chunks.
`11a.11b` produced the cloud DB apply readiness audit. Live apply is blocked
from this environment by missing Supabase CLI/config/link/env plus unverifiable
target extension availability, but the repo now has the migration inventory and
human apply/verification runbook. `security.env.1` sanitized the ignored local
env example so provider/Supabase secret names are placeholders only; the prior
secret-looking Anthropic value must be rotated outside the repo if it was real.
`11a.12a` added the local-only corpus admin Settings scaffold: an injectable
service validates pasted Markdown, returns deterministic local preview status,
rejects invalid input, and renders the 11a.11b cloud-load blocker without live
DB or provider calls. `11a.12b` wired the scaffold into the debug app Settings
route and made the cloud-load affordance non-interactive while blocked.
`11a.12c` enriched that preview with ingestion-shaped metadata: normalized
file/source identity, deterministic title preview, heading count, estimated
chunk count, and Settings display. This closes the local/repo-scaffold part of
11a; live infrastructure sequencing is now the explicit pause point.

## Goal

Build the backend substrate for the agentic advisor: a knowledge graph of
shared methodology, a content ingestion pipeline so founders can keep
expanding the corpus, and a proxy backend + MCP tool layer (`11a.10`,
split into `10a` infra + `10b` per-operator enforcement; `10c` admin
dashboards flagged for post-100-locations; `10d` provider fallback as
locked future capability, off by default) brokering all LLM / embedding
calls and exposing per-operator live data. No user-facing surface;
purely infrastructure.

**Cadence superseded 2026-04-25.** Original 2026-04-22 framing was
"Phase 11a runs in parallel with Phase 8 / 8R / 9." That parallel
framing is now obsolete. Phase 11a now runs sequentially after `7.57`
stabilization and before `9.8`, per the locked build order in
`PROJECT_TRACKER.md` (completed `7.57` plan archived at
`docs/archive/phases/post_11a7_stabilization_plan.md`). By the time
Phase 9 lands, the graph + proxy + tool layer are ready so Phase 11b
(Advisor UX) is a small lift instead of a from-scratch build.

## Decisions Locked (2026-04-22 review)

- **Sequence (superseded 2026-04-25):** original framing was "11a runs
  in parallel with Phase 8 / 8R / 9." Now: 11a runs sequentially
  between `7.57` and `9.8` per the locked build cadence. Does not wait
  on auth or vendor selection. Phase 8 is blocked on vendor picks anyway,
  so 11a uses that time to build the knowledge substrate.
- **Content model:** founder-authored methodology, SOPs, handbooks, and
  training material form a shared corpus. Uploading new content expands
  the graph; new nodes + edges get discovered through ingestion. One
  canonical store, many consumers (Barrio coaching, Forge & Flow advisor).
- **Content authorship:** Vanessa primary for restaurant SOPs + training
  material. Jim Taylor + Preston Lee methodology is founder-synthesized
  from public writing. The active Jim Taylor source for 11a is the Markdown
  corpus file in `docs/Knowledge_graph_docs/`. No licensed third-party content.

- **Preston Lee methodology source:** Said will author a Preston Lee
  deep-dive doc, synthesized from public Preston Lee writing. Phase 11a
  can seed ingestion with Jim Taylor content first; Preston Lee ingests
  when the doc lands. Both co-exist in the same corpus location
  (`docs/Knowledge_graph_docs/`).

- **Corpus format standard: Markdown only.** All ingestion material must
  be Markdown. Applies to Jim Taylor deep-dive, Preston Lee deep-dive
  (authored in Markdown when it lands), Vanessa's SOPs + training
  material, and any future methodology content. Non-Markdown inputs
  (HTML, `.docx`, PDF, Google Docs) raise a flag in the ingestion pipeline
  for conversion-before-ingest; they do not silently bypass the standard.

- **Vanessa's SOP + training backlog:** The current active corpus is already
  Markdown under `docs/Knowledge_graph_docs/`, including Vanessa / operator
  training material provided for this lane. Future non-Markdown additions
  (Google Docs / `.docx` / PDF) still go through conversion-before-ingest and
  require a manifest update before they become active corpus rows.
- **Corpus storage location: Supabase Postgres (same project as Phase 9).**
  Decision locked on 2026-04-23 as part of the backend stack pivot.
  Rationale: the content model is natively multi-tenant (shared
  methodology + per-operator SOPs); Postgres with RLS handles per-operator
  scoping natively; the backend aligns with Phase 9 / 9.5 / 10a
  infrastructure; non-engineer authoring becomes a clean future path
  without repo-access gymnastics.

  - Specific backend: Supabase Postgres with Apache AGE extension (for
    graph traversal via Cypher queries) and pgvector extension (for
    vector similarity search). Both extensions loaded on the same
    Postgres instance.
  - Admin-authored writes only (Said + Vanessa); Phase 9 auth roles gate
    write access via RLS policies on corpus tables.
  - Per-operator scoping baked in from day one even with a single
    operator - shared methodology documents are operator-independent
    (null `restaurant_id` or global scope); those global rows are shared
    founder-authored methodology only, never another operator's SOPs or
    metrics. SOP / training material is operator-scoped (`restaurant_id`
    set per row; RLS enforces).
  - Dev loop uses the local Supabase stack (Docker) so dev work does not
    touch real data; no parallel-sequencing blocker vs Phase 9.

- **Graph + vector architecture: Apache AGE + pgvector on single
  Postgres instance.** Following the documented Microsoft Azure
  production pattern, methodology content is stored as:
  - Nodes and edges in Apache AGE property graph (Cypher queries for
    traversal)
  - Vector embeddings in pgvector columns on related tables (HNSW or
    IVFFlat indexes for ANN search)
  - A bridge between them: cosine similarity scores written as
    `SIMILAR_TO` edges in the AGE graph, turning vector distances into
    traversable relationships
  - One Postgres query planner, one backup strategy, one monitoring
    stack, one connection pool

- **Server hosting: dedicated backend (Cloud Run), not Cloud Functions.**
  Decision locked 2026-04-22 alongside the Phase 9 mixed-backend decision.
  Reason: MCP tool serving + graph retrieval (Phase 11a) and the future
  agent runtime (Phase 11b) do not fit Cloud Functions constraints
  (request timeouts, cold starts, lack of persistent state). Cloud
  Functions (or Supabase Edge Functions) remains the path for Phase 9
  auth admin ops; 11a/11b run on Cloud Run. Both authenticate clients
  against the same Firebase Auth and read/write the same Supabase
  Postgres (with RLS enforcement for user-scoped reads, Supabase
  service-role for admin-scoped writes that bypass RLS).

- **Per-operator scoping:** designed into the tool layer from day one
  via Postgres RLS. Enforcement lights up with Phase 9 auth (JWT claims
  scope reads); scaffolding supports single-tenant mode before then
  without throwaway rework.

## Scope

Phase 11a owns:

- Knowledge graph schema + storage
  - graph model (property graph, embedded JSON, or similar; exact
    storage decision still TBD)
  - confidence tagging (EXTRACTED, INFERRED, AMBIGUOUS) preserved
    through retrieval
  - methodology-to-formula edges so reasoning can trace a metric back to
    the principle that justifies it
- Content ingestion pipeline
  - upload / add-to-corpus flow so founders can expand the knowledge base
    without a full rebuild
  - initial corpus seeding from Jim Taylor labor model content, Preston
    Lee methodology, Vanessa's SOPs + training material, industry KPI
    definitions
  - re-ingest / update semantics so stale material can be replaced
- MCP server + tool layer (backend-only; no chat UI yet)
  - knowledge tools (graph read, concept explain, path trace)
  - operational tools (CPLH, SPLH, PPA, headcount, Sales Labor %,
    Variance, open-shift context, closed history) reading from existing
    repositories
  - per-operator scoping hooks wired through from day one
- Supabase Postgres integration for corpus persistence, using Apache
  AGE for graph traversal, pgvector for vector similarity search, and
  RLS policies for per-operator scoping. Same Postgres project as
  Phase 9 / 9.5 / 10a.

## Scope Does Not Own

Phase 11a does not own:

- agent runtime / reasoning loop (`Phase 11b`)
- Coach Chatbot UI (`Phase 11b`)
- any user-facing surface
- POS + Labor connector transport (`Phase 8`)
- reservation connector transport (`Phase 8R`)
- auth, roles, permission keys (`Phase 9`)
- Barrio UX shell (`Phase 9.75`)

## Runtime Contract

```text
founder uploads methodology / SOP / training content
-> ingestion pipeline
-> knowledge graph (nodes + edges, confidence-tagged)
-> pgvector cosine candidates
-> Voyage rerank-2.5 ordering
-> Claude answer runtime with citations / provenance

operator repositories (POS, labor, canonical facts, variance)
-> proxy backend (`11a.10a`) + MCP tool layer (read-only,
   per-operator scoping hooks via `11a.10b` enforcement)
-> ready to serve the agent runtime when Phase 11b lights up
```

## Dependencies

Required before Phase 11a can ship real:

- nothing architecturally; 11a is backend-only and now resumes sequentially
  after `7.57`
- corpus content from Vanessa (SOPs + training material) for meaningful
  ingestion
- Supabase Postgres project provisioned with AGE + pgvector extensions
  enabled (can start with local Supabase Docker stack for dev before
  production project is provisioned)

Consumers of Phase 11a:

- `Phase 11b` agent runtime + Coach Chatbot UX
- `Phase 9.75` coaching retrieval surfaces (My Shift coaching tip, Focus
  picker AI-assist) once 9.75 ships - retrieval happens through 11a's
  graph + tools, not through 11b's agent runtime (coaching tips are a
  simpler retrieval case than conversational chat)

## Non-Negotiables

- no vendor secrets in Flutter; MCP server mediates all external access
- no licensed third-party content in the corpus; founder-synthesized only
- per-operator scoping hooks designed in from day one even if enforcement
  waits on Phase 9
- the graph and corpus are advisory / explanatory layers only; they do not
  replace canonical operational facts, locked plans, target authority, or
  permission truth
- no user-facing surface shipped from 11a; all UX lives in 11b or
  consuming phases
- corpus format is Markdown only; non-Markdown inputs raise a
  conversion flag rather than ingesting silently
- operator-scoped corpus writes should carry audit-style write metadata
  consistent with the Phase 10a governance pattern, even though the corpus
  tables remain separate from 10a shared-state tables

## Adjacent Phases

- `Phase 8` + `Phase 8R` populate the repositories the tool layer reads;
  11a can scaffold against demo / seeded data before they land
- `Phase 9` issues the operator scope the tool layer isolates on when
  11b ships
- `Phase 9.75` Barrio coaching surfaces consume 11a's retrieval layer
- `Phase 11b` consumes 11a's graph + tools for the agent runtime

## 11a.11c-e Live Infrastructure Checklist

Repo scaffold (`11a.0` through `11a.12c`) is complete. The remaining
11a work is live execution. Locked sequence 2026-04-25:
**`11a.11c` -> `11a.11d` -> `11a.11e`**, then `11a.12` cloud
enablement, then `11a.13` pricing-tier admin Settings UX, then
resume the build cadence at `9.8`. Tick items off as they land.

### `11a.11c` - Cloud Supabase apply + extension verify + AGE benchmark gate

**Setup**

- [ ] Supabase production project provisioned in `ca-central-1`
      (fallback `us-east-1` if Canada-region unavailable)
- [ ] Supabase staging project provisioned in same region (mirrors
      production schema; migrations land here first, validate with
      synthetic data, then promote to production)
- [ ] Point-in-time recovery enabled on production, 7-day retention
- [ ] Weekly logical backup (`pg_dump`) scheduled to Google Cloud
      Storage with 90-day retention (covers the gap beyond PITR)
- [ ] Supavisor transaction-mode pooling configured
- [ ] Proxy backend (Cloud Run) env / KMS wired to cloud Supabase
      connection string
- [ ] Cloud Run `max-instances` capped so that
      `(max_instances * connections_per_instance) <=
      supabase_connection_limit * 0.7` (leaves headroom; prevents
      connection exhaustion during traffic spikes)

**Extensions**

- [ ] Apache AGE extension enabled; sample Cypher query verified
- [ ] pgvector extension enabled; `vector` type + cosine similarity
      verified
- [ ] If AGE unavailable on chosen tier: blocker documented,
      Q12 fallback flag flipped on, Neo4j-migration timeline noted

**Foundational identity tables**

- [ ] `operators` (`operator_id` UUID PK; `business_name`,
      `owner_email`, `subscription_tier`, `preferred_currency`
      CHAR(3) DEFAULT 'CAD'; `primary_location_id` UUID NULL
      (FK to `locations`, used for cross-location aggregations
      when an operator runs locations across multiple time zones);
      audit columns)
- [ ] `locations` (`location_id` UUID PK; `operator_id` FK CASCADE;
      `name`, `address`, `timezone` IANA TEXT,
      `business_day_rollover_hour` INT; audit columns)
- [ ] `users` (`user_id` UUID PK; `operator_id` FK CASCADE; `email`,
      `role` TEXT NULL; audit columns)
- [ ] `operator_admins` (`user_id` PK/FK; `operator_id` FK CASCADE;
      `is_super_admin` BOOL; audit columns)

**Operator-scoped fact-table conventions**

- [ ] Every fact table carries `(operator_id, location_id)` with FK
      references to `operators` / `locations` (`ON DELETE CASCADE`)
- [ ] Every fact table has `created_at TIMESTAMPTZ DEFAULT now()`
      and `updated_at TIMESTAMPTZ DEFAULT now()`
- [ ] Source-truth instants stored as `TIMESTAMPTZ`; denormalized
      `business_date DATE` computed write-once at insert
- [ ] `TIMESTAMP WITHOUT TIME ZONE` not present anywhere in
      operator-scoped tables (audit query confirms)
- [ ] CHECK constraints on numeric columns (`cost_usd >= 0`,
      `token_count >= 0`, etc.)
- [ ] RLS enabled with policy stubs on every operator-scoped table
      (Phase 9 turns enforcement on)

**Counter / cap / idempotency / flags**

- [ ] `usage_logs` declared as a **partitioned table** by
      `period_start` (Postgres declarative monthly partitioning;
      cheap at table creation, brutal to retrofit later);
      composite PK on `(operator_id, location_id, usage_class,
      period_start)`; columns `token_count`, `cost_usd`,
      `request_count`; audit columns
- [ ] `usage_caps` (`(operator_id, location_id, usage_class)` PK;
      `monthly_cap_usd` DECIMAL, `per_invocation_cap_usd` DECIMAL;
      `created_by`, `updated_by`, audit columns)
- [ ] `proxy_requests` (`request_id` UUID PK; `idempotency_key`
      UNIQUE; `request_type` TEXT for Phase 12 reuse;
      `operator_id`, `location_id`, `usage_class`;
      `response_payload` JSONB NULL; audit columns)
- [ ] `feature_flags` (`flag_name` TEXT; `operator_id` UUID NULL;
      `location_id` UUID NULL; `enabled` BOOL; audit columns)
- [ ] `fx_rates` (`base_currency`, `quote_currency`, `rate` DECIMAL,
      `as_of_date`, `source`; PK on `(base, quote, as_of_date)`)

**Embeddings / corpus / graph**

- [ ] Vector versioning columns on embeddings table:
      `embedding_provider_id`, `embedding_model_id`,
      `embedding_dimension` INT
- [ ] AGE graph projection schema applied (apply `7.57.4` SQL)
- [ ] pgvector HNSW cosine partial index applied (apply `11a.8` SQL)
- [ ] Content-addressed corpus chunk tables applied (apply
      `11a.11a` SQL)

**AGE benchmark gate**

- [ ] Synthetic graph generated at 1K-operator scale and
      10K-operator scale
- [ ] Representative graph-traversal queries run **in isolation**;
      p95 latency recorded
- [ ] Same queries run **under 10x concurrent load** (10 parallel
      traversals at the same time); p95 latency recorded
- [ ] If isolated p95 > 500ms OR concurrent p95 > 1000ms:
      `feature_flags` row inserted for
      `graph_retrieval_mode = vector_only` (Q12 fallback becomes
      launch posture); benchmark blocker documented
- [ ] If isolated p95 <= 500ms AND concurrent p95 <= 1000ms:
      AGE is the launch posture; benchmark results recorded for
      future reference (AGE doesn't have Neo4j's mature query
      optimizer, so concurrency edges show up faster)

**Acceptance**

- [ ] Cloud Supabase live with both extensions verified
- [ ] Staging project mirrors production schema
- [ ] All Tier 1 + Tier 1.5 schema applied without manual fixes
- [ ] AGE benchmark gate result documented (pass or
      fail-with-fallback, including concurrent-load p95)
- [ ] Proxy backend connects to cloud Supabase via Supavisor
      transaction pooling
- [ ] Cloud Run `max-instances` cap set against connection-limit
      math

**Post-launch maintenance (scheduled jobs to land alongside this slice)**

- [ ] Nightly prune of `proxy_requests` rows older than 48 hours
      (idempotency keys are only meaningful for retry windows;
      unbounded growth otherwise)
- [ ] Daily FX-rate refresh job populates `fx_rates` from external
      source (e.g. exchangerate-api.com); falls back to last-known
      rate if external source is down
- [ ] Weekly `pg_dump` export to GCS confirmed running

### `11a.11d` - Proxy counter wiring + smoke test

- [ ] Idempotency check wired on every proxy request
      (`proxy_requests` UPSERT by `idempotency_key`; retried
      requests return prior `response_payload` instead of
      re-executing)
- [ ] Counter writes use **atomic UPSERT** for `usage_logs`:
      `INSERT ... ON CONFLICT (operator_id, location_id,
      usage_class, period_start) DO UPDATE SET
      token_count = usage_logs.token_count + EXCLUDED.token_count,
      request_count = usage_logs.request_count + 1,
      cost_usd = usage_logs.cost_usd + EXCLUDED.cost_usd`.
      Prevents lost updates when two requests for the same
      operator/location/class hit different Cloud Run instances
      simultaneously
- [ ] Cap lookup per `(operator_id, location_id, usage_class)`
      from `usage_caps` table
- [ ] Refusal payload returns clean machine-readable error
      with cap-status (current spend, cap, period reset date)
- [ ] `/health` endpoint runs **three real queries** on every
      probe: `SELECT 1` on Postgres, a one-row Cypher MATCH on
      AGE, a one-row similarity query on pgvector. Returns 200
      only if all three succeed; 503 with reason otherwise.
      A naive 200-OK probe fails to catch silent DB outages
- [ ] Cloud Run liveness/readiness probes configured to use
      `/health`
- [ ] All proxy routes use `/v1/...` URL versioning convention
- [ ] Per-request logging emits meta-only by default
      (operator_id, location_id, usage_class, token counts,
      latency, status)
- [ ] Per-operator opt-in flag in `feature_flags`
      (`request_logging_full_content`) enables full-content
      logging for that operator only when needed for support
- [ ] Cap-event notification: when an operator hits monthly cap,
      proxy emits an email or Slack webhook to F&F admin
- [ ] Smoke test: simulate over-cap operator without firing real
      provider calls; refusal payload validated
- [ ] Smoke test: simulate idempotent retry; second request
      returns cached prior result without re-executing
- [ ] Smoke test: simulate concurrency on counter writes; no
      double-counts

### `11a.11e` - Corpus + embedding live load

- [ ] Corpus build pipeline (`tool/advisor_corpus/`) runs against
      production proxy
- [ ] Pipeline is **idempotent** (re-runnable on partial failure;
      content-addressed chunk IDs prevent duplicate embedding work)
- [ ] Pipeline respects Voyage API rate limits: configurable RPS
      cap; 429 responses trigger exponential backoff with jitter
- [ ] Pipeline is **resumable**: an interrupted load can be
      restarted; already-embedded chunks (matched by chunk_id +
      content_sha256) are skipped, not re-embedded
- [ ] Partial-failure handling: if one chunk fails to embed after
      backoff retries, pipeline records the failure and continues
      with remaining chunks (does not halt entire load)
- [ ] All 233 chunks loaded with content-addressed IDs preserved
- [ ] Voyage embedding cost recorded (validates ~$0.05 estimate)
- [ ] Embedding rows stamped with `embedding_provider_id`,
      `embedding_model_id`, `embedding_dimension`
- [ ] AGE graph projection runs at production scale; smoke
      traversal succeeds (CPLH metric -> teaching chapter ->
      formula context returns expected nodes)
- [ ] Vector search returns expected candidates for known queries
- [ ] Voyage rerank returns expected ordering for known queries
- [ ] Old / inactive chunks remain queryable for replay (Q6
      content-addressed contract verified end-to-end)

### After `11a.11c-e` close

`11a.12` and `11a.13` were superseded 2026-04-25. Their scope (corpus
admin + pricing tier admin) has migrated into a dedicated new phase:

**Phase 11A — F&F Operations Console** (capital A; web/desktop admin
backend, distinct from `11a` advisor infrastructure):

- `11A.0` Flutter for Web bootstrap (route shell, Firebase Auth,
  deployed Cloud Run service at `admin.forgeflow.app`)
- `11A.1` Operator + location management (CRUD)
- `11A.2` Pricing tier admin (formerly `11a.13`)
- `11A.3` Corpus admin (formerly `11a.12`)
- `11A.4` Integration management
- `11A.5` Debug console
- `11A.6` Observability dashboard
- (`11A.7–10` polish slices interleave post-`11b`)

Plan: [phase_11A_operations_console_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md).

Build cadence resumes at `9.8` only after `11A.0–6` accept.

## Source Material

- [project_rag_vision.md](C:/Users/saidu/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_rag_vision.md)
- [Rag_Architecture.svg](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/reference/Rag_Architecture.svg)
- [corpus_manifest.yaml](C:/Git%20Local%20Repos/forge_flow_demo/docs/Knowledge_graph_docs/corpus_manifest.yaml)
- [phase_11a_0_corpus_manifest_ingestion_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_0_corpus_manifest_ingestion_contract.md)
- [phase_11a_1_manifest_validator_chunk_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_1_manifest_validator_chunk_plan.md)
- [phase_11a_2_ingestion_record_materializer.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_2_ingestion_record_materializer.md)
- [phase_11a_3_supabase_corpus_storage_schema.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_3_supabase_corpus_storage_schema.md)
- [phase_11a_4_db_loader_dry_run.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_4_db_loader_dry_run.md)
- [phase_11a_5_local_db_load_verification.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_5_local_db_load_verification.md)
- [phase_11a_6_embedding_contract_provider_prep.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_6_embedding_contract_provider_prep.md)
- [phase_11a_7_embedding_execution_local_load.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_11a/phase_11a_7_embedding_execution_local_load.md)
- [phase_11b_advisor_ux_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11b/phase_11b_advisor_ux_plan.md)

## Placeholder Notes

- Graph projection artifact status. `11a.0` defines the first node / edge
  taxonomy and provenance contract; `11a.3` stages graph seed storage; `7.57.4`
  added deterministic AGE projection and CPLH smoke-traversal SQL artifacts.
  Codex verification could not apply them locally because the `supabase` CLI is
  unavailable here. Before `11b`, run those artifacts in an AGE-enabled
  Supabase/Postgres environment or record the exact provisioning blocker.
- Vector embedding model choice locked for the first advisor corpus pass:
  Voyage `voyage-4-large`, 1024 dimensions, cosine retrieval. This is the
  Claude-aligned path because Anthropic does not provide native Claude
  embeddings and points Claude builders to Voyage; current Voyage docs list
  `voyage-4-large` as the best general-purpose / multilingual retrieval-quality
  option. The rerank lane is also locked for the first pass: Voyage
  `rerank-2.5` orders pgvector candidate chunks before Claude receives the
  grounded context. Voyage embedding execution landed in `11a.7`; rerank calls
  remain `11a.9`.
- Local embedding execution status: `11a.7` executed Voyage `voyage-4-large`
  embeddings for all 233 chunks using free-tier-safe batching, generated
  `embedding_updates.sql`, and loaded the vectors into the local
  Supabase/Postgres container. The local DB now reports 233 ready,
  `voyage-4-large`, non-null `vector(1024)` embeddings.
- Vector search artifact status: `11a.8` added versioned embedding metadata
  (`embedding_provider_id`, `embedding_model_id`, `embedding_dimension`), an
  HNSW cosine partial index for ready Voyage `voyage-4-large` 1024-dim rows,
  and `public.advisor_search_chunks(...)` for scoped candidate retrieval.
- Rerank smoke status: `11a.9` routes vector-search-style candidates through
  `RerankProvider`, orders by provider score, and preserves source/provenance
  metadata for the later Claude answer runtime.
- Proxy scaffold status: `11a.10a` added the server-side boundary for future
  AI calls. It loads configured secret names, fails closed without a real JWT
  verifier, and requires operator/location scope on protected routes.
  `11a.10b` added the launch-tier usage guard and counter-table scaffold for
  token, rate, and monthly cost caps; usage-protected routes fail closed until
  a real counter store is wired.
- Content-addressed chunk status: `11a.11a` changed source chunk IDs to a
  doc-prefixed content-hash form, added `active` to `advisor_source_chunks`,
  made load SQL mark stale chunks inactive without deletion, kept embedding
  updates matched by `chunk_id` + `content_sha256`, and made
  `advisor_search_chunks` active-only.
- Corpus storage live loader status. The manifest validator, chunk planner,
  build-only materializer, Supabase/Postgres schema scaffold, build-only SQL
  load-prep files, local Supabase Postgres load verification, and dry-run
  embedding job preparation are now available. `11a.11b` added
  `docs/phases/phase_11a/phase_11a_11b_cloud_db_apply_readiness.md`, which
  records that cloud DB apply is blocked here until Supabase CLI/config/link/env
  and target extension checks are available. Applying load files to a
  cloud/production database or calling the embedding provider still needs a
  separately scoped slice.
- Secret hygiene status: `security.env.1` sanitized `.env.local.example`
  placeholders and confirmed the file is ignored and untracked. Any prior real
  provider key represented by that local value must be rotated in the provider
  console; repo cleanup alone is not key rotation.
- Corpus admin UX status: `11a.12a` added the local-only Settings scaffold and
  pure local `AdvisorCorpusAdminService`. The surface previews pasted Markdown
  and displays the cloud-load blocker. `11a.12b` wired it into the debug app
  shell and disabled the blocked cloud-load action. `11a.12c` made preview
  output more ingestion-shaped while keeping it local-only.
- Post-11a sequencing note: 11a's local/repo scaffold is complete. Pause before
  opening the next lane and decide where to sequence the live infrastructure
  work captured by `11a.11b` (cloud migration apply, pgvector/AGE verification,
  corpus load, embedding load, and any proxy DB counter-store wiring needed
  before real 11b advisor behavior).

### Pre-ingest conversion status

The old Jim Taylor HTML conversion task is superseded. The active Jim Taylor
source for 11a ingestion is now:

- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`

Older archive references to the retired internal Barrio docs path remain
historical unless a later content-provenance cleanup explicitly scopes them.
Runtime Dart content references are not part of this 11a.0 corpus contract
slice.
