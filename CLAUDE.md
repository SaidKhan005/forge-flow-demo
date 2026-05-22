# CLAUDE.md

Normative repo rules. When this file and a higher tier conflict, the
Authority Order below decides. Each binding rule is stated once;
later sections cross-reference rather than restate.

**Contents:**
Operator Communication Style ·
Authority Order ·
Hard Promises ·
Workflow (Pattern · Routing · House rules · Orchestrator Support Loop · Doc Lean-Out & Archive Pass · Agent-led slices · Ceiling-raise rule) ·
Shared Checkout Safety ·
Cost & Convergence Discipline ·
Review Loop ·
Service-Layer Split ·
Architecture Guardrails ·
Time Guardrails ·
RLS-Ready Schema ·
Proxy & API Conventions ·
Testing ·
Phase Doc Hygiene ·
Tooling (Codex skill · MCP servers) ·
Knowledge Graph (graphify) ·
Commits & Push ·
Session Handoff ·
Demo Mode ·
Flavors.

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
  Full hard rule + prohibitions: see "Agent-led slices" below.
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
- Prompt-shape canonical (live): `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
  is the source of truth for executor/agent prompt shape. The wave-2-era
  paste-ready handoff prompts are retained for reference only at
  `docs/archive/_indices/wave_2_closeout_2026_05_15/` (`CLAUDE_HANDOFF_PROMPT.md`
  + `CODEX_HANDOFF_PROMPT.md`); they are history, not a live workflow input.
- Per-slice scope: `docs/_execution/<lane>/03_execution_slices.md` (or
  inline in the tracker if `< 1 week AND < 5 files`).
- Prompt-shape rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md` (named for
  legacy reasons; applies to both Claude and Codex agent prompts).

### House rules

- After `db/migrations/*.sql` changes: `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart`.
- **UX no-em-dash law.** No operator-facing string anywhere may use an em dash (U+2014 `—`) as punctuation or a separator. Use a colon for label/value separators (`'Barrio Legado: North Loop'`), `to` for ranges, or a full stop / comma when it joins clauses. The standalone `'—'` glyph stays as the honest empty/missing-value sentinel (Metric Honesty Doctrine). `tool/ux_em_dash_lint.dart` enforces this over the rendering/content layers (pre-push hook + manual `dart run tool/ux_em_dash_lint.dart`); the doctrine binds all operator-facing copy, including any surface outside that lint scope. New UX surfaces get added to the lint's `kUxCopyRoots`.
- Runtime acceptance (advisory pattern, not CI-enforced — reviewer judgment): `docs/contracts/slice_runtime_acceptance_contract.md`; browser slices use `runbooks/browser_use_codex_acceptance_workflow.md` (named for legacy reasons; applies to whichever executor exercises browser flows).
- Feature lens audit: use `runbooks/feature_implementation_lens_audit_runbook.md` before broad feature work, settings work, route/schema changes, runtime-exposed behavior, or any implementation where hidden plumbing may matter.
- Main chat is read-only across worktrees when worktrees are running. Tracker/memory/coordination edits on master OK.
- Don't broaden scope. Don't update trackers during implementation unless asked (see "Agent-led slices"). Report `Links updated: yes/no` if docs move.
- Graphify is manual-only: see the "Knowledge Graph" section.

### Orchestrator Support Loop (while agents run)

The orchestrator never idle-blocks on a running agent. While an agent works, it runs a strictly non-conflicting loop (read-only or planning only; never edits a file a live agent may touch):
1. Pre-flight recon for the next task, including a 'reuse, don't re-derive' check that the work is not already landed/superseded.
2. Pin the audit baseline (origin/master SHA + expected changed-file set + reject rule) so the incoming PR audit is targeted, not a full re-read.
3. Regression-watch recently merged PRs for drift.
4. Conflict-map running worktrees for file overlap (serialize per Cost & Convergence #3 before they collide).
5. Maintain a compaction-survivable in-flight ledger (agent id, scope, expected files, status).
6. Pre-stage the next agent prompt.
Any work that would touch a live agent's surface waits. Origin: 2026-05-19 workflow test; the recon step alone prevented a redundant agent dispatch.

### Doc Lean-Out & Archive Pass (operator-triggered)

Trigger: the operator says "full doc update", "lean out and archive",
"update lean out and archive", or "doc lean out" (minor variants
count). Run this fixed procedure. Do NOT rebuild the knowledge graph
(graphify is manual-only, see "Knowledge Graph"); if
`graphify-out/graph.json` already exists, use it read-only for signal.

1. **Safety sweep first.** Per Shared Checkout Safety: scan every
   worktree/branch for uncommitted or unpushed work; non-destructively
   snapshot any dirty worktree to a pushed
   `rescue/wt-snapshot/<base>-<UTC>` branch; confirm no committed work
   is unpushed. Nothing else starts until this is clean.
2. **Scope.** `PROJECT_TRACKER.md` + all of `docs/**` EXCEPT
   `docs/archive/**`, `docs/business/**`, `docs/f&f Coaching/**`, and
   `docs/ARCHITECTURE.md` (operator's personal study notes: redirect
   references only; never open, edit, or move it or its generated
   `docs/architecture_book/book.html`).
3. **Signal.** Build the live docs tree + reference scan; use an
   existing `graphify-out/graph.json` read-only for
   orphan/repetition/staleness signal.
4. **Classify** each candidate KEEP / ARCHIVE / MERGE / REPOINT via a
   read-only Explore agent (Cost & Convergence "reuse, don't
   re-derive": verify landed / superseded / paused-not-stale /
   intentional-pair status before acting).
5. **Honest assessment.** Do not manufacture consolidation. Explicitly
   flag false-positive "duplicates" (intentional source + plain-English
   pairs, per-vendor integration templates, load-bearing indices,
   paused-vendor docs) and say so plainly when the repo is already
   lean.
6. **Repoint-then-archive.** Repoint ALL inbound references first
   (excluding `docs/archive/**`), THEN history-preserving `git mv`
   into `docs/archive/**`. Nothing is ever deleted.
7. **Waves + gates.** Execute agent-led in safe waves (worktree →
   commit + push → PR → STOP per "Agent-led slices"); orchestrator
   audits Pattern B and merges; binding / Authority-Order / contract /
   auth / RLS / proxy doc moves need explicit operator approval; pause
   at every real gate.
8. **Verify landed.** Confirm each merged PR's content is actually on
   `origin/master` ("MERGED" is not landed, Shared Checkout Safety #3).

Origin: 2026-05-19 (8-wave consolidation + graph-verified re-run);
binding form of a repeated operator workflow so it is never re-derived.

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

1. **Own-worktree-only; shared checkout stays on master.** A session NEVER
   edits the shared main checkout working tree, and the shared checkout's
   HEAD STAYS on `master` at all times. All implementation work happens in
   that session's own `.claude/worktrees/<lane>/` (or
   `.codex/worktrees/<lane>/`) on a `claude/*` (or `codex/*`) branch. No
   session, executor, agent, or hook switches the shared checkout off
   `master`, commits feature/slice work to it, or leaves it on a feature
   branch. Only exception: ref/tracker/coordination commits by the
   orchestrator on `master` — never feature/code WIP. If anything moves
   the shared checkout off `master`, restore it to `origin/master`
   immediately (rescue any uncommitted content per rule 4 first). Direct
   fix for the repeated 2026-05-18/19 "HEAD landed on master mid-task"
   incidents.
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
   WIP rescue run via `tool/repo_janitor.sh`, wired to the `post-merge`
   git hook (background, dry-run by default; enable real cleanup with
   `touch .git/repo_janitor_apply`). Not by spending interactive
   orchestrator budget re-cleaning the same sprawl.
6. **Gate merges while CI is dark.** Until 2026-06-01, the orchestrator
   runs `tool/pre_merge_gate.sh <PR>` before merging any high-risk PR
   (touching `lib/**`, `db/migrations/**`, `tool/advisor_proxy/**`, auth,
   RLS, or proxy) — clean merge + analyzer + changed-tests GO/NO-GO. Plus
   `tool/verify_pr_landed.sh <PR>` after merge to confirm content actually
   landed (rationale: "MERGED" ≠ landed, see Shared Checkout Safety #3).

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

### Mobile Pressure Suite (integration tests on device)

Runner files: `integration_test/mobile_pressure/lane_[a–h]_runner.dart`

**Canonical run command (one lane at a time):**
```
flutter test integration_test/mobile_pressure/lane_X_runner.dart \
  --device-id emulator-5554 \
  --flavor forgeflow \
  --dart-define=kDemoMode=true \
  --timeout 120s
```

**Non-negotiable rules — learned the hard way:**
- `--dart-define=kDemoMode=true` is MANDATORY. Omitting it causes every test to throw `StateError: Mobile pressure suite requires --dart-define=kDemoMode=true` at startup and 0 tests pass.
- Run lanes **one at a time**, never in parallel. Parallel runs share `build/app/` Gradle output and produce file-copy conflicts mid-build.
- `--timeout 120s` prevents the 12-minute default from hanging the runner on slow emulator boot.
- If a lane times out on first run (APK install race), re-run once before diagnosing.

**Unit + widget tests (no device needed):**
```
flutter test test/
```

## Phase Doc Hygiene

- Slice < 1 week AND < 5 files → inline in tracker.
- Larger, or new contract → own phase doc.
- Closed phase docs retire to `docs/archive/phases/` within a week.

## Tooling: Codex skill + MCP servers + graphify

- This file (`CLAUDE.md`) is the SINGLE SOURCE OF TRUTH for authority order, workflow, gates, and rules. The Codex `~/.codex/skills/forge-flow` skill MUST defer to it and MUST NOT restate those rules (restating creates silent drift — the failure mode this prevents). Because Codex does not auto-load `CLAUDE.md`, the Codex skill's first action is to locate the repo and read `CLAUDE.md` + `PROJECT_TRACKER.md`.
- `.mcp.json` registers `forgeflow_docs` (read-only docs/contracts/runbooks search), `forgeflow_sqlite_schema` (read-only local SQLite schema), `graphify` (manually refreshed local code/docs graph).
- `rg` first when symbol/filename/import path/literal text is known. Graphify usage is governed by the "Knowledge Graph" section.
- **In-browser QA — operator web console.** Any session asked to run, pressure-test, or QA the operator web console MUST read `runbooks/operator_web_qa_runbook.md` before doing anything else. The build command, dhttpd serve config (`operator-web-static`, port 8185), polyfill boot-verify snippet, semantics-enable snippet, 11-route checklist, known baseline defects, and troubleshooting table are all there. No re-discovery.
- **In-browser QA — admin console.** Any session asked to run, pressure-test, or QA the admin console MUST read `runbooks/admin_console_browser_qa_runbook.md` before doing anything else. Same polyfill methodology; `--dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true` build; dhttpd serve config (`admin-web-static`, port 8186); 13-route checklist covering both primary nav and Business accounts hidden routes. No re-discovery.

## Knowledge Graph

Single canonical statement on graphify (cross-referenced by House
rules, Tooling, and Commits & Push):

- Manual-only for cost control. The operator triggers any graph refresh. Do not auto-run `/graphify --update`, do not create `graphify-out/needs_update`, do not treat a stale `needs_update` file as a required next-turn action, and do not run graphify mid-session. Until the operator asks for graph context or confirms a fresh refresh, prefer authority docs, repo-local search, and code inspection.

## Commits & Push

- Commits at phase close, not slice close (unless asked).
- Push is automatic on commit.
- Local hooks are cheap guardrails only. Install with `scripts/install_git_hooks.ps1`; they do not run graphify, provider calls, cloud actions, browser QA, or full Flutter test suites.
- Graphify is never run by hooks or mid-session: see "Knowledge Graph".

## Session Handoff (only when wrapping)

Update `~/.claude/projects/C--forge-flow-demo/memory/session_handoff.md` with what finished, files changed, tests run, next steps, doc moves. Hard cap **40 lines**. "What Completed" = last accepted slice only (prior slices live in `PROJECT_TRACKER.md`). Not prompt authority; don't reread mid-execution.

## Demo Mode

HP #2: `kDemoMode` is a writer-side switch — same tables, same reads, same
UI either way. **Full architecture + rationale:
`docs/contracts/demo_mode_contract.md` (authoritative — do not duplicate
its prose here).**

Binding essentials:
- Demo data = standard SQLite tables under
  `DemoScope.restaurantId = 'demo_restaurant_001'`. **No `demo_*` tables.**
- Writer = `MockReplayDataSourceProvider` → `_seedDemoDataFromReplay`
  (`sqlite_database_seed.dart`); Phase 8 vendor sinks implement the same
  `DataSourceProvider`, so demo→live changes only the writer. Per-(O,L,C)
  flip state in Postgres `demo_mode_state`; disconnect does NOT auto-revert.
- Readers (services/repos/widgets) NEVER branch on `kDemoMode`. Demo auth
  is a writer-side bootstrap SOURCE swap (`DemoAuthLoginService`), not a
  reader branch.

Sanctioned reader-side carve-outs — do NOT remove without an explicit
replacement plan (rationale in the contract):
1. `lib/screens/auth/login_screen.dart` — additive "Use demo operator" button (UX only).
2. `lib/services/app_data_status_service.dart` — `DEMO` vs `CURRENT` badge (label only).
3. `lib/screens/settings_screen.dart` — `_kDemoMode` gates demo-only "Data reset" + "Demo date" sections.
4. `lib/screens/settings/settings_demo_live_switch.dart` — `demo_mode_state` UI fold for the master Demo→Live switch.

Rules for new demo-aware code:
- Default = NO branch; demo and prod read the same path. Demo seeders write the same DAOs/tables as production.
- UX-only flag use: mark `// kDemoMode carve-out: <reason>` and append rationale to the contract + carve-out list above.
- Any `demo_*` SQLite/Postgres table violates HP #2 — use existing tables with `restaurant_id = DemoScope.restaurantId` (or the `demo_mode_state` row). A parallel `demo_*` table or a `kDemoMode`-gated reader requires explicit operator sign-off.

## Flavors

- Forge & Flow: `lib/main_forgeflow.dart`
- Barrio: `lib/main_barrio.dart`
