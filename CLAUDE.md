# CLAUDE.md

## Authority Order

When sources conflict, later loses to earlier:

1. The active prompt.
2. `docs/contracts/**`.
3. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`.
4. The active phase doc named in the prompt (`docs/phases/**`).
5. This file.

`docs/archive/**` is history — ignore unless the prompt names it.
`docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures; treat them
as expected, not regressions.

## Hard Promises

Every slice respects these. Origin:
`docs/archive/phases/post_11a7_stabilization_plan.md`.

1. **Phase 8 = pure transport swap.** Vendor connector writers
   against existing SQLite tables only. Cleanup belongs to `7.57`
   (structural) or `7.61` (freshness). Phase 8 work that touches
   fixtures, services, or freshness surfaces as a `7.57`/`7.58`/`7.61`
   follow-up.
2. **Demo mode persists post-launch.** `kDemoMode` is a writer-side
   switch. True → `mock_integration_replay_seed.dart` fills SQLite.
   False → vendor connectors fill SQLite. Same tables, same reads,
   same UI.
3. **No app logic changes before `7.58`.** `7.57.0`–`9.5` are
   docs/governance, file moves, abstraction layers, or additive
   capability. `7.58.0` (Primary Driver audit) is the first
   logic-deciding slice.
4. **Per-operator isolation is non-negotiable.** RLS-ready schema
   from day one (see RLS-Ready Schema). Phase 9 enforces. `11b` does
   not ship multi-operator before then.
5. **AGE infrastructure live before `11b`; retrieval is Modular
   Adaptive Agentic RAG.** Schema landed in `7.57.4`; live apply at
   `11a.11c.6`. Advisor `11b` launches with Anthropic Contextual
   Retrieval; AGE traversal lights up incrementally (`11b.2` causal,
   Phase 12 workflows + coaching). Detail:
   `docs/phases/phase_11a/phase_11a_decision_register.md`.
6. **Advisor speaks in recommendations, not commands.** Decided
   2026-04-25: F&F provides advisory information; operator decides
   whether to act. F&F never acts on the operator's behalf in the
   launch product. Liability codification (T&Cs) lands in Phase 9.8.
7. **F&F holds all provider keys server-side.** No BYO-key path.
   Proxy backend in `11a.10` brokers all LLM/embedding calls.
   Client app never holds production keys; dev `--dart-define` is
   for local development only. Production keys live in Cloud Run
   env / KMS.
8. **AI infrastructure is general-purpose.** `LLMProvider`,
   `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider`,
   and (Phase 8.5) `IntegrationProvider` are not advisor-specific.
   The advisor (11b) is one consumer; workflow automation (Phase 12
   post-launch) will be another with the same plumbing.
9. **AI cost is metered by class.** Every AI surface carries
   `usage_class`; meterable per `(operator_id, location_id,
   staff_id NULL, workflow_id NULL, usage_class)` in `usage_logs` +
   `usage_caps`. No flat-rate AI at scale. Five cost-discipline
   levers (prompt caching, tier routing, response cache, precomputed
   summaries, batch API) keep margin 75-95%. Concrete tiers + caps:
   `docs/phases/phase_11a/phase_11a_decision_register.md`.

## Workflow

- Codex plans, reviews, advances trackers. Claude implements the
  scoped prompt, runs focused tests, reports back.
- Do not broaden scope.
- Do not update trackers during implementation unless the prompt asks.
- If docs move or are materially touched, update touched links and
  report `Links updated: yes/no`.

## Review Loop (user pastes an Execution Report)

1. Review changed files plus nearby runtime seams.
2. Issues found → return findings; keep the slice active.
3. Clean → Codex advances trackers and the next prompt.
4. Ignore stale findings if the current code no longer matches them.
5. User pivots into architecture, workflow, or docs cleanup → stop
   the prompt loop and consolidate.

## Service-Layer Split

- `lib/data/` — frozen legacy. Delete-only, never add.
- `lib/services/` — runtime orchestration.
- `lib/domain/services/` — pure formulas, no I/O.
- `lib/state/` — new state holders.
- `lib/dev/` — demo and dev-only material.
- `lib/infrastructure/persistence/sqlite/` — DB helpers.

## Architecture Guardrails

- `LaborModel` is the formula source.
- `TargetCycle` locks 60-day standards.
- `ActiveTargetProfile` is the runtime projection of the active cycle.
- `DemandForecastContext` is rolling demand, not standards.
- `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.
- Source facts, derived metrics, and teaching summaries stay separate.
- Widgets do not own source-truth or service-period bucketing.
- Shift's whole-day view is authoritative; `10.5` adds daypart
  alongside, never replacing.

## Time Guardrails

- Restaurant-local timing wins. Business date is the anchor.
- Week start, business-day rollover, and service periods are
  restaurant-owned settings.
- Closed truth is not rewritten by later cycles or weekly plans.
- **Storage rule (decided 2026-04-25):** operator-scoped Postgres
  fact tables store source-truth instants as `TIMESTAMPTZ` (UTC)
  plus a denormalized `business_date` `DATE` column computed at
  write time using `location.timezone` + `business_day_rollover_hour`.
  `location.timezone` is an IANA string on the `locations` table
  (per-location, not per-operator — multi-location operators may
  span zones). `TIMESTAMP WITHOUT TIME ZONE` is banned in
  operator-scoped tables (silent DST corruption). `business_date`
  is computed once at write, never recomputed at read.

Refs: `docs/contracts/phase_7_55_architecture_contract.md`,
`phase_7_55_time_boundary_contract.md`,
`phase_7_55_target_cycle_weekly_plan_rules.md`.

## RLS-Ready Schema

Operator-scoped Postgres fact tables (shifts, cycles, plans, weekly
snapshots, variance, history) include `(operator_id, location_id)`
plus an RLS policy stub from creation. Single-location operators run
with a default `location_id`. Corpus / methodology stays
`operator_id`-scoped. Phase 9 enables enforcement. Scaffolding is
not retrofitted later.

**Repository pattern (decided 2026-04-25, two-layer defense):** app
code reads/writes operator-scoped Postgres tables only through
`OperatorScopedRepository<T>` (or equivalent), which injects
`(operator_id, location_id)` from the current `OperatorContext`. Raw
`package:postgres` imports are forbidden outside
`lib/infrastructure/persistence/postgres/` — CI lint enforces.
Postgres RLS is the backup safety net under the repository, not the
primary defense.

**RLS performance discipline (locked 2026-04-26):**
- Every fact-table index has `operator_id` (or `(operator_id,
  location_id)`) as the leading column. Indexes leading with anything
  else (e.g., `business_date`) are forbidden on operator-scoped tables.
  Without this, RLS policy evaluation is two orders of magnitude
  slower. CI lint enforces.
- Proxy session-variable injection uses `SET LOCAL` (transaction-scoped),
  never `SET` (session-scoped). Pooled connection reuse must not carry
  tenant context across requests.

## Proxy & API Conventions

- API URL versioning: `/v1/...` paths today; `/v2/...` when
  breaking changes ship; old paths stay live until explicit
  deprecation.
- Every write the proxy does is idempotent. Clients carry an
  idempotency key per request; the proxy stores keys in
  `proxy_requests` (UNIQUE constraint). Retries return the prior
  result instead of re-executing.
- Every AI surface plugs into `11a.10`'s infrastructure (proxy +
  provider abstractions + counter/caps + feature flags). No
  parallel stacks. Phase 12 workflows, future Barrio staff
  coaching, and any future AI surface reuse the same plumbing.
- **Postgres host = Azure DB Flexible Server, `Canada Central`,
  PG 16.** Extensions: `AGE`, `pgvector`, `pg_diskann`, `pgmq`,
  `pg_cron`, `pg_stat_statements`. Migrations in `db/migrations/`.
  Direct `package:postgres` imports forbidden outside
  `lib/infrastructure/persistence/postgres/`.
- **Retrieval pattern**: Modular Adaptive Agentic RAG (Haiku
  classifier → SQL / Contextual Retrieval / AGE → Sonnet synthesis
  with prompt cache).
- **Real-time pattern**: Postgres `NOTIFY` → Cloud Pub/Sub →
  WebSocket bridge in proxy (Phase 10a builds it).
- **Cost-discipline levers default-on**: prompt caching, tier
  routing, response cache, precomputed summaries, batch API.

Architecture detail and rationale:
`docs/phases/phase_11a/phase_11a_decision_register.md`.

## Testing

- Run the smallest set that proves the seam.
- `dart analyze` whenever the prompt requires verification.
- "No rerun" prompts → do a code review instead.

## Phase Doc Hygiene

- Slice < 1 week AND < 5 files → inline in the tracker.
- Larger, or new contract → own phase doc.
- Closed phase docs retire to `docs/archive/phases/` within a week.

## Graph vs Grep

`rg` first when symbol, filename, import path, or literal text is
known. The `graphify` MCP server is for orientation:

- `shortest_path` — trace how unfamiliar concepts connect.
- `query_graph` — find which contract bullet covers a topic
  (returns `source_file` + `source_location`).
- Phase-lane orientation before opening files.

Skip god-nodes and community exploration unless Codex requests them.

## Knowledge Graph Refresh

`graphify-out/needs_update` exists → run `/graphify --update` as the
FIRST action of the next turn. This is the only sanctioned graphify
run mid-session. Brief acknowledgement first ("Refreshing the doc
graph from your last commit…"); do not promise a duration.

The hook excludes `docs/archive/**` and `graphify-out/**` via
`FROZEN_HISTORY_PATHS` in `.githooks/post-commit`. Extend that list
when a surface retires.

## Commits & Push

- Commits at phase close, not slice close. No commit per slice
  unless the user asks.
- Push is automatic on commit. The post-commit hook (a) AST-rebuilds
  the code graph and (b) writes `needs_update` if Markdown changed.
- Do not run graphify mid-session except per Knowledge Graph Refresh.

## Session Handoff (only when wrapping)

Update
`~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md`:

- what finished, files changed, tests run, what comes next, doc
  moves
- hard cap **40 lines**
- "What Completed" = last accepted slice only; prior slices live in
  `PROJECT_TRACKER.md`

Not prompt authority. Do not reread mid-execution.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
