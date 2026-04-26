# Phase 11a - Agentic Advisor Infrastructure

Updated: 2026-04-26
Status: Live infrastructure sequence active - **Postgres host migrating from Supabase to Azure DB Flexible Server** (locked 2026-04-26)
Owner: Future advisor infrastructure lane

Last review: 2026-04-23 - Backend stack pivoted from Firestore to Postgres with Apache AGE (graph) + pgvector (vectors). Rationale: native graph traversal via Cypher queries, native vector similarity, SQL for analytics, all in a single Postgres instance. Documented production pattern for "operational analytics + knowledge graph + semantic intelligence in a single engine" per Microsoft Azure's AGE + pgvector architecture guidance.

2026-04-26 update: **Postgres host migrating from Supabase to Azure Database for PostgreSQL Flexible Server (Canada Central, PG 16).** Trigger: Apache AGE is GA on Azure DB Flexible Server with Microsoft-authored documentation, performance guides, and tooling, but is not on Supabase's curated extension allowlist. Migration scope is one session because no production operator data exists yet — staging schema is the only live state. New sub-slices `11a.11c.4` (decision lock + doc rewrite, this session), `11a.11c.5` (repo tooling re-target, code-only), and `11a.11c.6` (Azure provisioning + apply + AGE benchmark gate, live) are inserted before `11a.11d`. Hard Promise #5 returns to its original "AGE traversal ships before 11b" posture (Q12 vector-only fallback retained as resilience insurance, default `graph_first`).

Current review: 2026-04-25 - `11a.0` established the active Markdown corpus
location, manifest authority, source inclusion/exclusion rules, chunking
profiles, graph node/edge taxonomy, and retrieval provenance contract. `11a.1`
added the local manifest validator plus chunk-plan dry run. `11a.2` added a
deterministic build-only materializer that emits source document, source chunk,
graph node seed, and graph edge hint records under `build/advisor_corpus/`.
`11a.3` added the Postgres schema scaffold for those record families,
including extension prep, RLS enablement, indexes, and placeholder policies.
`11a.4` added deterministic build-only SQL load preparation: ordered upsert
files plus a load manifest under `build/advisor_corpus/load/`. `11a.5` loaded
those records into a local Postgres container and verified counts,
pending embedding state, RLS enablement, and reference integrity. `11a.6`
added a dry-run embedding job preparer, then `11a.6a` revised the provider
contract to the Claude-aligned lane: Claude/Anthropic for future advisor
answers, Voyage `voyage-4-large` for embeddings, Voyage `rerank-2.5` for
candidate reranking, and `vector(1024)` in pgvector.
Local Voyage embedding generation is now complete and loaded into the local
Postgres container. `11a.8` added generated SQL for versioned
embedding metadata, HNSW cosine indexing, and `advisor_search_chunks` scoped
candidate retrieval. Cloud database apply, rerank calls, AGE live apply, MCP
tools, and agent UX remain future 11a/11b work.

Current review: 2026-04-25 - `7.57` stabilization is complete. `7.57.4`
added deterministic AGE projection and CPLH smoke-traversal SQL artifacts from
the staged graph seed tables. Codex local verification could not apply AGE
because no AGE-enabled Postgres host was provisioned at the time; generated
artifacts carry an explicit `AGE_BLOCKER` path. `11a` resumed at `11a.8`. Live
AGE apply is now scheduled for `11a.11c.6` against Azure DB Flexible Server.
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
`11a.11b` produced the cloud DB apply readiness audit (Supabase-historical;
superseded 2026-04-26 by Azure provisioning runbook in `11a.11c.6`). Live
apply was blocked at the time by missing Supabase CLI/config/link/env plus
unverifiable target extension availability; the repo has the migration
inventory and is now re-targeted at Azure DB Flexible Server in `11a.11c.5`.
`security.env.1` sanitized the ignored local env example so provider secret
names are placeholders only; the prior secret-looking Anthropic value must
be rotated outside the repo if it was real. `11a.11c.5` will rename
`SUPABASE_*` env names to `POSTGRES_*` / `AZURE_*`.
`11a.12a` added the local-only corpus admin Settings scaffold: an injectable
service validates pasted Markdown, returns deterministic local preview status,
rejects invalid input, and renders the 11a.11b cloud-load blocker without live
DB or provider calls. `11a.12b` wired the scaffold into the debug app Settings
route and made the cloud-load affordance non-interactive while blocked.
`11a.12c` enriched that preview with ingestion-shaped metadata: normalized
file/source identity, deterministic title preview, heading count, estimated
chunk count, and Settings display. This closes the local/repo-scaffold part of
11a. `11a.11c.1` then added the local cloud-foundation migration for the
Tier 1 + Tier 1.5 cloud schema: identity tables, usage/cap/idempotency/feature
flag/FX support tables, audit columns, RLS service-role stubs, declarative
`usage_logs` partitioning, and composite `(operator_id, location_id)`
constraints that reject cross-tenant location mismatches. SQL is portable;
host migration to Azure happens in `11a.11c.4-6`. `11a.11c.2` re-ran the
staging-apply preflight against Supabase and accepted a BLOCKED report
because Supabase CLI/config/link/env/project prerequisites were absent; no
live commands ran. `11a.11c.3` then verified the linked Supabase remote has
all five migrations recorded, pgvector/pgcrypto working, cloud-foundation
constraints present, and **AGE unavailable**. Both `11a.11c.2` and
`11a.11c.3` are now Supabase-historical; live host migrates to Azure DB
Flexible Server in `11a.11c.4-6`.

**`11a.11c.4` (decision lock — this session)** rewrites this plan,
`PROJECT_TRACKER.md`, `CLAUDE.md`, and adjacent phase docs for the Azure
migration. No code changes.

**`11a.11c.5` (repo tooling re-target)** moves migration files from
`supabase/migrations/` to `db/migrations/`; replaces `supabase/config.toml`
with a local Postgres + AGE + pgvector Docker compose; replaces
`scripts/supabase_*.ps1` with `scripts/azure_pg_*.ps1` (Azure CLI + psql);
renames secret names in `tool/advisor_proxy/`, tests, and corpus tooling;
drops the Supabase CLI dev dependency from `package.json`. Code-only; no
live DB calls.

**`11a.11c.6` (Azure provisioning + apply)** provisions Azure DB Flexible
Server in `Canada Central` (PG 16, Burstable B1ms or B2s), allowlists AGE +
pgvector + pg_diskann + pgmq + pg_cron + pg_stat_statements via
`azure.extensions`, configures `shared_preload_libraries`, configures
firewall (Cloud Run egress allowlist), enables 35-day PITR, applies all
migrations from `db/migrations/`, applies the `7.57.4` AGE projection
schema (live for the first time), applies the `11a.8` pgvector HNSW (or
evaluates pg_diskann), runs the AGE benchmark gate at 1K and 10K operator
scale, and inserts `feature_flags` row
`(graph_retrieval_mode, NULL, NULL, true)` defaulting to graph-first.

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
- **Corpus storage location: Azure Database for PostgreSQL Flexible Server
  (same instance as Phase 9 cloud schema).** Decision locked on 2026-04-23
  as Postgres-with-AGE-and-pgvector; specific host re-locked 2026-04-26 to
  Azure DB Flexible Server (Canada Central, PG 16) after discovering AGE is
  not on Supabase's curated extension allowlist but is GA on Azure DB.
  Rationale: the content model is natively multi-tenant (shared methodology
  + per-operator SOPs); Postgres with RLS handles per-operator scoping
  natively; the backend aligns with Phase 9 / 9.5 / 10a infrastructure;
  non-engineer authoring becomes a clean future path without repo-access
  gymnastics; AGE is GA on Azure with first-class Microsoft tooling and
  documentation.

  - Specific backend: Azure DB Flexible Server (PG 16) with Apache AGE
    extension (for graph traversal via Cypher queries), pgvector
    extension (for vector similarity search), and `pg_diskann` available
    as a future optimization for high-scale vector workloads. Extensions
    allowlisted via `azure.extensions` server parameter.
  - Admin-authored writes only (Said + Vanessa); Phase 9 auth roles gate
    write access via RLS policies on corpus tables.
  - Per-operator scoping baked in from day one even with a single
    operator - shared methodology documents are operator-independent
    (null `restaurant_id` or global scope); those global rows are shared
    founder-authored methodology only, never another operator's SOPs or
    metrics. SOP / training material is operator-scoped (`restaurant_id`
    set per row; RLS enforces).
  - Dev loop uses a local Postgres + AGE + pgvector Docker compose so
    dev work does not touch real data; no parallel-sequencing blocker vs
    Phase 9.

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
  Functions remains a path for Phase 9 auth admin ops if needed; 11a/11b
  run on Cloud Run. All services authenticate clients against Firebase
  Auth and read/write the same Azure DB Flexible Server (with RLS
  enforcement for user-scoped reads; a service-role connection for
  admin-scoped writes that bypass RLS, which Phase 11A admin routes use).

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
- Azure DB Flexible Server (Postgres) integration for corpus persistence,
  using Apache AGE for graph traversal, pgvector for vector similarity
  search, and RLS policies for per-operator scoping. Same Postgres
  instance as Phase 9 / 9.5 / 10a.

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
- Azure DB Flexible Server (Canada Central, PG 16) provisioned with
  AGE + pgvector + pg_diskann extensions allowlisted (can start with
  local Postgres + AGE + pgvector Docker compose for dev before
  production server is provisioned)

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

Repo scaffold (`11a.0` through `11a.12c`) is complete, and `11a.11c.1`
has added the local cloud-foundation migration artifact. The remaining
11a work is live execution. **Re-locked sequence 2026-04-26 with Postgres
host migration to Azure inserted before `11a.11d`:**
**`11a.11c.4` (this session, decision lock) → `11a.11c.5` (repo tooling
re-target, code-only) → `11a.11c.6` (Azure provisioning + apply, live) →
`11a.11d` (proxy counter wiring, against Azure) → `11a.11e` (corpus +
embedding load, against Azure)**, then resume the build cadence at the
F&F Operations Console (`11A.0–6`), then `9.8`. Tick items off as they
land.

### `11a.11c` - Postgres host migration + cloud schema apply + extension verify + AGE benchmark gate

**Sub-slice progress**

- [x] `11a.11c.1` local cloud-foundation migration accepted:
      `supabase/migrations/202604250005_advisor_cloud_foundation.sql`
      (relocates to `db/migrations/` in `11a.11c.5`) creates the Tier 1
      + Tier 1.5 identity/support schema with RLS stubs, partitioned
      `usage_logs`, and composite ownership FKs. SQL is portable.
- [x] `11a.11c.2` staging-apply preflight report (Supabase) accepted
      as BLOCKED. **Superseded 2026-04-26** by Azure migration; report
      retained as Supabase-historical.
- [x] `11a.11c.3` linked-Supabase-remote schema verification accepted
      with caveat (AGE unavailable). **Superseded 2026-04-26** by
      Azure migration; report retained as Supabase-historical and
      proves SQL portability.
- [ ] **`11a.11c.4` (decision lock — this session)**: Tracker, CLAUDE.md,
      and phase docs updated to reflect Azure DB Flexible Server as the
      Postgres host. Hard Promise #5 amended back to "AGE traversal
      ships before 11b". Forward design gaps and soft constraints
      catalogued in PROJECT_TRACKER.md. No code changes.
- [ ] **`11a.11c.5` (repo tooling re-target — code-only)**:
  - [ ] Move `supabase/migrations/*.sql` → `db/migrations/*.sql`
        (preserve filename ordering; SQL unchanged)
  - [ ] Replace `supabase/config.toml` with `docker-compose.dev.yml`
        running Postgres 16 + AGE + pgvector + pg_diskann for local dev
  - [ ] Replace `scripts/supabase_staging_preflight.ps1` →
        `scripts/azure_pg_staging_preflight.ps1` (Azure CLI + psql; same
        contract: env check, extension check, optional smoke queries)
  - [ ] Replace `scripts/supabase_staging_setup.ps1` →
        `scripts/azure_pg_staging_setup.ps1` (`az postgres flexible-server
        create` + firewall rules + extension allowlist)
  - [ ] Replace `scripts/use_supabase_staging_env.ps1` →
        `scripts/use_azure_pg_staging_env.ps1` (loads `POSTGRES_URL`,
        `POSTGRES_ADMIN_URL`, `AZURE_PG_RESOURCE_GROUP`, etc. from
        `.env.local`)
  - [ ] Update `package.json`: drop `"supabase"` dev dependency and
        related npm scripts; no replacement npm dep needed (Azure CLI
        installed separately)
  - [ ] Rename `ProxySecretNames.supabaseUrl` → `postgresUrl` and
        `supabaseServiceRoleKey` → `postgresAdminUrl` (or equivalent)
        in `tool/advisor_proxy/advisor_proxy.dart`; update doc comments
  - [ ] Update `tool/advisor_proxy/main.dart` doc comment ("Anthropic,
        Voyage, Postgres, Firebase" — drop "Supabase" mention)
  - [ ] Update `tool/advisor_corpus/advisor_corpus.dart` —
        `target_schema_migration` path: `db/migrations/...`
  - [ ] Update `lib/services/advisor_corpus_admin_service.dart` —
        comment refs (Postgres, not Supabase)
  - [ ] Update `test/advisor_proxy_test.dart` — secret-name fields and
        migration path strings
  - [ ] Update `test/advisor_corpus_manifest_test.dart` — migration
        path strings
  - [ ] Mark legacy reports superseded:
        `phase_11a_11b_cloud_db_apply_readiness.md`,
        `phase_11a_11c2_staging_apply_report.md`,
        `phase_11a_11c3_staging_apply_report.md`,
        `phase_11a_11c3_staging_apply_result.md` get a "Superseded
        2026-04-26 by Azure migration; retained as Supabase-historical"
        note at the top
  - [ ] Acceptance: `dart analyze` clean; existing tests pass; no live
        DB calls made
- [ ] **`11a.11c.6` (Azure provisioning + apply — live)**: see Setup
      and Extensions checklists below.

**Setup (Azure DB Flexible Server)**

- [ ] Azure DB Flexible Server **production** instance provisioned in
      `Canada Central` (Toronto), PG 16, **General Purpose D2s_v3** or
      higher (2 vCPU, 8GB RAM minimum) — Burstable tiers OK at MVP
      idle but General Purpose recommended for AGE workloads at scale
- [ ] Azure DB Flexible Server **staging** instance provisioned in
      same region (Burstable B2s acceptable; mirrors production schema;
      migrations land here first, validate with synthetic data, then
      promote to production)
- [ ] Point-in-time recovery enabled on production, **35-day**
      retention
- [ ] Weekly logical backup (`pg_dump`) scheduled to Google Cloud
      Storage with 90-day retention (cross-cloud durability beyond PITR)
- [ ] Built-in PgBouncer enabled on Azure DB; transaction-mode pooling
      configured
- [ ] Proxy backend (Cloud Run) env / KMS wired to Azure DB
      connection string (`POSTGRES_URL`, `POSTGRES_ADMIN_URL`)
- [ ] Networking: firewall rule allows Cloud Run egress IPs from
      `northamerica-northeast2` (Toronto), or Private Link configured
      for production
- [ ] Cloud Run `max-instances` capped so that
      `(max_instances * connections_per_instance) <=
      azure_db_max_connections * 0.7` (leaves headroom; prevents
      connection exhaustion during traffic spikes)

**Extensions (Azure DB Flexible Server)**

- [ ] `azure.extensions` server parameter set to allowlist:
      `AGE,VECTOR,PG_DISKANN,PGMQ,PG_CRON,PG_STAT_STATEMENTS`
- [ ] `shared_preload_libraries` includes `AGE,pg_cron,pg_stat_statements`
- [ ] Server restarted to apply server parameter changes
- [ ] `CREATE EXTENSION IF NOT EXISTS age CASCADE;` succeeds; sample
      Cypher MATCH query verified
- [ ] `CREATE EXTENSION IF NOT EXISTS vector;` succeeds; cosine
      similarity verified (`'[1,2,3]'::vector <=> '[1,2,4]'::vector`)
- [ ] `CREATE EXTENSION IF NOT EXISTS pg_diskann;` succeeds; sample
      DiskANN index build verified (consider switching from HNSW to
      DiskANN at `11a.8` if benchmarks justify)
- [ ] `CREATE EXTENSION IF NOT EXISTS pgmq;` succeeds (parked for
      Phase 12 workflow queue; verify availability now to avoid
      surprises later)
- [ ] AGE benchmark gate result: pass or fail-with-fallback documented

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
      10K-operator scale on Azure DB
- [ ] Representative graph-traversal queries run **in isolation**;
      p95 latency recorded
- [ ] Same queries run **under 10x concurrent load** (10 parallel
      traversals at the same time); p95 latency recorded
- [ ] AGE is the launch posture (Hard Promise #5);
      `feature_flags` row inserted for
      `(graph_retrieval_mode, NULL, NULL, true)` defaulting to
      graph-first
- [ ] If isolated p95 > 500ms OR concurrent p95 > 1000ms (unexpected
      on dedicated Azure DB host): the flag flips to
      `graph_retrieval_mode = false` (vector-only as resilience
      posture, NOT launch posture); benchmark blocker documented;
      tier upgrade evaluated (e.g., D2s → D4s) before considering
      Q12 fallback as default

**Acceptance**

- [ ] Azure DB Flexible Server live with AGE + pgvector + pg_diskann
      verified
- [ ] Staging instance mirrors production schema
- [ ] All Tier 1 + Tier 1.5 schema applied to both instances without
      manual fixes (migrations from `db/migrations/` apply cleanly)
- [ ] AGE benchmark gate result documented (pass or
      fail-with-fallback, including concurrent-load p95)
- [ ] AGE projection schema (7.57.4) applied; smoke traversal
      succeeds (CPLH metric → teaching chapter → formula context
      returns expected nodes)
- [ ] Proxy backend connects to Azure DB via built-in PgBouncer
      transaction pooling
- [ ] Cloud Run `max-instances` cap set against Azure DB connection-
      limit math

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
  Live AGE apply was previously blocked by lack of an AGE-enabled host. As of
  2026-04-26, the live host is locked to Azure DB Flexible Server (Canada
  Central, PG 16, where AGE is GA); AGE artifacts will apply for the first
  time in `11a.11c.6` and validated against the AGE benchmark gate.
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
  `embedding_updates.sql`, and loaded the vectors into the local Postgres
  container. The local DB now reports 233 ready, `voyage-4-large`, non-null
  `vector(1024)` embeddings. `11a.11c.5` switches the local container from
  the Supabase Docker stack to a generic Postgres + AGE + pgvector
  Docker compose.
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
  build-only materializer, Postgres schema scaffold, build-only SQL load-prep
  files, local Postgres load verification, and dry-run embedding job
  preparation are now available. Staging cloud DB apply was previously linked
  to a Supabase project (ref `tngrpfaddcologhrltyo`) and confirmed all five
  migrations are present, pgvector working, but **AGE was unavailable**.
  **As of 2026-04-26, the host pivots to Azure DB Flexible Server in
  `Canada Central`** (PG 16, AGE GA). The Supabase staging project is
  retired in `11a.11c.6` once Azure is verified. Applying corpus load files
  or calling the embedding provider runs in `11a.11e` against Azure.
- Secret hygiene status: `.env.local` is the canonical private operator env
  file for Postgres/Anthropic/Voyage local work. It is ignored and untracked,
  and future commits must not delete, rename, or commit it. Any prior real
  provider key represented by an example/local value must be rotated in the
  provider console; repo cleanup alone is not key rotation. `11a.11c.5`
  renames `SUPABASE_*` env names in `.env.local` conventions to
  `POSTGRES_*` / `AZURE_*`.
- Corpus admin UX status: `11a.12a` added the local-only Settings scaffold and
  pure local `AdvisorCorpusAdminService`. The surface previews pasted Markdown
  and displays the cloud-load blocker. `11a.12b` wired it into the debug app
  shell and disabled the blocked cloud-load action. `11a.12c` made preview
  output more ingestion-shaped while keeping it local-only.
- Post-11a sequencing note: 11a's local/repo scaffold is complete. Live
  infrastructure work runs in `11a.11c.4-6` (Azure migration), `11a.11d`
  (proxy counter wiring against Azure), and `11a.11e` (corpus + embedding
  load against Azure). Original `11a.11b` Supabase readiness inventory is
  retained as Supabase-historical.

### Pre-ingest conversion status

The old Jim Taylor HTML conversion task is superseded. The active Jim Taylor
source for 11a ingestion is now:

- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`

Older archive references to the retired internal Barrio docs path remain
historical unless a later content-provenance cleanup explicitly scopes them.
Runtime Dart content references are not part of this 11a.0 corpus contract
slice.
