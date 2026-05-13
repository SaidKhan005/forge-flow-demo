# CLAUDE.md

## Authority Order

When sources conflict, earlier wins:

1. The active prompt.
2. `docs/contracts/core_app_architecture.md` — canonical Phase 7.55 architecture; binds Layers 1–12 every implementation contract must honor.
3. `docs/contracts/**` (other Tier-2 contracts, including the source `phase_7_55_architecture_contract.md` + plain-english companion that #2 re-assembles).
4. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`, `docs/POST_HARDENING_FOLLOWUPS.md`.
5. The active phase doc named in the prompt (`docs/phases/**`).
6. This file.

`docs/archive/**` is history — ignore unless the prompt names it. `docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures; treat as expected, not regressions.

## Hard Promises

Every slice respects these. Origin: `docs/archive/phases/post_11a7_stabilization_plan.md`.

1. Phase 8 = pure transport swap — vendor connectors write existing SQLite tables only; cleanup is `7.57`/`7.58`/`7.61`.
2. Demo mode persists post-launch — `kDemoMode` is a writer-side switch; same tables, reads, UI either way.
3. No app logic changes before `7.58` — `7.58.0` (Primary Driver audit) is the first logic-deciding slice.
4. Per-operator isolation is non-negotiable — RLS-ready schema from day one; Phase 9 enforces.
5. AGE infra live before `11b`; retrieval is Modular Adaptive Agentic RAG. Advisor `11b` launches with Contextual Retrieval; AGE traversal lights up incrementally (`11b.2` causal, Phase 12).
6. Advisor speaks in recommendations, not commands — F&F never acts on the operator's behalf at launch. Liability codification → Phase 9.8.
7. F&F holds all provider keys server-side. No BYO-key. Proxy brokers all LLM/embedding calls; production keys in Cloud Run env / KMS.
8. AI infrastructure is general-purpose — `LLMProvider`, `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider`, `IntegrationProvider` are not advisor-specific; Phase 12 reuses the plumbing.
9. AI cost metered by class — `usage_caps` two-slot key + 5 cost-discipline levers keep margin 75–95%.
10. Every backend phase ships operator-facing UX before phase close. Phase docs include a `Frontend Exposure` section. UX-exposing slices include a demo-mode walkthrough; Codex returns `FOLLOW-UP NEEDED` if missing.
11. Hierarchy-scoped settings are mandatory. Business/operator values inherit downward through org units to locations; lower configured scopes override higher scopes. Every settings, roles, timing, pricing, accuracy, security, support, and future configuration surface must show selected scope, inherited source, and effective value, or document why the capability is backend-only/gated/incomplete. Integrations are location-editable only because vendor connections are location-bound.

## Workflow

- Phase loop: Claude proposes prompts → worktrees implement → Codex reviews → Claude fixes → Codex updates docs. Graph refresh is manual-only when the operator asks for it.
- Parallel lanes: Codex on master; Claude in `.claude/worktrees/<lane>`. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
- Between batches: master audits the just-merged batch, leans docs, archives closed material, and emits the next prompts.
- After `db/migrations/*.sql` changes: `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart`.
- Runtime acceptance (advisory pattern, not CI-enforced — reviewer judgment): `docs/contracts/slice_runtime_acceptance_contract.md`; browser slices use `runbooks/browser_use_codex_acceptance_workflow.md` (Codex-driven, out-of-repo — no harness binary lives here).
- Feature lens audit: use `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` before broad feature work, settings work, route/schema changes, runtime-exposed behavior, or any implementation where hidden plumbing may matter.
- Main chat is read-only across worktrees when worktrees are running. Tracker/memory/coordination edits on master OK.
- Don't broaden scope. Don't update trackers during implementation unless asked. Report `Links updated: yes/no` if docs move.
- **Agent-led slices: no auto-merge.** When work is delegated to a worktree agent, the agent's contract is `commit + push + open PR → STOP`. The agent must not merge, must not run `--no-verify` to bypass hooks, and must not update trackers. The orchestrator (main chat) audits the PR diff against contracts + slice intent, dispatches a follow-up agent if material gaps, and merges only when clean. Audit artifacts live in `docs/_audits/<wave>/pr_<n>_<topic>.md`. Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict. Detail: `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices".

## Review Loop (user pastes an Execution Report)

1. Review changed files + nearby runtime seams.
2. Issues → return findings, slice stays active. Clean → Codex advances trackers + next prompt.
3. Ignore stale findings the current code no longer matches.

## Service-Layer Split

- `lib/data/` — frozen legacy. Delete-only.
- `lib/services/` — runtime orchestration. `lib/domain/services/` — pure formulas, no I/O.
- `lib/state/` — state holders. `lib/dev/` — demo and dev-only.
- `lib/auth/` — frozen permission key catalog (mirrors `docs/contracts/auth_permission_key_catalog.md`).
- `lib/infrastructure/persistence/sqlite/` — SQLite helpers.
- `lib/infrastructure/persistence/postgres/` — only place raw `package:postgres` imports allowed; CI lint enforces.

## Architecture Guardrails

- `LaborModel` is the formula source; `TargetCycle` locks 60-day standards; `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.
- Source facts, derived metrics, and teaching summaries stay separate. Widgets do not own source-truth or service-period bucketing.
- Shift's whole-day view is authoritative; `10.5` adds daypart alongside, never replacing.

## Time Guardrails

- Restaurant-local timing wins; business date is the anchor; closed truth is not rewritten by later cycles or weekly plans.
- Operator-scoped Postgres fact tables store `TIMESTAMPTZ` (UTC) plus denormalized `business_date` `DATE`. `TIMESTAMP WITHOUT TIME ZONE` banned in operator-scoped tables.
- Detail: `docs/contracts/phase_7_55_time_boundary_contract.md`.

## RLS-Ready Schema

- Operator-scoped fact tables include `(operator_id, location_id)` + RLS policy stub from creation. App code uses `OperatorScopedRepository<T>` (primary defense); RLS is backup.
- Every fact-table B-tree index leads with `operator_id` (or `(operator_id, location_id)`); CI lint enforces.
- Proxy uses `SET LOCAL` (transaction-scoped). RLS policies use four `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions; bare `current_setting()` reads forbidden.
- Detail: `docs/contracts/hardening_rls_and_repository_pattern_contract.md`.

## Proxy & API Conventions

- API URL versioning: `/v1/...` today; `/v2/...` for breaking changes; old paths stay live until explicit deprecation.
- Every proxy write is idempotent. Clients carry an idempotency key; proxy stores keys in `proxy_requests` (UNIQUE).
- Every AI surface plugs into `11a.10` infra (proxy + provider abstractions + counter/caps + flags). No parallel stacks.
- Postgres: Azure DB Flexible Server, `Canada Central`, PG 16. Extensions: `AGE`, `pgvector`, `pg_diskann`, `pg_cron`, `pg_partman`, `pg_stat_statements`, `pgcrypto`. `pgmq` is NOT available — use `FOR UPDATE SKIP LOCKED` or Cloud Tasks.
- Service principals: non-human actors authenticate with `sp:`-prefixed JWTs; `audit_logs.actor_kind` never NULL. Hash-chained audit log: SHA-256 via `pgcrypto`, `pg_partman` per-operator/day, daily Azure Blob anchor.
- Detail: `docs/phases/phase_11a/phase_11a_decision_register.md`; scalability locks: `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`.

## Testing

- Smallest set that proves the seam.
- `dart analyze` whenever the prompt requires verification.
- "No rerun" prompts → do a code review instead.

## Phase Doc Hygiene

- Slice < 1 week AND < 5 files → inline in tracker.
- Larger, or new contract → own phase doc.
- Closed phase docs retire to `docs/archive/phases/` within a week.

## Tooling: Codex skill + MCP servers + graphify

- Codex `$forge-flow` skill at `~/.codex/skills/forge-flow` mirrors this file's authority order, phase routing, live-mutation boundaries, migration/runtime gates, walkthrough expectations, tracker closeout rules.
- `.mcp.json` registers `forgeflow_docs` (read-only docs/contracts/runbooks search), `forgeflow_sqlite_schema` (read-only local SQLite schema), `graphify` (manually refreshed local code/docs graph).
- `rg` first when symbol/filename/import path/literal text is known. Use `graphify` only when the operator explicitly asks for graph context or confirms it was manually refreshed.

## Knowledge Graph

- Manual-only for cost control. Do not auto-run `/graphify --update`, do not create `graphify-out/needs_update`, and do not treat a stale `needs_update` file as a required next-turn action.
- The operator manually triggers graph refresh when needed. Until then, prefer authority docs, repo-local search, and code inspection.

## Commits & Push

- Commits at phase close, not slice close (unless asked).
- Push is automatic on commit.
- Local hooks are cheap guardrails only. Install with `scripts/install_git_hooks.ps1`; they do not run graphify, provider calls, cloud actions, browser QA, or full Flutter test suites.
- Do not run graphify mid-session unless the operator explicitly requests a manual refresh.

## Session Handoff (only when wrapping)

Update `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md` with what finished, files changed, tests run, next steps, doc moves. Hard cap **40 lines**. "What Completed" = last accepted slice only (prior slices live in `PROJECT_TRACKER.md`). Not prompt authority; don't reread mid-execution.

## Demo Mode

HP #2: `kDemoMode` is a writer-side switch — same tables, same reads, same UI either way. Audited end-to-end 2026-05-07. Detail: `docs/contracts/demo_mode_contract.md`.

Architecture:
- Demo data lives in standard SQLite tables (`shift_records`, `week_records`, `restaurant_locations`, `target_cycles`, `import_runs`, `raw_import_records`, `active_target_profiles`, etc.) under `DemoScope.restaurantId = 'demo_restaurant_001'`. There are no `demo_*` SQLite tables.
- The writer is `MockReplayDataSourceProvider` (a `DataSourceProvider<MockReplayOutput>` impl) feeding `_seedDemoDataFromReplay` in `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`. Phase 8 vendor connectors (`*_pos_postgres_sink.dart`) implement the same `DataSourceProvider` interface, so flipping demo→live changes only the writer.
- Per-(operator, location, category) demo state lives in the Postgres `demo_mode_state` table; `DemoModeFlipPolicy.evaluateFlip` flips `is_demo = false` after the first vendor connection backfills ≥1 record. Disconnect does NOT auto-revert.
- Reader paths (services, repositories, widgets) do NOT branch on `kDemoMode`. They read whatever the active scope's tables hold.

Intentional reader-side carve-outs (do not remove without an explicit replacement plan):
1. `lib/screens/auth/login_screen.dart` — `_demoOperatorSignInEnabled` adds an additive "Use demo operator" button below the regular sign-in. Strictly UX; the button drives the same `signInWithEmailPassword` path.
2. `lib/services/app_data_status_service.dart` — the data-status badge renders `DEMO` instead of `CURRENT` when `--dart-define=kDemoMode=true`. Label-only; same read math.
3. `lib/screens/settings_screen.dart` — `_kDemoMode` const gates two demo-only management sections in the Settings tab: "Data reset" (clears local demo data) and "Demo date" (advance demo restaurant through sample business days). Production builds hide both sections; the rest of the Settings tab (Account, MFA, Active Sessions, Data freshness, Wage authority, Team, Permissions, FF Support) renders identically in demo and prod. Operator sign-off 2026-05-08 — these are demo-only operator affordances that have no production analogue, so the carve-out is the lower-risk option compared to rendering disabled UI in prod.

Rules for new demo-aware code:
- Default = NO branch. Demo and prod read from the same code path.
- If a UX-only label/badge needs the flag, mark the site `// kDemoMode carve-out: <reason>` and append the rationale to the contract doc + this section.
- Any new SQLite or Postgres table named `demo_*` is a violation of HP #2; use the existing tables with `restaurant_id = DemoScope.restaurantId` (or the per-(operator, location, category) `demo_mode_state` row).
- Demo seeders MUST write to the same DAOs / tables as production. Adding a parallel `demo_*` table or a `kDemoMode`-gated reader requires explicit operator sign-off.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
