# CLAUDE.md

## Authority Order

When sources conflict, earlier wins:

1. The active prompt.
2. `docs/contracts/**`.
3. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`,
   `docs/POST_HARDENING_FOLLOWUPS.md`.
4. The active phase doc named in the prompt (`docs/phases/**`).
5. This file.

`docs/archive/**` is history — ignore unless the prompt names it.
`docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures; treat them as
expected, not regressions.

## Hard Promises

Every slice respects these. Origin: `docs/archive/phases/post_11a7_stabilization_plan.md`.

1. **Phase 8 = pure transport swap.** Vendor connectors write against
   existing SQLite tables only. Cleanup is `7.57`/`7.58`/`7.61` follow-up.
2. **Demo mode persists post-launch.** `kDemoMode` is a writer-side switch.
   Same tables, same reads, same UI either way.
3. **No app logic changes before `7.58`.** `7.58.0` (Primary Driver audit)
   is the first logic-deciding slice.
4. **Per-operator isolation is non-negotiable.** RLS-ready schema from day
   one; Phase 9 enforces.
5. **AGE infrastructure live before `11b`; retrieval is Modular Adaptive
   Agentic RAG.** Advisor `11b` launches with Anthropic Contextual Retrieval;
   AGE traversal lights up incrementally (`11b.2` causal, Phase 12 workflows).
6. **Advisor speaks in recommendations, not commands.** F&F never acts on
   the operator's behalf at launch. Liability codification → Phase 9.8.
7. **F&F holds all provider keys server-side.** No BYO-key. Proxy backend
   brokers all LLM/embedding calls; production keys in Cloud Run env / KMS.
8. **AI infrastructure is general-purpose.** `LLMProvider`, `EmbeddingProvider`,
   `RerankProvider`, `DataSourceProvider`, `IntegrationProvider` are not
   advisor-specific; Phase 12 workflows reuse the same plumbing.
9. **AI cost is metered by class.** `usage_caps` two-slot key + 5
   cost-discipline levers keep margin 75–95%.
10. **Every backend phase ships its operator-facing UX before phase close.**
    Phase docs include a `Frontend Exposure` section. UX-exposing slices
    include a demo-mode walkthrough; Codex returns `FOLLOW-UP NEEDED` if
    walkthrough evidence is missing.

## Workflow

- **Phase loop**: post-commit hook refreshes graph → Claude plans next slices
  off the graph → Codex reviews + drafts prompts → parallel worktrees ship →
  audit → loop.
- **Parallel lanes**: Codex on master; Claude in `.claude/worktrees/<lane>`.
  Multiple phases may run simultaneously. Rules:
  `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Lanes".
- **Between batches**: Claude on master runs `docs/BETWEEN_SPRINT_AUDIT_PROMPT.md`
  to audit the merged batch, lean trackers/phase docs, archive, and emit next prompts.
- **Migration drift scanner**: after any slice adds `db/migrations/*.sql`, run
  `dart run tool/migration_drift_scanner.dart --fix --strict-docs`. It updates
  the staging setup cutoff, writes `build/reports/migration_drift_report.md`,
  and flags tracker/runbook authority docs that still need manual queue/count
  wording updates. Keep `dart run tool/migration_cutoff_lint.dart` as the hard
  CI-style gate.
- **Main chat is read-only across worktrees** when worktrees are running
  (observe/diff/review only). Tracker/memory/coordination edits on master OK.
- Don't broaden scope. Don't update trackers during implementation unless asked.
- If docs move, update touched links and report `Links updated: yes/no`.

## Review Loop (user pastes an Execution Report)

1. Review changed files plus nearby runtime seams.
2. Issues → return findings; keep the slice active.
3. Clean → Codex advances trackers and the next prompt.
4. Ignore stale findings the current code no longer matches.

## Service-Layer Split

- `lib/data/` — frozen legacy. Delete-only.
- `lib/services/` — runtime orchestration.
- `lib/domain/services/` — pure formulas, no I/O.
- `lib/state/` — state holders.
- `lib/dev/` — demo and dev-only.
- `lib/auth/` — frozen permission key catalog (constants only; mirrors
  `docs/contracts/auth_permission_key_catalog.md`).
- `lib/infrastructure/persistence/sqlite/` — SQLite helpers.
- `lib/infrastructure/persistence/postgres/` — only place raw `package:postgres`
  imports are allowed; CI lint enforces.

## Architecture Guardrails

- `LaborModel` is the formula source.
- `TargetCycle` locks 60-day standards; `ActiveTargetProfile` is its runtime
  projection. `DemandForecastContext` is rolling demand, not standards.
  `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.
- Source facts, derived metrics, and teaching summaries stay separate.
- Widgets do not own source-truth or service-period bucketing.
- Shift's whole-day view is authoritative; `10.5` adds daypart alongside,
  never replacing.

## Time Guardrails

- Restaurant-local timing wins. Business date is the anchor.
- Week start, business-day rollover, and service periods are restaurant-owned.
- Closed truth is not rewritten by later cycles or weekly plans.
- **Storage rule**: operator-scoped Postgres fact tables store source-truth
  instants as `TIMESTAMPTZ` (UTC) plus a denormalized `business_date` `DATE`
  computed at write using `location.timezone` (IANA, per-location) +
  `business_day_rollover_hour`. `TIMESTAMP WITHOUT TIME ZONE` is banned in
  operator-scoped tables. `business_date` is computed once at write.

Refs: `docs/contracts/phase_7_55_*.md`.

## RLS-Ready Schema

Operator-scoped Postgres fact tables include `(operator_id, location_id)`
plus an RLS policy stub from creation. Single-location operators run with a
default `location_id`. Corpus / methodology stays `operator_id`-scoped.
Scaffolding is not retrofitted later.

- **Repository pattern (two-layer defense)**: app code uses
  `OperatorScopedRepository<T>`, which injects `(operator_id, location_id)`
  from `OperatorContext`. Postgres RLS is the backup, not the primary defense.
- **Index discipline**: every fact-table B-tree index leads with `operator_id`
  (or `(operator_id, location_id)`). Indexes leading with `business_date` etc.
  are forbidden; CI lint enforces.
- **Session vars**: proxy uses `SET LOCAL` (transaction-scoped), never `SET`.
  Pooled connections must not carry tenant context across requests.
- **RLS UUID wrappers**: policies use four `STABLE LEAKPROOF PARALLEL SAFE`
  wrapper functions; bare `current_setting()` reads are forbidden, CI lint enforces.

## Proxy & API Conventions

- API URL versioning: `/v1/...` paths today; `/v2/...` when breaking changes
  ship; old paths stay live until explicit deprecation.
- Every proxy write is idempotent. Clients carry an idempotency key per
  request; the proxy stores keys in `proxy_requests` (UNIQUE constraint).
- Every AI surface plugs into the `11a.10` infrastructure (proxy + provider
  abstractions + counter/caps + feature flags). No parallel stacks.
- **Postgres**: Azure DB Flexible Server, `Canada Central`, PG 16. Extensions:
  `AGE`, `pgvector`, `pg_diskann`, `pg_cron`, `pg_partman`, `pg_stat_statements`,
  `pgcrypto`. Migrations in `db/migrations/`.
- **`pgmq` is NOT an Azure extension on this host.** In-DB queues use
  `SELECT ... FOR UPDATE SKIP LOCKED` against a plain workflow table;
  HTTP-delivery queues use Cloud Tasks.
- **Retrieval**: Modular Adaptive Agentic RAG (Haiku classifier → SQL /
  Contextual Retrieval / AGE → Sonnet synthesis with prompt cache).
- **Real-time**: `NOTIFY` → Pub/Sub → WebSocket bridge (Phase 10a).
  `event_outbox` is the durable backbone.
- **Service principals**: non-human actors authenticate with `sp:`-prefixed
  JWTs; `audit_logs.actor_kind` never NULL.
- **Hash-chained audit log**: SHA-256 chain via `pgcrypto`, `pg_partman`
  per-operator/day, daily Azure Blob immutable anchor.
- **Cost-discipline levers default-on**: prompt caching with `"ttl":"1h"` pin,
  tier routing, response cache, precomputed summaries, Batch API.

Architecture detail: `docs/phases/phase_11a/phase_11a_decision_register.md`.
35 locked scalability decisions:
`docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`.

## Testing

- Run the smallest set that proves the seam.
- `dart analyze` whenever the prompt requires verification.
- "No rerun" prompts → do a code review instead.

## Phase Doc Hygiene

- Slice < 1 week AND < 5 files → inline in the tracker.
- Larger, or new contract → own phase doc.
- Closed phase docs retire to `docs/archive/phases/` within a week.

## Graph vs Grep

`rg` first when symbol, filename, import path, or literal text is known. The
`graphify` MCP server is for orientation:

- `shortest_path` — trace how unfamiliar concepts connect.
- `query_graph` — find which contract bullet covers a topic (returns
  `source_file` + `source_location`).
- Phase-lane orientation before opening files.

Skip god-nodes and community exploration unless Codex requests them.

## Knowledge Graph Refresh

`graphify-out/needs_update` exists → run `/graphify --update` as the FIRST
action of the next turn. This is the only sanctioned graphify run mid-session.
Brief acknowledgement first; do not promise a duration.

The hook excludes `docs/archive/**` and `graphify-out/**` via
`FROZEN_HISTORY_PATHS` in `.githooks/post-commit`. Extend that list when a
surface retires.

## Commits & Push

- Commits at phase close, not slice close (unless asked).
- Push is automatic on commit. The post-commit hook (a) AST-rebuilds the code
  graph and (b) writes `needs_update` if Markdown changed.
- Don't run graphify mid-session except per Knowledge Graph Refresh.

## Session Handoff (only when wrapping)

Update `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md`:

- what finished, files changed, tests run, what comes next, doc moves
- hard cap **40 lines**
- "What Completed" = last accepted slice only; prior slices live in `PROJECT_TRACKER.md`

Not prompt authority. Don't reread mid-execution.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
