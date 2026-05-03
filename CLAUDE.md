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
`docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures; treat them
as expected, not regressions.

## Hard Promises

Every slice respects these. Origin: `docs/archive/phases/post_11a7_stabilization_plan.md`.

1. **Phase 8 = pure transport swap.** Vendor connectors write existing SQLite tables only; cleanup is `7.57`/`7.58`/`7.61`.
2. **Demo mode persists post-launch.** `kDemoMode` is a writer-side switch; same tables, same reads, same UI either way.
3. **No app logic changes before `7.58`.** `7.58.0` (Primary Driver audit) is the first logic-deciding slice.
4. **Per-operator isolation is non-negotiable.** RLS-ready schema from day one; Phase 9 enforces.
5. **AGE infra live before `11b`; retrieval is Modular Adaptive Agentic RAG.** Advisor `11b` launches with Contextual Retrieval; AGE traversal lights up incrementally (`11b.2` causal, Phase 12).
6. **Advisor speaks in recommendations, not commands.** F&F never acts on the operator's behalf at launch. Liability codification → Phase 9.8.
7. **F&F holds all provider keys server-side.** No BYO-key. Proxy brokers all LLM/embedding calls; production keys in Cloud Run env / KMS.
8. **AI infrastructure is general-purpose.** `LLMProvider`, `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider`, `IntegrationProvider` are not advisor-specific; Phase 12 reuses the plumbing.
9. **AI cost metered by class.** `usage_caps` two-slot key + 5 cost-discipline levers keep margin 75–95%.
10. **Every backend phase ships its operator-facing UX before phase close.** Phase docs include a `Frontend Exposure` section. UX-exposing slices include a demo-mode walkthrough; Codex returns `FOLLOW-UP NEEDED` if missing.

## Workflow

- **Phase loop**: graph refresh → Claude proposes prompts → parallel worktrees implement → Codex reviews against contracts/phase docs → Claude fixes until approved → Codex updates docs → Claude handles requested git actions.
- **Parallel lanes**: Codex on master; Claude in `.claude/worktrees/<lane>`. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
- **Between batches**: Claude on master runs `docs/BETWEEN_SPRINT_AUDIT_PROMPT.md` to audit, lean docs, archive, and emit next prompts.
- **Migration drift**: after `db/migrations/*.sql` changes, run `dart run tool/migration_drift_scanner.dart --fix --strict-docs` then `dart run tool/migration_cutoff_lint.dart`.
- **Runtime acceptance**: runtime-exposed slices follow `docs/contracts/slice_runtime_acceptance_contract.md`. Browser-exposed slices use Browser Use per `runbooks/browser_use_acceptance_harness_runbook.md`.
- **Main chat is read-only across worktrees** when worktrees are running (observe/diff/review only). Tracker/memory/coordination edits on master OK.
- Don't broaden scope. Don't update trackers during implementation unless asked. If docs move, update touched links and report `Links updated: yes/no`.

## Review Loop (user pastes an Execution Report)

1. Review changed files plus nearby runtime seams.
2. Issues → return findings; keep the slice active.
3. Clean → Codex advances trackers and the next prompt.
4. Ignore stale findings the current code no longer matches.

## Service-Layer Split

- `lib/data/` — frozen legacy. Delete-only.
- `lib/services/` — runtime orchestration. `lib/domain/services/` — pure formulas, no I/O.
- `lib/state/` — state holders. `lib/dev/` — demo and dev-only.
- `lib/auth/` — frozen permission key catalog (mirrors `docs/contracts/auth_permission_key_catalog.md`).
- `lib/infrastructure/persistence/sqlite/` — SQLite helpers.
- `lib/infrastructure/persistence/postgres/` — only place raw `package:postgres` imports are allowed; CI lint enforces.

## Architecture Guardrails

- `LaborModel` is the formula source.
- `TargetCycle` locks 60-day standards; `ActiveTargetProfile` is its runtime projection. `DemandForecastContext` is rolling demand. `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.
- Source facts, derived metrics, and teaching summaries stay separate.
- Widgets do not own source-truth or service-period bucketing.
- Shift's whole-day view is authoritative; `10.5` adds daypart alongside, never replacing.

## Time Guardrails

- Restaurant-local timing wins. Business date is the anchor.
- Week start, business-day rollover, and service periods are restaurant-owned.
- Closed truth is not rewritten by later cycles or weekly plans.
- **Storage rule**: operator-scoped Postgres fact tables store source-truth instants as `TIMESTAMPTZ` (UTC) plus a denormalized `business_date` `DATE` computed at write from `location.timezone` (IANA) + `business_day_rollover_hour`. `TIMESTAMP WITHOUT TIME ZONE` is banned in operator-scoped tables. Detail: `docs/contracts/phase_7_55_time_boundary_contract.md`.

## RLS-Ready Schema

- Operator-scoped fact tables include `(operator_id, location_id)` + RLS policy stub from creation. Single-location operators run with default `location_id`. Corpus/methodology stays `operator_id`-scoped. Scaffolding is not retrofitted later.
- App code uses `OperatorScopedRepository<T>` (primary defense); Postgres RLS is the backup.
- Every fact-table B-tree index leads with `operator_id` (or `(operator_id, location_id)`); CI lint enforces.
- Proxy uses `SET LOCAL` (transaction-scoped), never `SET`. Pooled connections must not carry tenant context across requests.
- RLS policies use four `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions; bare `current_setting()` reads forbidden, CI lint enforces.
- Detail: `docs/contracts/hardening_rls_and_repository_pattern_contract.md`.

## Proxy & API Conventions

- API URL versioning: `/v1/...` today; `/v2/...` when breaking changes ship; old paths stay live until explicit deprecation.
- Every proxy write is idempotent. Clients carry an idempotency key per request; proxy stores keys in `proxy_requests` (UNIQUE).
- Every AI surface plugs into `11a.10` infra (proxy + provider abstractions + counter/caps + feature flags). No parallel stacks.
- **Postgres**: Azure DB Flexible Server, `Canada Central`, PG 16. Extensions: `AGE`, `pgvector`, `pg_diskann`, `pg_cron`, `pg_partman`, `pg_stat_statements`, `pgcrypto`. Migrations in `db/migrations/`.
- **`pgmq` is NOT an Azure extension.** In-DB queues use `SELECT ... FOR UPDATE SKIP LOCKED`; HTTP-delivery queues use Cloud Tasks.
- **Retrieval**: Modular Adaptive Agentic RAG (Haiku classifier → SQL / Contextual Retrieval / AGE → Sonnet synthesis with prompt cache).
- **Real-time**: `NOTIFY` → Pub/Sub → WebSocket bridge (Phase 10a). `event_outbox` is the durable backbone.
- **Service principals**: non-human actors authenticate with `sp:`-prefixed JWTs; `audit_logs.actor_kind` never NULL.
- **Hash-chained audit log**: SHA-256 chain via `pgcrypto`, `pg_partman` per-operator/day, daily Azure Blob immutable anchor.
- **Cost-discipline levers default-on**: prompt caching `"ttl":"1h"` pin, tier routing, response cache, precomputed summaries, Batch API.

Architecture detail: `docs/phases/phase_11a/phase_11a_decision_register.md`.
35 scalability locks: `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`.

## Testing

- Run the smallest set that proves the seam.
- `dart analyze` whenever the prompt requires verification.
- "No rerun" prompts → do a code review instead.

## Phase Doc Hygiene

- Slice < 1 week AND < 5 files → inline in the tracker.
- Larger, or new contract → own phase doc.
- Closed phase docs retire to `docs/archive/phases/` within a week.

## Tooling: Codex skill + MCP servers + graphify

- Codex `$forge-flow` skill at `~/.codex/skills/forge-flow` mirrors this file's authority order, phase routing, live-mutation boundaries, migration/runtime gates, walkthrough expectations, tracker closeout rules.
- `.mcp.json` registers `forgeflow_docs` (read-only docs/contracts/runbooks search), `forgeflow_sqlite_schema` (read-only local SQLite schema), `graphify` (code/docs graph).
- `rg` first when symbol/filename/import path/literal text is known. Use `graphify` (`shortest_path` / `query_graph`) for orientation only. Skip god-nodes/community exploration unless Codex requests.

## Knowledge Graph Refresh

`graphify-out/needs_update` exists → run `/graphify --update` as the FIRST action of the next turn. This is the only sanctioned graphify run mid-session. Brief acknowledgement first; don't promise a duration.

The hook excludes `docs/archive/**` and `graphify-out/**` via `FROZEN_HISTORY_PATHS` in `.githooks/post-commit`. Extend that list when a surface retires.

## Commits & Push

- Commits at phase close, not slice close (unless asked).
- Push is automatic on commit. Post-commit hook AST-rebuilds the code graph and writes `needs_update` if Markdown changed.
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
