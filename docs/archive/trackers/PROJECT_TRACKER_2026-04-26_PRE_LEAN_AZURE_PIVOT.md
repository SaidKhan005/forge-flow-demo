# Forge & Flow Project Tracker

Updated: 2026-04-26
Owner: You
Execution model: We think, Claude codes

## Active Authority

- `PROJECT_TRACKER.md`
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/DATA_ALIGNMENT_TRACKER.md` only when the slice is alignment-heavy
- `docs/KNOWN_FAILING_TESTS.md` when a slice runs broad suites or hits a known red test

Archive:

- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Now

- Current phase: `11a` live-infrastructure sequence pivoted 2026-04-26.
  **Postgres host migrating from Supabase to Azure Database for PostgreSQL
  Flexible Server** (Canada Central, PG 16). Trigger: AGE is not on Supabase's
  curated extension allowlist, but is GA on Azure DB Flexible Server with
  Microsoft-authored docs, perf guides, and tooling. Migration is one-session
  scope because no production operator data exists yet — staging schema is the
  only live state. Path B (hybrid Supabase + Azure for AGE) explicitly
  rejected (dual-write tax). Path C (full migration to Azure) is the locked
  path. See `Locked Future Tweaks` for the rationale and rejected alternatives.
- Last accepted prompt: `11a.11c.3` verified the linked Supabase staging remote
  has all five migrations applied, pgvector/pgcrypto working, cloud-foundation
  constraints present, and AGE unavailable/fallback-only. **That work is now
  superseded by the Azure migration**; the Supabase staging project will be
  retired after the Azure swap completes.
- Next slice prompts for Codex to generate (locked sequence 2026-04-26):
  - **`11a.11c.4`** — Decision lock + tracker/phase-doc rewrite (this session).
  - **`11a.11c.5`** — Repo migration tooling re-targeted to Azure (code-only,
    no live apply). Move `supabase/migrations/*.sql` to `db/migrations/*.sql`;
    replace `supabase/config.toml` with a local Postgres + AGE + pgvector
    Docker compose for dev; replace `scripts/supabase_*.ps1` with
    `scripts/azure_pg_*.ps1` (Azure CLI + psql); rename
    `ProxySecretNames.supabaseUrl`/`supabaseServiceRoleKey` to
    `postgresUrl`/`postgresAdminUrl` (or equivalent); update
    `tool/advisor_corpus/`, `tool/advisor_proxy/`,
    `lib/services/advisor_corpus_admin_service.dart`,
    `test/advisor_proxy_test.dart`, `test/advisor_corpus_manifest_test.dart`;
    drop the Supabase CLI dev dependency from `package.json`. Acceptance: tests
    pass; no live DB calls; `dart analyze` clean.
  - **`11a.11c.6`** — Azure DB Flexible Server provisioning + extension verify
    + schema apply + AGE benchmark gate (live). Provision staging in
    `Canada Central` (PG 16, Burstable B1ms or B2s); allowlist `AGE`,
    `pgvector`, `pg_diskann`, `pgmq`, `pg_cron`, `pg_stat_statements`;
    configure `shared_preload_libraries`; configure firewall (Cloud Run egress
    allowlist or Private Link); enable 35-day PITR; apply all migrations;
    verify AGE Cypher MATCH, pgvector cosine, pg_diskann build; run AGE
    benchmark gate (now expected to PASS); insert `feature_flags` row
    `(graph_retrieval_mode = 'graph_first', ...)`. Acceptance: live extensions
    confirmed, all migrations applied, AGE benchmark documented, refusal
    fallback flag is `graph_first` (NOT `vector_only`).
  - **`11a.11d`** — Proxy counter table wiring + smoke (against Azure).
  - **`11a.11e`** — Corpus + embedding live load (against Azure; AGE projection
    actually executes for the first time).
  Then **Phase 11A F&F Operations Console** (`11A.0` Flutter-for-Web bootstrap
  → `11A.1` operator/location admin → `11A.2` pricing tier admin → `11A.3`
  corpus admin → `11A.4` integration management → `11A.5` debug console →
  `11A.6` observability dashboard), then resume the build cadence at `9.8`.
- Active planning input: `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`.
- Prompt loop: after each Claude report, Codex verifies repo truth, updates
  trackers, then generates the next prompt from updated tracker truth.
- Current live-integration scope: one restaurant/location at launch, but
  the schema is multi-location-ready (`(operator_id, location_id)` on
  every fact table) so org-level operators with multiple locations can
  onboard without a data migration.
- Naming guardrail: keep internal `Baseline` / `Schedule` names unchanged
  through `7.57` and Phase 8.

## Phase Board

| Phase | Status | Current truth |
| --- | --- | --- |
| `7.57` | complete | Stabilization accepted through `7.57.4`; completed plan archived. |
| `11a` | live infrastructure active; **Postgres host migration to Azure DB Flexible Server in flight** | Corpus, chunking, local Postgres load, Voyage embeddings, embedding load, AGE projection artifacts, vector search, rerank smoke, proxy scaffold, proxy usage enforcement, replay-safe content-addressed chunks, cloud DB readiness blocker capture, local env-example hygiene, debug-wired corpus admin preview, cloud-foundation migration, and linked staging schema verification (against Supabase) are landed but the Postgres host is now migrating to Azure DB Flexible Server (Canada Central, PG 16) because Supabase does not ship Apache AGE. Next gates are `11a.11c.4` (decision lock + doc rewrite — this session), `11a.11c.5` (repo tooling re-target, code-only), `11a.11c.6` (Azure provisioning + apply + AGE benchmark gate, live), then `11a.11d` proxy counter wiring against Azure, then `11a.11e` corpus + embedding live load against Azure. Hard Promise #5 returns to its original "AGE traversal ships before 11b" posture; the Q12 vector-only fallback remains as resilience insurance, default `graph_first`. |
| `11A` | queued (capital A) | F&F Operations Console — web/desktop admin backend. Foundation slices (`11A.0–6`) open after `11a.11c-e` close and before `9.8`; polish slices (`11A.7–10`) interleave post-`11b`. New phase added 2026-04-25; supersedes the earlier `11a.12` and `11a.13` Flutter-Settings framing. Plan: `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`. |
| `7.58` | queued | Pre-11b behavioral alignment lane. Opens after `9.5`; closes before `11b.0`. |
| `7.61` | queued | Pre-Phase-8 freshness audit. Opens after `10b`; closes before Phase 8. |

Completed phase history was moved to
`docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

## Current Slice Queue

`11a` live-infrastructure sequence (re-locked 2026-04-26 with Postgres host
migration to Azure DB Flexible Server inserted before `11a.11d`):

1. **`11a.11c`** — Postgres host migration + cloud schema apply +
   extension verify + schema apply (full Tier 1 + Tier 1.5 schema in
   one atomic migration: foundational identity tables, audit columns,
   `usage_logs`, `usage_caps`, `proxy_requests` for idempotency,
   `feature_flags`, `fx_rates`, vector versioning columns on
   embeddings, RLS policy stubs, FK cascades, CHECK constraints) +
   AGE benchmark gate.
   - `11a.11c.1` accepted: local cloud-foundation migration
     `202604250005_advisor_cloud_foundation.sql` plus migration tests.
     (SQL is portable; reused under Azure.)
   - `11a.11c.2` accepted as a BLOCKED staging-apply report: preflight
     found Supabase CLI/config/link/env/project prerequisites still missing,
     so no live commands ran. **Superseded 2026-04-26** by Azure migration.
   - `11a.11c.3` accepted: all five migrations are recorded on the linked
     Supabase staging remote, read-only SQL verification passed, and AGE
     is unavailable. **Superseded 2026-04-26**: Supabase staging will be
     retired after Azure swap; this verification proves the SQL is portable
     but the host pivots.
   - **`11a.11c.4`** (this session) Decision lock + tracker / phase doc
     rewrite for full Postgres host migration to Azure DB Flexible Server
     (Canada Central, PG 16). Hard Promise #5 returns to "AGE traversal
     ships before 11b". No code changes in this slice.
   - **`11a.11c.5`** Repo migration tooling re-targeted to Azure (code-only,
     no live apply). Folder rename `supabase/migrations/*.sql` →
     `db/migrations/*.sql`; replace `supabase/config.toml` with a local
     Postgres + AGE + pgvector Docker compose (`docker-compose.dev.yml`)
     for dev; replace `scripts/supabase_*.ps1` with `scripts/azure_pg_*.ps1`
     (Azure CLI + psql); rename `ProxySecretNames.supabaseUrl` /
     `supabaseServiceRoleKey` to `postgresUrl` / `postgresAdminUrl`;
     update `tool/advisor_corpus/`, `tool/advisor_proxy/`,
     `lib/services/advisor_corpus_admin_service.dart`,
     `test/advisor_proxy_test.dart`, `test/advisor_corpus_manifest_test.dart`
     to use the new paths and secret names; drop `supabase` dev
     dependency from `package.json`. Acceptance: tests pass, no live
     DB calls, `dart analyze` clean. Mark
     `docs/phases/phase_11a/phase_11a_11c2_staging_apply_report.md`,
     `phase_11a_11c3_staging_apply_report.md`,
     `phase_11a_11c3_staging_apply_result.md`,
     `phase_11a_11b_cloud_db_apply_readiness.md` as Supabase-historical.
   - **`11a.11c.6`** Azure DB Flexible Server provisioning + extension
     verify + schema apply + AGE benchmark gate (live). Provision
     staging in `Canada Central` (PG 16, Burstable B1ms or B2s); allowlist
     `AGE`, `pgvector`, `pg_diskann`, `pgmq`, `pg_cron`,
     `pg_stat_statements` via `azure.extensions` server parameter;
     configure `shared_preload_libraries`; enable 35-day PITR; configure
     firewall (Cloud Run egress allowlist or Private Link); apply all
     migrations from `db/migrations/`; verify AGE Cypher MATCH, pgvector
     cosine, pg_diskann build with sample queries; apply 7.57.4 AGE
     projection schema (now actually executes); apply 11a.8 pgvector
     HNSW (or evaluate switch to pg_diskann); run AGE benchmark gate at
     1K and 10K operator scale (now expected to pass on dedicated host);
     insert `feature_flags` row
     `(graph_retrieval_mode, NULL, NULL, true)` defaulting to graph-first
     (Q12 vector-only fallback remains in code as resilience). Acceptance:
     live extensions confirmed, all migrations applied, AGE benchmark
     documented, default retrieval mode is graph-first.
2. **`11a.11d`** — Proxy counter table wiring + smoke test
   (idempotency check, cap lookup, refusal payload, `/health` endpoint
   running three real queries — `SELECT 1` + AGE Cypher MATCH +
   pgvector cosine, `/v1/` URL versioning, meta-only logging by
   default). Now runs against Azure.
3. **`11a.11e`** — Corpus + embedding live load via
   `VoyageEmbeddingProvider`. Validates cost-reality estimate (~$0.05
   for 233 chunks). AGE graph projection actually executes at production
   scale; smoke traversal succeeds (CPLH metric → teaching chapter →
   formula context returns expected nodes).

Then **Phase 11A F&F Operations Console** (web/desktop admin
backend; supersedes the earlier `11a.12` / `11a.13` Flutter-Settings
framing):

4. **`11A.0`** — Flutter for Web bootstrap; brand styling; route
   shell; Firebase Auth integration; deploys at
   `admin.forgeflow.app`.
5. **`11A.1`** — Operator + location management (CRUD on
   `operators`, `locations`, `users`, `operator_admins`).
6. **`11A.2`** — Pricing tier admin (table editor for `usage_caps`
   per `(operator_id, location_id, usage_class)` — replaces the
   earlier `11a.13` scope).
7. **`11A.3`** — Corpus admin (drag-and-drop markdown upload, diff
   view, rollback — replaces the earlier `11a.12` scope).
8. **`11A.4`** — Integration management (Anthropic / Voyage key
   rotation, vendor connector status, FX-rate source).
9. **`11A.5`** — Debug console (per-operator request log viewer).
10. **`11A.6`** — Observability dashboard (system health, latency,
    error rate, cost-by-operator, cap-event stream).

Then resume the build cadence at **`9.8`** (compliance + commercial).
Phase 11A polish slices (`11A.7–10`: feature flag admin, API version
mgmt, audit log review, status page mgmt) interleave post-`11b`.

## Hard Gates

- `7.57.0` rules + five hard promises accepted.
- `7.57.1` legacy fixture extraction accepted with demo mode visually
  unchanged.
- `7.57.2a` state-holder / refresh-coordinator move accepted.
- `7.57.2b` demo fixture / DB helper move accepted.
- `7.57.2c` runtime read-service move accepted.
- `7.57.2d` baseline / benchmark service cluster move accepted.
- `7.57.2e` TargetCycleService move accepted.
- `7.57.2f` ShiftService move accepted.
- `7.57.2g` ShiftDataSource move accepted; `7.57.2` parent sweep closed.
- `7.57.3a` provider interfaces/adapters accepted; dev advisor model routing
  is configurable, visible in Settings, and update-aware.
- `7.57.3b` advisor corpus embedding execution now routes through
  `VoyageEmbeddingProvider`.
- `7.57.3c` StaticShiftDataSource mock-replay reads now route through
  `MockReplayDataSourceProvider`.
- `7.57.3d` renamed the answer-provider seam to `LLMProvider` and exposed
  prompt-caching capability; `7.57.3` parent provider abstraction is accepted.
- `7.57.4` AGE projection artifacts accepted; live AGE apply was not run here
  because no AGE-enabled host was provisioned at the time. Generated SQL
  carries an explicit `AGE_BLOCKER` path and smoke traversal evidence;
  `7.57` is closed. Live AGE apply is now scheduled for `11a.11c.6` against
  Azure DB Flexible Server (where AGE is GA).
- `11a.8` vector search schema/functions accepted: versioned embedding
  metadata, HNSW cosine partial index, and `advisor_search_chunks` candidate
  retrieval landed as generated SQL/build artifacts.
- `11a.9` rerank smoke accepted: vector-search-style candidates now route
  through `RerankProvider`, preserve citation metadata, and stay fake-tested
  without live Voyage calls.
- `11a.10a` proxy scaffold accepted: server-side config reads secret values by
  name, JWT verification is interface-based, protected routes require
  operator/location scope, and the Cloud Run-ready scaffold performs no live
  provider or DB calls.
- `11a.10b` proxy usage enforcement accepted: launch-tier request token cap,
  per-minute rate cap, monthly cost cap, machine-readable refusal policy,
  fail-closed counter-store seam, usage smoke route, and RLS-enabled usage
  counter migration landed without live provider or DB calls.
- `11a.11a` content-addressed corpus chunks accepted: chunk IDs now change when
  content changes, same-content chunks across docs do not collide, load SQL
  marks stale chunks inactive without deleting them, zero-current-chunk docs
  still deactivate prior chunks, vector search filters to active chunks, and
  embedding updates remain matched by `chunk_id` + `content_sha256`.
- `11a.11b` cloud DB readiness audit accepted as blocker capture: the readiness
  doc inventories all four advisor migrations, records that live apply was
  blocked at the time by missing Supabase CLI/config/link/env and unverifiable
  target extensions, and provides the later human apply/verification runbook.
  No live DB apply was performed. **Superseded 2026-04-26** by Azure migration
  (`11a.11c.4-6`); the readiness doc retained as Supabase-historical and
  marked as such.
- `11a.11c.1` cloud foundation migration accepted: the next lexicographic
  migration adds Tier 1 + Tier 1.5 identity/support schema (`operators`,
  `locations`, `users`, `operator_admins`, `usage_logs`, `usage_caps`,
  `proxy_requests`, `feature_flags`, `fx_rates`) with audit columns,
  non-negative/shape checks, RLS service-role policy stubs, partitioned
  `usage_logs`, and composite `(operator_id, location_id)` constraints that
  reject cross-operator location mismatches. SQL is portable; `11a.11c.5`
  relocates it to `db/migrations/` and `11a.11c.6` applies it to Azure.
- `11a.11c.3` staging schema verification accepted: the
  report at
  `docs/phases/phase_11a/phase_11a_11c3_staging_apply_report.md` confirms all
  five migrations are recorded against the linked Supabase staging remote,
  `pgcrypto` and `vector 0.8.0` are installed, pgvector smoke passed,
  RLS/schema/constraint checks passed, and AGE is unavailable/fallback-only.
  **Superseded 2026-04-26** by Azure migration: the SQL portability is
  re-confirmed but Supabase staging is being retired; live host pivots to
  Azure DB Flexible Server (`Canada Central`, PG 16) per `11a.11c.4-6`. The
  Supabase staging project will be deleted after Azure apply completes.
- `security.env.1` local env hygiene accepted: `.env.local` is the canonical
  private operator env file for Postgres/Anthropic/Voyage local work. It is
  ignored, untracked, and must not be committed or deleted by future repo
  changes. `.env.local.example` is no longer the canonical place for real
  secrets. `11a.11c.5` updates the env-name conventions from `SUPABASE_*` to
  `POSTGRES_*` / `AZURE_*` while preserving the gitignore guarantee.
- `11a.12a` corpus admin local scaffold accepted: Settings now has an
  injectable/dev-gated `ADVISOR CORPUS` surface backed by a pure local service
  that previews pasted Markdown, rejects non-Markdown/blank content, and
  surfaces the `11a.11b` cloud-load blocker without live calls.
- `11a.12b` corpus admin debug wiring accepted: the debug app Settings route
  now injects `AdvisorCorpusAdminService`, release/default hiding remains
  gated, and the cloud-load control is disabled rather than clickable while
  blocked.
- `11a.12c` corpus admin preview metadata accepted: the local Settings preview
  now exposes normalized file/source identity, deterministic title fallback,
  heading count, estimated chunk count, and UI rendering while remaining
  local-only with cloud load blocked.
- All five `7.58` sub-slices must accept before `11b.0` opens.
- Phase 9 RLS must be real and tested before `11b` ships to multiple
  operators.
- All four `7.61` sub-slices must accept before Phase 8 opens.

## Active Guardrails

- Build cadence is sequential, not parallel (updated 2026-04-25 to
  insert Phase 11A F&F Operations Console after 11a live infra and
  before 9.8):
  `[7.57] -> 11a.11c-e -> [11A.0-6 admin foundation + ops readiness] -> 9.8 -> 9 -> 10a -> 10.5 -> 9.5 -> [7.58] -> 11b -> 9.75 -> 11b.2 -> [11A.7-10 admin polish, interleave] -> 10b -> [7.61] -> 8 -> 8R`.
- Demo mode persists forever. `kDemoMode = true` fills SQLite from
  `mock_integration_replay_seed.dart`; `kDemoMode = false` fills the same
  tables from vendor connectors. Same tables, read paths, UI, and advisor
  behavior.
- Phase 8 is a pure transport swap. If Phase 8 discovers fixture extraction,
  service moves, freshness audits, or behavior decisions, that work belongs in
  `7.57`, `7.58`, or `7.61`.
- No app logic changes before `7.58`. `7.57` through `9.5` close is docs,
  file moves, abstractions around existing behavior, or additive capability.
- Per-operator isolation is non-negotiable, and the schema is
  multi-location-ready from day one. Operator-scoped Postgres fact
  tables (shifts, cycles, plans, weekly snapshots, variance, history)
  carry `(operator_id, location_id)` plus RLS policy stubs from
  creation. Single-location operators run with a default
  `location_id`. Corpus / methodology stays `operator_id`-scoped. RLS
  enforcement turns on in Phase 9; retrofit is not an option once
  facts exist. Decided 2026-04-25.
- Time-storage rule for operator-scoped Postgres fact tables:
  `TIMESTAMPTZ` (UTC) for source-truth instants plus a denormalized
  `business_date` `DATE` column computed at write using
  `location.timezone` (IANA, per-location) +
  `business_day_rollover_hour`. `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables — silent DST corruption is
  unrecoverable. `business_date` is write-once, never recomputed at
  read. Decided 2026-04-25.
- Repository-pattern enforcement: app code reads/writes
  operator-scoped Postgres tables only through
  `OperatorScopedRepository<T>` (or equivalent), which injects
  `(operator_id, location_id)` from the current `OperatorContext`.
  Raw `package:postgres` imports are forbidden outside
  `lib/infrastructure/persistence/postgres/`; CI lint enforces.
  Postgres RLS stays enabled on every operator-scoped table as the
  safety net underneath. Two-layer defense — repository wrapper is
  the primary protection, RLS is the backup. Decided 2026-04-25.
- AGE projection artifacts are in repo. Live AGE apply is scheduled for
  `11a.11c.6` against Azure DB Flexible Server (where AGE is GA). Before
  `11b` starts, AGE traversal must be live (Hard Promise #5).
- **Postgres host = Azure DB Flexible Server, `Canada Central`, PG 16.**
  Decided 2026-04-26. Rationale: Apache AGE is GA on Azure with
  Microsoft-authored documentation, performance guides, and tooling, but is
  not on Supabase's curated extension allowlist. Azure also has `pg_diskann`
  (faster vector search than HNSW per Microsoft benchmarks), TimescaleDB
  (useful for `usage_logs` / `proxy_requests` / `fx_rates` analytics),
  35-day PITR (vs Supabase 7-day), and better Toronto co-location with
  Cloud Run `northamerica-northeast2`. Supabase-specific value-adds
  (Auth, Storage, PostgREST, Realtime, Edge Functions) are not used by
  this project — Firebase Auth + Cloud Run + custom proxy already cover
  those concerns. Hybrid (Path B: Supabase ops + Azure for AGE)
  rejected — dual-write tax. Migration is one-session because no
  production operator data exists yet.
- Production Anthropic/Voyage/vendor keys must stay server-side. Flutter
  release/App Store/Play Store builds must not receive real API keys via
  `--dart-define`; 11b/Phase 8 must use a backend gateway for production
  provider calls.
- Advisor posture is recommendation-only, not action. Decided 2026-04-25:
  the advisor surfaces grounded recommendations with provenance and
  confidence ("I recommend X because Y"); operators decide whether to act.
  F&F never acts on the operator's behalf in the launch product.
  Liability: F&F provides advisory information; operator decisions and
  outcomes are the operator's sole responsibility, codified in Phase 9.8
  T&Cs. Workflow automation (Phase 12 post-launch) extends this with
  per-action consent — same posture, just covering automated actions.
- Service-layer split: `lib/data/` is legacy and frozen; `lib/services/` is
  runtime orchestration; `lib/domain/services/` is pure formula/domain logic
  with no I/O; state holders live in `lib/state/`.
- Schema migrations on production use online-migration patterns:
  `CREATE INDEX CONCURRENTLY` for indexes, two-step backfill for
  non-null defaults (`ADD COLUMN` without default → batched
  backfill → `SET DEFAULT`), `ADD CONSTRAINT ... NOT VALID` followed
  by `VALIDATE CONSTRAINT` for new constraints on populated tables.
  Long-locking migrations are forbidden once real operator data
  exists. Decided 2026-04-25.

## Locked Future Tweaks

- `7.57.3`: `LLMProvider.answer(..., tier)` routes `quick` -> Haiku
  and `nuanced` -> Sonnet; default `quick`. Renamed from
  `AdvisorAnswerProvider` per hard promise #8 (general-purpose AI
  infrastructure); rename folds into `7.57.3c` or a small `7.57.3d`.
- `7.57.3` / `11a.10`: Anthropic prompt caching exposed via
  `Capability.promptCaching` — ~10x reduction on repeated context
  (system prompt, methodology). Generic capability flag so the
  abstraction stays portable across providers.
- `11a.10` is the proxy backend (formerly framed as MCP tool layer).
  Two launch-blocking sub-slices:
  - `11a.10a` proxy infrastructure — Cloud Run service, key vault,
    JWT-auth, operator scoping. F&F's master Anthropic + Voyage
    keys live here; client app never holds them. Health check
    endpoint (`/health`) confirms DB + AGE + pgvector live so
    Cloud Run liveness/readiness probes route correctly.
  - `11a.10b` per-operator/location/usage-class enforcement.
    Counter table (`usage_logs`) keyed on `(operator_id,
    location_id, usage_class, period_start)` with `usage_class` as
    `TEXT` for extensibility (Phase 12 workflow types, future
    staff coaching, future onboarding agents — all reuse the same
    table without schema migration). Cap table (`usage_caps`)
    keyed on `(operator_id, location_id, usage_class)` with
    `monthly_cap_usd` and `per_invocation_cap_usd` columns. Cap
    values stored in USD; display layer converts to operator
    currency at render time. Refusal policy returns clean error
    with cap-status payload. Idempotency on every request via
    `proxy_requests` table (UNIQUE on idempotency key, with
    `request_type` column so Phase 12 tool calls reuse the same
    table). Admin dashboards on top of these tables are flagged
    separately (`11a.10c`, post-100-locations); editable admin UX
    lives in `11A.2` Pricing tier admin (Phase 11A Operations
    Console).
- `11a.10d` provider fallback chains (capability, off by default) —
  Anthropic primary → secondary → OpenAI `gpt-4o-mini` fallback.
  Architecture supports it; implementation deferred until production
  data shows it's needed. Lighting it up requires a multi-week
  investment to integrate the second provider and prompt-tune. Q7
  default at launch is hard-fail with a clear error message.
- `11a.11a` landed content-addressed corpus chunks: chunk ID is doc-prefixed
  and hash-based, any content change produces a new chunk ID, old chunks stay
  in the corpus marked inactive rather than deleted, and advisor search filters
  to active chunks. `11a.11b` owned cloud DB apply/readiness and exact blocker
  capture; 2026-04-26 supersession routes the live apply work into the Azure
  migration sequence (`11a.11c.4-6`).
- `11a.11b` landed the cloud DB readiness artifact at
  `docs/phases/phase_11a/phase_11a_11b_cloud_db_apply_readiness.md`. The
  Supabase prerequisites have been replaced by the Azure DB Flexible Server
  provisioning runbook in `11a.11c.6`; original artifact retained as
  Supabase-historical.
- ~~`11a.12` corpus admin UX~~ — **superseded 2026-04-25** by
  `11A.3` (corpus admin in the F&F Operations Console). Same
  pipeline (markdown → chunks → content-hash → embed via Voyage →
  Postgres), better surface (web/desktop drag-and-drop instead of
  in-app Settings page).
- ~~`11a.13` pricing tier admin Settings UX~~ — **superseded
  2026-04-25** by `11A.2` (pricing tier admin in the F&F Operations
  Console). Same scope (edit `usage_caps` per `(operator_id,
  location_id, usage_class)` with audit columns), better surface.
- **Phase 11A F&F Operations Console** (new phase decided
  2026-04-25, supersedes the prior `11a.12` and `11a.13` Flutter-
  Settings framing). Web/desktop admin backend hosted at
  `admin.forgeflow.app` on a separate Cloud Run service. Tech
  stack: **Flutter for Web** (reuses `app_theme.dart` brand,
  single Dart codebase across mobile and web/desktop). Eleven
  sub-slices total; foundation slices (`11A.0–6`) launch-blocking
  before `11b`, polish slices (`11A.7–10`) post-launch. Full plan
  at `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.
  Sub-slices:
  - `11A.0` Flutter-for-Web bootstrap (route shell, Firebase Auth,
    deployed Cloud Run service)
  - `11A.1` Operator + location management
  - `11A.2` Pricing tier admin (table editor for `usage_caps`)
  - `11A.3` Corpus admin (drag-and-drop markdown, diff view,
    rollback)
  - `11A.4` Integration management (Anthropic / Voyage key
    rotation, vendor connector status, FX-rate source)
  - `11A.5` Debug console (per-operator request log viewer with
    meta-by-default, full-content opt-in toggle)
  - `11A.6` Observability dashboard (system health, latency p95/
    p99, error rate, cost-by-operator, cap-event stream)
  - `11A.7` Feature flag admin (edit `feature_flags` rows)
  - `11A.8` API version management (deprecation tracking)
  - `11A.9` Audit log review (`created_by`/`updated_by` queryable)
  - `11A.10` Status page management (incident creation, post-
    mortems, sync to public `status.forgeflow.app`)
  - `11A.11` (optional, post-launch) Replay tool — re-run a past
    request against current corpus + model
- **`11a.11c` / `11a.11d` / `11a.11e` live infrastructure** (re-locked
  sequence 2026-04-26 with Postgres host migration to Azure inserted):
  - `11a.11c` Postgres host migration to Azure DB Flexible Server +
    cloud schema apply + extension verify + AGE benchmark gate.
    **Host**: Azure Database for PostgreSQL Flexible Server (PG 16).
    **Region**: `Canada Central` (Toronto, co-located with Cloud Run
    `northamerica-northeast2`). **Tier**: Burstable B1ms or B2s for
    MVP; scale to General Purpose D-series at multi-operator launch.
    **Point-in-time recovery**: enabled, 35-day retention.
    **Connection pooling**: built-in PgBouncer (transaction mode).
    **Extensions allowlisted via `azure.extensions`**: AGE, pgvector,
    pg_diskann, pgmq, pg_cron, pg_stat_statements. **Extensions
    loaded via `shared_preload_libraries`**: AGE, pg_cron,
    pg_stat_statements. **Networking**: firewall rule allows Cloud
    Run egress IPs (or Private Link in production). **Schema applies
    atomically** (Tier 1 + Tier 1.5 schema decisions, all in this
    slice's migration):
    - Foundational identity tables: `operators`, `locations`,
      `users`, `operator_admins`. RLS policy stubs dormant until
      Phase 9 turns enforcement on.
    - Operator-scoped fact tables carry `(operator_id, location_id)`
      + audit columns (`created_at`, `updated_at` `TIMESTAMPTZ`
      DEFAULT `now()`).
    - `usage_logs` counter keyed `(operator_id, location_id,
      usage_class, period_start)` with `usage_class` as `TEXT`.
    - `usage_caps` cap table keyed `(operator_id, location_id,
      usage_class)` with `monthly_cap_usd`, `per_invocation_cap_usd`,
      `created_by`, `updated_by`.
    - `proxy_requests` idempotency table (UNIQUE on key, with
      `request_type` column for Phase 12 reuse).
    - `feature_flags` table: `(flag_name TEXT, operator_id UUID
      NULL, location_id UUID NULL, enabled BOOL)`. Powers Q12
      retrieval-mode flag, Q8 streaming on/off when it lands,
      Phase 12 workflow access per operator, anything needing
      per-operator gating without redeploys.
    - `fx_rates` table for daily FX snapshots (USD / CAD / others
      as needed).
    - CHECK constraints on cost/token columns (`>= 0`) and other
      invariants (`business_date IS NOT NULL` where required).
    - Foreign keys on every `(operator_id, location_id)` reference
      with `ON DELETE CASCADE` (PIPEDA cascade-delete satisfies
      operator deletion).
    - Vector versioning columns on embeddings table:
      `embedding_provider_id`, `embedding_model_id`,
      `embedding_dimension` (locked earlier; ride the same
      migration).
    - RLS policy stubs on every operator-scoped table.
    **AGE benchmark gate** runs as part of this slice with simulated
    1K and 10K operator-scale synthetic data. AGE on Azure DB
    dedicated host is expected to pass; p95 > 500ms (isolated) or
    > 1000ms (10x concurrent) triggers Q12 fallback flag flip
    (`graph_retrieval_mode = 'vector_only'`) as a resilience switch.
    Default at launch is `graph_first` per Hard Promise #5.
  - `11a.11d` Proxy counter table wiring + smoke test. Per-request
    idempotency check (`proxy_requests` upsert by key); per-
    `(operator_id, location_id, usage_class)` cap lookup; refusal
    returns clean error with cap-status payload. **Health check
    endpoint** (`/health`) runs three real queries on every probe:
    `SELECT 1` on Postgres, a one-row Cypher MATCH on AGE, a one-row
    similarity query on pgvector. Returns 200 only if all three
    succeed; 503 with reason otherwise. Cloud Run liveness/readiness
    probes use `/health`. **API URL versioning** locked: `/v1/...`
    at launch. **Per-request logging** is meta-only by default
    (operator_id, location_id, usage_class, token counts, latency,
    status — no question text, no answer text); per-operator opt-in
    flag enables full-content logging when needed for support cases.
    Smoke test simulates over-cap operator without firing real
    provider calls.
  - `11a.11e` Corpus + embedding live load via
    `VoyageEmbeddingProvider` against the Azure-backed production
    proxy. Content-hashed chunk IDs preserve replay; embedding rows
    stamped with provider/model/dimension metadata. AGE graph
    projection runs at scale (first time AGE traversal executes
    live); validates the cost-reality estimate (~$0.05 for 233
    chunks). Pipeline is idempotent, resumable, and respects Voyage
    rate limits with exponential backoff.
- **Currency dual support (CAD default + USD)** (decided 2026-04-25).
  All internal cost accounting in USD (F&F pays providers in USD).
  `operators.preferred_currency` (CHAR(3), default 'CAD') selects
  display currency. Daily FX snapshots in `fx_rates` table from a
  cheap external service. Display layer (Settings UX, advisor cost
  display, billing summaries) converts USD → operator currency at
  render time. Subscription billing (Stripe etc., Phase 9.8) charges
  in operator's currency.
- **Feature flags table from day one** (decided 2026-04-25).
  Schema: `(flag_name TEXT, operator_id UUID NULL, location_id UUID
  NULL, enabled BOOL)`. Powers per-operator/per-location toggles
  without redeploys. Use cases: Q12 retrieval-mode flag (AGE vs
  vector-only), Q8 streaming on/off when it lands, Phase 12 workflow
  access per pilot operator, output-sanitization allowlist
  per-operator overrides, anything else needing gating.
- **Idempotency on proxy writes** (decided 2026-04-25). Every
  advisor-question and (future) tool-call request carries an
  idempotency key (UUID from client). Proxy stores keys in
  `proxy_requests` table with UNIQUE constraint. Retried requests
  find prior result instead of re-executing. `request_type` column
  generalizes the table for Phase 12 tool calls.
- **API URL versioning convention** (decided 2026-04-25). Paths
  under `/v1/...` at launch. Breaking changes ship at `/v2/...`;
  `/v1/` remains live until explicit deprecation policy. Codified in
  `CLAUDE.md` Proxy & API Conventions.
- **Tier 3 schema defaults approved** (decided 2026-04-25):
  - `FOREIGN KEY ... ON DELETE CASCADE` on every operator-scoped
    table's references to `operators` and `locations`. Operator
    cancellation cascades cleanly; PIPEDA "right to erasure"
    satisfied. Foreign keys everywhere on `(operator_id, location_id)`
    references — referential integrity, no orphan rows.
  - Per-request logging meta-only by default (operator_id,
    location_id, usage_class, token counts, latency, status). No
    question text, no answer text, no operator-typed content. Per-
    operator opt-in flag enables full-content logging for support.
- Post-launch caching layer for repeat advisor questions (Q7 option
  B, deferred). When production data shows specific question
  classes recurring, add a cache so an Anthropic blip surfaces
  "from N minutes ago" instead of an error. Off until evidence
  justifies.
- `LLMProvider.complete(...)` is non-streaming at launch (returns
  full response). Streaming arrives post-launch as a non-breaking
  additive method `completeStream(...)` returning a stream of
  events; existing `complete()` callers unaffected. Decided
  2026-04-25 (Q8 option A): pre-launch validation is about answer
  substance, not UX feel; SSE / mid-stream cost-cap edges add
  1–2 weeks of proxy work that doesn't change correctness.
- Prompt-injection defense at launch (decided 2026-04-25, Q9
  updated post-research). The actual defense at MVP is
  architectural — RLS + repository pattern + read-only + single-
  shot RAG + F&F-controlled corpus. The prompt-stack is hygiene on
  top, not the primary defense. MVP stack:
  1. **Base64-encode operator free-text fields** when injecting
     them into context (Microsoft Spotlighting "encoding" variant —
     ~2% attack success vs ~50% baseline in published tests).
     Replaces naive XML delimiter wrapping; system prompt
     instructs Claude to decode mentally and treat as data.
  2. **System-prompt scoping** — explicit instruction: "you only
     answer questions about restaurant operations using the
     provided context; decline anything off-topic." OWASP #1
     mitigation; free.
  3. **Output sanitization for markdown links and images** —
     strip / rewrite any URL or image in the model's response
     unless it points to an F&F-internal allowlist domain. This is
     the defense that would have prevented Slack AI (Aug 2024) and
     Microsoft EchoLeak (June 2025) exfiltration incidents. Cheap,
     high-impact.
  4. **Length caps on operator free-text fields** when injected
     into context (e.g., 500 chars on shift notes — separate from
     storage limits). Large injected blobs are an attack vector.
  5. Anthropic role separation (system vs user) used for
     structural clarity. Published 480-test study showed
     negligible security impact alone — kept as hygiene, not
     counted as a defense layer.
  Folds into `7.57.3c`/`3d` prompt-construction work; not a new
  slice. The actual link/image allowlist for output sanitization
  is flagged for Phase 9.8 commercial scope.
- **Multi-operator launch prompt-injection adds** (locked, lights
  up when 11b ships to multiple operators): (a) input-side
  classifier on operator queries — Meta's Llama Prompt Guard 2
  (free, fast, multilingual) is the default choice; (b) provenance
  markers in every context block (`<source operator="..."
  trust="...">`) so retrieval scoping is reviewable; (c) retrieval-
  scope audit — filter by `operator_id` BEFORE embedding similarity,
  not after (Slack AI Aug 2024 root cause); (d) adversarial test
  suite in CI, seeded from `tldrsec/prompt-injection-defenses`.
- **Phase 12 (write-tools / agent loops) prompt-injection adds** —
  this is where architecture changes, not just heavier filtering.
  Lights up when write-tools land:
  (a) Plan-Then-Execute or Action-Selector pattern (Simon Willison
      design patterns paper, June 2025) — tool calls are decided
      before the model sees retrieved or operator-supplied content;
  (b) Two-LLM separation (CaMeL-style) for any write path that
      touches operator-supplied content — quarantined LLM extracts,
      privileged LLM acts, symbolic variables only between them;
  (c) Human-in-the-loop **mandatory** for irreversible actions
      (schedule changes, comms, financial);
  (d) Tool-output classifier (Anthropic's auto-mode pattern) over
      every tool result before it re-enters agent context;
  (e) Egress allowlist — closed list of where automated workflows
      can reach;
  (f) Per-operator audit log of every tool call.
- **Cloud Run cold-start strategy** (decided 2026-04-25, Q11). At
  MVP: `min-instances=0` (accept ~5–15s cold-start latency on first
  request after ~15 min idle). Cost: $0 baseline; acceptable for
  single-operator beta. At multi-operator launch: flip to
  `min-instances=1` (always-warm proxy). Cost: ~$15–30/month per
  warm instance. Configurable at deploy time — no code change. Per-
  operator cost negligible at scale (one warm instance serves many
  operators). Avoids the "natural usage gap → 20s wait" UX hit
  once usage spreads across operators through the day. Skipped
  warmup pings (option C) — fragile, silent failure mode, no
  benefit over `min-instances=1`.
- **Graph backend fallback architecture** (decided 2026-04-25,
  Q12). The retrieval layer in `11a.8` / `11a.9` ships with a
  `mode: graph-first | vector-only` flag. AGE is the default at
  launch (hard promise #5); the vector-only mode is dormant
  insurance. Activates only if AGE benchmarks fail at production
  scale. Integration cost: ~half a day in `11a.8` / `11a.9` —
  vector-only path already exists alongside AGE; just exposing the
  mode selector through the retrieval API.
  **AGE benchmark gate**: before AGE is trusted for production,
  run it at simulated 1K and 10K operator-scale synthetic data; if
  graph-traversal queries hit p95 > 500ms, the fallback flag is
  the launch posture, not the contingency posture.
  **What "fallback activated" means**: advisor degrades to vector-
  only RAG (the same retrieval pattern every other AI advisor
  uses) — functional, just less differentiated. Hard promise #5
  remains met (AGE projection ships in 7.57.4); the differentiator
  is paused while Neo4j migration plans on a normal 6–9 week
  timeline if AGE truly cannot scale. Without this fallback, an
  AGE production failure forces a launch delay or a broken-advisor
  ship.
- **Agent runaway bounds** (decided 2026-04-25, Q10).
  At launch (extends `11a.10b`): per-request `max_tokens` enforced
  via `LLMProvider`; per-request HTTP wallclock timeout in the
  proxy (default 30s for the advisor); per-operator monthly cost
  cap (already locked). Catches single-request runaway with cheap,
  native API features.
  For Phase 12 (when write-tools land): per-task tool-call cap
  (default 20, tunable per pricing tier); per-task token cap
  (default $1.00 / 100K tokens, tunable); per-task wallclock cap
  (default 60s, tunable); per-operator parallel-task cap (default
  3, tunable). Enforcement is server-side in the proxy (extension
  of `11a.10b` counter table — per-task tracking alongside per-
  operator-monthly tracking). Client-side counters in the agent
  runtime as defense-in-depth.
  **Failure mode is graceful summary, not hard cut-off**: when a
  limit hits ~80%, agent runtime injects "summarize what you've
  found so far and conclude" instruction. Operator sees a partial
  result with a "task was cut short" badge — not an error wall.

## Forward Design Gaps (decisions to lock at the triggering phase)

These are not blocked by current architecture. They are *additions* to the
existing repository pattern + RLS-ready schema + provider abstractions, and
will be specced when their phase opens. Listed here so they don't get
forgotten between now and trigger. Decided 2026-04-26.

- **Per-operator vendor credential storage** (Phase 8R / Phase 12
  prerequisite). Schema: `vendor_credentials` table per
  `(operator_id, location_id, vendor_id)` with encrypted columns
  (encrypted-at-rest via `pgcrypto` envelope or Cloud KMS / Azure Key
  Vault). Stores OAuth tokens / API keys for operator's vendor systems
  (POS, payroll, etc.). Token-refresh logic lives in vendor-connector
  workers; admin rotation UX lives in `11A.4` Integration management.
  Trigger: first server-side vendor pull in Phase 8R, or Phase 12
  workflow reaching out to operator's external system. Until trigger,
  Phase 8 vendor connectors keep credentials on operator's device per
  Hard Promise #1's transport-swap discipline.
- **Operator fact data cloud sync** (Phase 12 prerequisite; partial in
  `11A.5` debug console). Schema is RLS-ready and `(operator_id,
  location_id)`-shaped from day one (already locked). Sync mechanism
  not yet designed — likely write-through-on-commit from operator app
  to Postgres via the same `/v1/...` proxy that handles AI calls, or
  CDC from operator-side SQLite. MVP impact: Phase 11A.5 debug console
  cannot see operator's actual shift schedule until sync exists; the
  advisor (Phase 11b) passes operator state inline with each query
  instead of reading from cloud. Trigger: Phase 12 workflow automation
  (workflows are server-side, must read operator data) or operator
  support volume that justifies richer 11A.5 debug.
- **Workflow execution state machine schema** (Phase 12). New tables:
  `workflow_definitions` (per operator), `workflow_runs` (execution
  instances), `workflow_steps` (step state, retries, errors),
  `workflow_audit_log` (compliance — who-triggered-what-when, write-tool
  actions). AGE-backed graph for workflow definition + traversal
  (workflows are inherently graph-shaped: nodes = steps, edges =
  transitions, conditions branch the path). Trigger: Phase 12 opens.
- **Long-running workflow execution path** (Phase 12). Cloud Run
  request handlers cap at 60 minutes. Workflow steps that exceed this
  (overnight batch, multi-hour reconciliation, large imports) run in
  a sibling Cloud Run jobs service (separate deployment from the
  request-handling proxy). Queue: `pgmq` (allowlisted on Azure DB) or
  Cloud Tasks. Per-task wallclock + token + tool-call caps already
  locked under "Agent runaway bounds". Trigger: Phase 12 opens.
- **Outbound webhook delivery** (Phase 12). Workflows emit events;
  operator's external systems (their dashboards, Slack, email)
  consume. Infrastructure: subscriber registry per `(operator_id,
  workflow_id, event_type, target_url)`; retry-with-exponential-
  backoff worker; dead-letter queue; HMAC signature on payload.
  Trigger: Phase 12 opens.
- **Per-operator backup / restore tooling** (post-launch ops). The
  Azure DB PITR + weekly `pg_dump` are DB-wide. Operator-scoped
  export ("send me a copy of my data"), operator-scoped restore
  ("restore me to last Tuesday"), and operator-scoped delete (PIPEDA
  / GDPR right-to-deletion) need explicit logic on top of the
  repository pattern's per-operator scope. Decision: build the
  tooling as `11A.5` follow-on or `9.8` legal/compliance sub-slice,
  whichever triggers first. Trigger: first off-boarding request,
  first compliance audit, or `9.8` lighting up data-rights surfaces.

## Soft Constraints (acceptable, awareness only)

These are real constraints already priced into the architecture. Listed
here so they're not rediscovered as "blockers" later. Decided 2026-04-26.

- **Cross-cloud egress costs.** Cloud Run (GCP `northamerica-northeast2`
  Toronto) → Azure DB (Azure `Canada Central` Toronto): ~$0.087/GB
  outbound from Azure, ~$0.08/GB outbound from GCP. Negligible at MVP
  (1GB free monthly egress on Cloud Run within North America); modest
  at 100+ operators. If it ever becomes meaningful, evaluate Private
  Link or VPC peering.
- **Cloud Run cold starts.** Phase 11b first-request latency on idle
  operators ~5-15s. Mitigation already locked: `min-instances=0` at
  MVP (single-operator beta), flip to `min-instances=1` (~$15-30/mo
  per warm instance) at multi-operator launch.
- **Single-region database.** Azure DB Flexible Server in `Canada
  Central` is single-region. Global expansion (operator outside North
  America gets ~150ms RTT) would need cross-region read replicas
  (Azure supports up to 30 cascading replicas) or active-active
  multi-region. Acceptable for MVP and North-America growth.
- **Base64 encoding token inflation.** Microsoft Spotlighting wraps
  retrieved operator content; ~33% token-cost inflation. Accepted in
  Q9/Q10 as the prompt-injection defense trade. Revisit only if
  Phase 11b cost-per-query becomes a concern.
- **AGE blocks in-place PG major version upgrades on Azure.** Annual
  / biennial Postgres major version upgrade requires drop+recreate of
  AGE schemas during the upgrade window. Documented by Microsoft.
  Manageable operational tax; ritualized in the Azure DB ops runbook
  (`11a.11c.6` deliverable).
- **Repository-pattern-only DB access.** Direct SQL admin tooling is
  forbidden (CI lint enforces); all admin actions go through the
  proxy's `/v1/admin/*` routes (Phase 11A Operations Console covers
  the UX gaps via `service_role` route). By design — preserves the
  two-layer-defense guarantee. Reflagged here so it's not surprise-
  rediscovered when Phase 11A.x admin scenarios trigger.
- **Voyage-only embeddings + Anthropic-only LLM at launch.**
  `EmbeddingProvider`, `RerankProvider`, and `LLMProvider`
  abstractions (Hard Promise #8) make swaps mechanical. No
  architectural lock-in; just economics.

## Flagged For Future Decision (parked at natural phase homes)

Pre-launch concerns that don't belong in `7.57` / `7.58` / `7.61` but need
a decision at the right moment. Codex prompts for them when their phase
opens.

- **Phase 9.8 (compliance) — Advisor T&Cs + liability disclaimer codification.**
  Operator-facing T&Cs that explicitly state F&F provides advisory
  information; operator decisions and outcomes are the operator's sole
  responsibility. Plus E&O insurance evaluation for AI advisory output.
  (Posture locked 2026-04-25 as recommendation-only; this flag tracks the
  legal/insurance work.)
- **Phase 9.8 (compliance) — Production observability (errors).**
  General application error tracking. Cheap path: Sentry free tier.
  (Advisor-answer audit log is a separate flag — see 11b.2 below.)
- **Phase 9.8 (commercial) — Output sanitization allowlist.**
  What URL domains are permitted in advisor responses? At minimum:
  an F&F-internal allowlist of allowed link / image hosts. Anything
  else gets stripped or rewritten. Pairs with the MVP prompt-
  injection stack above. Decision: write the allowlist before
  multi-operator launch.
- **Phase 9.8 (commercial) — F&F pricing tier model.** What
  subscription tiers exist, what cost cap each tier gets, which tier
  gets which model (Haiku-only vs Sonnet-on-demand). **Cost reality
  at Haiku-first tiered routing + prompt caching:** heavy operator
  (~100 questions/month) ≈ $0.10–$0.30/month; light operator (~20
  questions/month) ≈ $0.02–$0.06/month; embedding (one-time + on
  corpus update) ≈ $0.05 total at 233 chunks. A $5/operator/month
  cap leaves healthy margin on a typical SaaS subscription. Real
  cost risk is uncapped agentic loops in Phase 12 — cost cap +
  Haiku-default must be on before any write-tool ships.
- **`11a.10c` (post-100-locations) — Cost observability + admin
  dashboards.** Per-operator dashboards, daily / monthly aggregates,
  alert thresholds. Deferred 2026-04-25: too much overhead before
  100 locations. The counter table from `11a.10b` is enough for
  cost-cap enforcement until volume justifies the dashboard build.
- **Pre-multi-operator launch — Day-one observability stack.**
  Three small wires before any operator beyond Vanessa onboards.
  (a) Sentry free tier for client + proxy error reporting.
  (b) Azure Monitor (Postgres metrics) + Cloud Run built-in
  dashboards enabled. (c) Cap-event notifications: when an operator
  hits monthly cap or rate limit, the proxy emits an email or Slack
  webhook to F&F admin so you decide whether to bump the cap or
  wait. Free tier services cover all three. Decided 2026-04-25 as
  recommended for "really good product shipped"; lands as part of
  Phase 9.8 commercial scope or earlier if convenient.
- **Pre-multi-operator launch — Status page** (e.g.
  `status.forgeflow.app`). Trust signal for paid customers when
  any vendor (Azure DB, Cloud Run, Anthropic, Voyage) has an
  outage. Free tier services exist (Statuspage.io, BetterStack).
  Decided 2026-04-25.
- **Customer support per-operator debug view** (admin route,
  meta-only by default). When an operator emails support saying
  "the advisor said something weird at 2:47pm," F&F admin needs a
  way to find that exact request. Lists last N requests for a
  given `operator_id` with metadata only by default; full content
  visible only if the operator opted in via per-operator content-
  logging flag. Lands as part of `11A.5` Debug console (Phase 11A
  Operations Console). Decided 2026-04-25.
- **`11a.10d` (when production data justifies) — Provider fallback
  strategy.** Strategy specifics — Anthropic → OpenAI gpt-4o-mini,
  or Anthropic → Google Gemini Flash, or three-deep? Cost vs
  reliability trade-off. The capability is locked above; the
  strategy choice is the flag.
- **`11a.11c.6` (Azure cloud DB apply) — Production DB migration story.**
  Local Postgres + AGE + pgvector Docker compose -> Azure DB Flexible
  Server (Canada Central). Migrations applied via `psql` driver from
  CI / Cloud Run job; `db/migrations/` ordering preserved by filename
  prefix. PITR 35-day retention; weekly logical `pg_dump` snapshots
  to GCS for cross-cloud durability beyond PITR window.
- **`11b` runtime / `11b.2` polish — Advisor audit log (light).**
  Decided 2026-04-25: light audit only — question, answer, timestamp,
  `operator_id`, cost. No implementation now; parked for the 11b.2
  conversation. Pairs with the Phase 9.8 T&Cs flag above —
  recommendation posture is the legal shield, audit log is operational
  hygiene. Heavier schema (corpus version, retrieved chunks, prompt
  hash, replay tool) is a post-launch decision if a dispute ever
  surfaces.
- **New lane near `10b` close — Launch readiness checklist.** Day-1
  readiness pass. Markdown doc.
- **Post-launch (Phase 12 candidate) — Workflow automation lane.**
  Builds on the same provider abstraction + MCP tool layer; extends
  read-only tools to write-tools (schedule edits, notifications,
  plan adjustments). Per-workflow cost caps + agentic loop limits
  required before any write-tool ships. Demand signal: operator asks
  for "AI runs operations," or 10+ operators asking for the same
  workflow.

## Active Planning Docs

- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`
- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Phase docs for queued lanes remain under `docs/phases/`.

## Notes

- Detailed completed history now lives in
  `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
- Active architecture authority docs live under `docs/contracts/`.
- Completed phase docs live under `docs/archive/phases/`.
