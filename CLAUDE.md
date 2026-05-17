# CLAUDE.md

## Operator Communication Style (binding — applies to every reply)

When reporting to the operator in chat (status, findings, summaries,
recommendations, results), the default and required format is:

- **Plain English.** No engineering jargon, no unexplained acronyms, no
  git/internal-tool vocabulary unless the operator used it first. If a
  technical term is unavoidable, explain it in the same breath.
- **Simple bullet points.** Short, scannable bullets — not walls of prose,
  not dense paragraphs. Lead with the answer/outcome, then specifics.
- **Tables only when they genuinely aid scanning** (e.g., a few rows of
  status); otherwise bullets.
- This governs operator-facing chat replies. It does NOT change commit
  messages, code comments, PR bodies, or contract/audit doc prose, which
  follow their own standards. Mirrors the product UX writing standard
  (plain English, reads as training).

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

## Workflow (executor-agnostic)

This is the repo's default workflow regardless of which executor is running
(Claude only, Codex only, or both in parallel). The operator may run out of
quota on one and switch to the other; the workflow stays the same.

### Pattern

- **Orchestrator** (the operator's main chat session) drives planning, prompt
  emission, audit, merge. Single owner of trackers + ledgers.
- **Executors** (Claude lane and/or Codex lane sessions) work in isolated
  `.claude/worktrees/<lane>/` (or `.codex/worktrees/<lane>/`) and never edit
  trackers, ledgers, audit docs, or each other's files. Their contract is
  `branch → implement → self-audit → commit + push → open PR → STOP`.
- **Worker agents** dispatched by either an executor or the orchestrator via
  the Agent tool use the same `worktree → PR → STOP` shape. No auto-merge.
- **Audit** by the orchestrator against contracts + slice intent. Pattern B
  table (worker self-audit + executor independent audit, both with file:line
  citations) is non-negotiable in every PR body.
- **Merge** by the orchestrator only when audit is clean. Auth-critical,
  RLS-touching, schema-touching, and proxy-touching slices require explicit
  operator approval regardless of audit verdict.
- **Between batches:** orchestrator audits the just-merged batch, leans
  docs, archives closed material, and emits the next prompts.

### Routing

- Forward plan: `docs/_indices/NEXT_WAVE_PLAN.md`.
- **Active feature plan: `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`** (Phase 2.5 per NEXT_WAVE_PLAN; output of Phase 2 mobile walkthrough; 9 slices; 44 gaps consolidated; reusable surface-coverage audit method appended).
- Per-wave slice ledger: `docs/_indices/<wave>_EXECUTION_LEDGER.md`. Wave 1's `WAVE_EXECUTION_LEDGER.md` CLOSED 2026-05-13 (archived to `docs/archive/_indices/wave_1_closed_2026_05_13/`). Wave 2's `WAVE_2_LEDGER.md` operator-web + admin lanes CLOSED 2026-05-14; mobile lane closed for walkthrough 2026-05-15 (transitioned to Per-Daypart Targets V1 plan).
- Paste-ready executor prompts: `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` and
  `docs/_indices/CODEX_HANDOFF_PROMPT.md`. Both encode the same workflow;
  use whichever matches your active executor.
- Per-slice scope: `docs/_execution/<lane>/03_execution_slices.md` (or
  inline in the tracker if `< 1 week AND < 5 files`).
- Prompt-shape rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md` (named for
  legacy reasons; applies to both Claude and Codex agent prompts).

### House rules

- After `db/migrations/*.sql` changes: `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart`.
- Runtime acceptance (advisory pattern, not CI-enforced — reviewer judgment): `docs/contracts/slice_runtime_acceptance_contract.md`; browser slices use `runbooks/browser_use_codex_acceptance_workflow.md` (named for legacy reasons; applies to whichever executor exercises browser flows).
- Feature lens audit: use `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` before broad feature work, settings work, route/schema changes, runtime-exposed behavior, or any implementation where hidden plumbing may matter.
- Main chat is read-only across worktrees when worktrees are running. Tracker/memory/coordination edits on master OK.
- Don't broaden scope. Don't update trackers during implementation unless asked. Report `Links updated: yes/no` if docs move.
- Graph refresh (graphify) is manual-only when the operator asks for it.

### Agent-led slices — hard rule

When work is delegated to a worktree agent (whether by an executor or the
orchestrator), the agent's contract is **`commit + push + open PR → STOP`**.
The agent MUST NOT merge, MUST NOT run `--no-verify` to bypass hooks, and
MUST NOT update trackers. The orchestrator audits the PR diff against
contracts + slice intent, dispatches a follow-up agent if material gaps,
and merges only when clean. Audit artifacts live in
`docs/_audits/<wave>/pr_<n>_<topic>.md`. Detail:
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices".

### Ceiling-raise rule (R-2 from post-Codex wave closeout)

Bleed-stop ceiling raises (e.g., `tool/advisor_proxy_size_lint.dart`'s
`kAdvisorProxyMaxLines`) require explicit operator approval, same gate as
auth-critical / RLS-touching / schema-touching / proxy-touching slices.
The doctrine "the monolith MUST shrink, not grow" only holds if raises
are gated. Detail: `docs/POST_HARDENING_FOLLOWUPS.md` "Refactor phase
scope" R-2.

## Shared Checkout Safety (binding — prevents silent work loss)

Origin: 2026-05-16 repo-health pass. Two WIP losses in one day
(`admin_security_gateway`, near-loss of `7.58.0a` mock-replay delta) traced
to the same root cause: uncommitted work left in the shared main checkout
while another session ran `reset --hard origin/master` / `pull --rebase
--autostash`. These rules are non-negotiable for every session (Claude or
Codex, orchestrator or executor):

1. **Own-worktree-only.** A session NEVER edits the shared main checkout
   working tree. All work happens in that session's own
   `.claude/worktrees/<lane>/` (or `.codex/worktrees/<lane>/`). The main
   checkout is for ref/tracker/coordination commits by the orchestrator
   only — never feature/code WIP.
2. **Push before you reset.** Only *pushed* commits are safe. Before any
   `reset`, rebase, branch switch, or autostash-triggering pull, commit and
   push. Uncommitted or local-only work in a shared checkout is considered
   already lost.
3. **"MERGED" ≠ landed.** GitHub merged status and branch ancestry are
   unreliable here (squash merges orphan branch tips; resets churn master).
   Confirm content is actually on `origin/master` with
   `tool/verify_pr_landed.sh <PR> [symbol ...]` before trusting a PR landed
   or relying on its code.
4. **Rescue, don't discard, found WIP.** If you find uncommitted changes in
   a shared checkout that aren't yours: do NOT reset/stash-drop them.
   Non-destructively snapshot via `git stash create`, point a
   `rescue/<topic>` branch at the result, and `git push origin
   rescue/<topic>` — then report. Never destroy another session's work.

## Cost & Convergence Discipline (binding — stops rework spend)

Origin: 2026-05-16 workflow review. At ~95 PRs/day with CI dark and a
moving base, the dominant cost is rework: work built then reverted,
re-audited after every rebase, lost and redone. These rules cut that:

1. **Decide before you dispatch.** Any product-direction, auth, or
   architecture fork is decided by the operator BEFORE expensive agent
   work starts — never build first and decide after. (#832 magic-link was
   built, audited, merged, then reverted 30 min later: a whole wasted
   cycle.) If the fork is unresolved, ask; do not speculatively build both.
2. **Work in waves, not a firehose.** Dispatch a batch of
   non-conflicting lanes against a pinned base, merge the batch, THEN
   start the next wave. Do not keep an unbounded number of lanes branching
   off a constantly-moving master — every one pays a rebase + re-audit tax.
3. **Cap concurrency; serialize conflicts.** Lanes touching the same
   high-contention surface (auth, `tool/advisor_proxy/**`, a single
   screen, the same migration chain) run ONE at a time, not in parallel.
   Parallel same-file lanes produce throwaway conflicting output.
4. **Reuse, don't re-derive.** Before dispatching, check the work isn't
   already landed/superseded (`tool/verify_pr_landed.sh`, `gh pr list`).
   Do not spawn an agent to redo a merged PR.
5. **Hygiene is automated, not interactive.** Worktree/branch pruning and
   WIP rescue run via `tool/repo_janitor.sh` (scheduled/hook), not by
   spending interactive orchestrator budget re-cleaning the same sprawl.

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
- The demo **auth session** is also writer-side: the mobile demo flavor (`lib/main_forgeflow.dart`, gated on `kDemoMode`/`FORGE_FLOW_DEMO_MODE` and NOT `FORGE_FLOW_USE_FIREBASE_AUTH`) mounts `ForgeFlowApp(requireAuth: true)` with `DemoAuthLoginService` (`lib/services/auth/demo_auth_login_service.dart`) instead of `FirebaseAuthLoginService`. The demo operator (`demo.operator@forgeflow.test`) is minted as a F&F admin (`ff_support`) so the full Settings surface (Account, Setup, Integrations, Data tab + Data-alignment panel) is testable in demo. This is a bootstrap SOURCE swap — the demo analogue of `MockReplayDataSourceProvider` — mirroring the contract-endorsed Operator Web/Admin `*_DEMO_AUTH` pattern; NOT a `kDemoMode` reader branch. Every reader (`SettingsScreen`, role/permission gates) consumes the resulting `AuthSession` identically in demo and prod. Production auth (`FORGE_FLOW_USE_FIREBASE_AUTH`) is byte-unchanged.

Intentional reader-side carve-outs (do not remove without an explicit replacement plan):
1. `lib/screens/auth/login_screen.dart` — `_demoOperatorSignInEnabled` adds an additive "Use demo operator" button below the regular sign-in. Strictly UX; the button drives the same `signInWithEmailPassword` path.
2. `lib/services/app_data_status_service.dart` — the data-status badge renders `DEMO` instead of `CURRENT` when `--dart-define=kDemoMode=true`. Label-only; same read math.
3. `lib/screens/settings_screen.dart` — `_kDemoMode` const gates two demo-only management sections in the Settings tab: "Data reset" (clears local demo data) and "Demo date" (advance demo restaurant through sample business days). Production builds hide both sections; the rest of the Settings tab (Account, MFA, Active Sessions, Data freshness, Wage authority, Team, Permissions, FF Support) renders identically in demo and prod. Operator sign-off 2026-05-08 — these are demo-only operator affordances that have no production analogue, so the carve-out is the lower-risk option compared to rendering disabled UI in prod.

4. `lib/screens/settings/settings_demo_live_switch.dart` - runtime `demo_mode_state` UI fold for the operator-approved master Demo -> Live switch. It reads `DemoModeStateNotifier.snapshot.hasDemoCategories`, calls the proxy/repository path to flip existing rows from `is_demo=true` to `false`, and refuses Live -> Demo. No `kDemoMode` branch, no `demo_*` table, and no reader repository fork.

Rules for new demo-aware code:
- Default = NO branch. Demo and prod read from the same code path.
- If a UX-only label/badge needs the flag, mark the site `// kDemoMode carve-out: <reason>` and append the rationale to the contract doc + this section.
- Any new SQLite or Postgres table named `demo_*` is a violation of HP #2; use the existing tables with `restaurant_id = DemoScope.restaurantId` (or the per-(operator, location, category) `demo_mode_state` row).
- Demo seeders MUST write to the same DAOs / tables as production. Adding a parallel `demo_*` table or a `kDemoMode`-gated reader requires explicit operator sign-off.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
