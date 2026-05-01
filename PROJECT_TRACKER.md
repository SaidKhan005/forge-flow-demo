# Forge & Flow Project Tracker

Updated: 2026-04-30 (batch B/C/D acceptances + lean pass)
Owner: You
Execution model: We think, Claude codes

## Active Authority

Read this file first for current phase, next slice, and which phase doc to
fetch. Do not treat this tracker as the full plan. It is now the lean routing
map.

Primary active docs:

- `PROJECT_TRACKER.md` - current phase, next slice, guardrails, fetch map.
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md` - active
  11a execution plan and slice contracts.
- `docs/phases/phase_11a/phase_11a_decision_register.md` - 11a decisions,
  parked follow-ups, soft constraints, and AGE/Azure rationale.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  - capital-A admin console plan.
- `docs/phases/phase_9/phase_9_auth_plan.md` - Phase 9 framework and live
  auth acceptance plan.
- `docs/phases/phase_9/phase_9_execution_backlog.md` - Phase 9 live-closeout
  parcels that remain after framework acceptance.
- `docs/phases/phase_9/phase_9_ios_device_matrix_qa_plan.md` - physical iOS
  device QA matrix and blocker checklist.
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` - 35
  locked scalability decisions (Q1-Q22 + Q3.1-Q3.10) absorbed into the
  pre-launch sequence on 2026-04-28. Freshest architecture direction;
  supersedes anything older if it conflicts with a Q-locked item.
- `docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`
  - CONDITIONAL PASS verdict, 3 load profiles, hot-path inventory,
  Bottleneck Ranking, and the 14-row Prelaunch Performance Test Matrix
  that is the launch gate (now `cutover.0b`).
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` - prompt shape, generator,
  parallel-lane rules, report format, in-session token hygiene.
- `docs/BETWEEN_SPRINT_AUDIT_PROMPT.md` - paste-ready between-batch
  audit + lean tracker/phase-doc refresh + archive check + Codex
  prompts for the next parallel batch, in one main-chat run.
- `docs/DATA_ALIGNMENT_TRACKER.md` only for alignment-heavy slices.
- `docs/KNOWN_FAILING_TESTS.md` only for broad or known-red test runs.
- `runbooks/phase_9_production1_migration_apply_runbook.md` only for future
  Production1 database mutation gates or audit trace.

Archive for history, not normal prompting:

- `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean tracker with all prior detail.
- `docs/archive/phases/phase_11a/phase_11a_advisor_infrastructure_plan_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`
  - full pre-lean 11a plan.
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md` - older completed phase
  history.
- `docs/archive/trackers/PROJECT_TRACKER_2026-04-29_PRE_PHASE9_CLOSEOUT_LEAN.md`
  - tracker snapshot before this closeout lean pass.
- `docs/archive/phases/phase_9/` - completed Phase 9 result reports, including
  auth-operation, MFA/recovery, Cloud Armor/iOS simulator, maintenance, and
  Production1 migration apply evidence.

## How To Fetch Context

Before each prompt:

1. Read `PROJECT_TRACKER.md` sections `Now`, `Current Slice Queue`, and
   `Prompt Fetch Map`.
2. Read only the phase doc named for the current slice.
3. If the slice asks for architecture, blockers, cost, security, or sequencing
   decisions, also read the relevant decision register listed in the fetch map.
4. Do not read archived docs unless there is a disputed historical question or
   a prompt explicitly targets archive history.
5. Do not let Claude infer user-owned decisions. Surface them in Block 1 under
   `Human prerequisites -> Decision needed for this slice`.

## Prompt Fetch Map

- `11a.11c.5`, `11a.11c.6*`, `11a.11d`, `11a.11e`: read
  `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`; add
  `docs/phases/phase_11a/phase_11a_decision_register.md` only when the prompt
  needs Azure/AGE rationale, fallback posture, or parked decisions.
- `11A.*`: read
  `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.
- `cutover.*`: read
  `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`;
  add `phase_11a_decision_register.md` when the prompt needs cost
  envelopes, tier choice, or dormancy rules.
- `9.live-closeout`, `9.0-9.10` (incl. `9.0a`): read
  `docs/phases/phase_9/phase_9_auth_plan.md` and
  `docs/phases/phase_9/phase_9_execution_backlog.md`; add
  `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md` when the prompt
  touches any user-owned Phase 9 choice; add `phase_11a_decision_register.md`
  when the prompt needs Phase 9 architecture-lock rationale, RLS performance
  discipline, or repository-pattern detail.
- `9.0Σ.b` … `9.0Σ.k`: read
  `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` (the
  Q-decision that owns the slice) and
  `docs/phases/phase_9/phase_9_execution_backlog.md` (the matching B23+
  parcel). Add `phase_9_scalability_performance_audit_2026-04-27.md` only if
  the slice has a perf-gate row in the 14-row matrix.
- `cutover.0a`, `cutover.0b`: read
  `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
  PLUS `phase_9_scalability_decisions_2026-04-27.md` (CMK / item 8 for 0a)
  or `phase_9_scalability_performance_audit_2026-04-27.md` (the 14-row
  perf-gate matrix for 0b).
- `9.8`, `10a`, `10.5`, `9.5`, `7.58`, `11b`, `9.75`, `10b`, `7.61`,
  `8`, `8R`: read that phase's doc under `docs/phases/**` when it opens.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day
Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan ->
WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn.

## Now

- **Current phase:** `9` framework + `9.0Σ.b-k` accepted on 2026-04-29.
  Phase 9 UX family + `11A.0-6` foundation actively shipping.
- **Recent acceptances** (last batch — see phase doc Frontend Exposure +
  walkthroughs for detail):
  - `9.UX.2` Custom Role Editor (commit `245f14e`)
  - `9.UX.5` Active Sessions viewer (commit `b5345d4`)
  - `11A.2` Pricing Tier Admin (commit `934fc69`)
  - `9.UX.inheritance-hint.0` rendering (commit `5f5c91c`) —
    **rendering only**; data-path follow-up (`9.UX.grant-payload.0`)
    needed before hints render in production.
- **Operational gates pending live apply/deploy:** `202604280014` (B46),
  `202604290000` (B41), `202604290001` (`9.UX.4` hierarchy wiring);
  proxy redeploy with `account_info: postgres` binding (unblocks
  `9.UX.account-info` device QA); proxy redeploy with B48 reset-confirm
  route (unblocks `9.UX.7` live email-link reset); Cloud Run audit
  anchor deploy (B43); B44/B45/B47 producer wiring (unblocks
  `11A.5`/`11A.6`).
- **Cloud Armor:** preview-only at sensitivity 2 with B17 false-positive
  SQLi signatures opted out; awaits ≥3 clean post-tuning preview-log
  days + explicit approval before enforcement.
- **iOS physical device matrix:** deferred until Apple device/signing
  lane is back. Automated GitHub Actions run `25087331405` is green on
  `master` (macOS host + ForgeFlow + Barrio iOS sim builds).
- **Maintenance baseline (last run):** `flutter analyze --fatal-infos`,
  `dart run tool/rls_policy_lint.dart`, focused tests, `git diff --check`,
  full `flutter test` clean.
- **Notify the user before** any live Firebase mutation, key/account
  request, billing setup, provider call, or product decision.

## Current Slice Queue

Locked 2026-04-26 under "full proper dev before launch - no shortcuts": the
entire product ships before any operator goes live on production. No
friend-beta, no demo-mode launch, no split-and-defer of compliance.

Realigned 2026-04-29 after the Production1 apply, B17 staging smoke, Cloud
Armor preview tuning, Apple simulator recheck, and docs lean pass.

**Active lanes** (Codex on master; Claude in `.claude/worktrees/<lane>`):

Multiple phases may be active simultaneously. Each lane carries one
slice from one phase to acceptance. File ownership, shared-seam
serialization, walkthrough evidence per lane, and merge sequencing
follow `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Parallel Lanes".

1. `11A.0-6` - F&F Operations Console foundation.
   Accepted: `11A.0`, `11A.1`, `11A.2`. Owed: `11A.3-6`
   (`11A.5`/`11A.6` blocked on B44/B45/B47 producer wiring). Scope:
   `phase_11A_operations_console_plan.md`.
2. `9.UX.*` family - Phase 9 operator-facing UX. Accepted: `9.UX.0`,
   `9.UX.1` (incl. `9.UX.1a` folded), `9.UX.2`, `9.UX.4`, `9.UX.5`,
   `9.UX.account-info`, `9.UX.inheritance-hint.0` (rendering only).
   Owed: `9.UX.3`, `9.UX.6`, `9.UX.7`, `9.UX.grant-payload.0`
   (data-path complement to inheritance-hint). Scope:
   `phase_9_auth_plan.md` `Frontend Exposure` section.
   Within-family shared seams (`auth_operations_gateway.dart`,
   `settings_screen.dart`) require sequencing per phase doc;
   additive-safe carve-outs allowed when the prompt names them.

Codex sets the per-lane queue; this tracker lists which phases are
active, not which slices are next per lane.

**Monitored/deferred follow-ups** (operational gates listed in `Now`;
this section names slice-shaped follow-ups only):

1. `9.UX.grant-payload.0` - data-path complement to
   `9.UX.inheritance-hint.0`. Extend `users_repository.dart`
   `selectTeamUsersByOperator` to project authoritative
   `(scope_type, org_unit_id, location_id, effective_location_ids)`
   per grant on `TeamUserListItem.grants`. Until this lands, the
   inheritance-hint rendering branches stay dormant in production.
2. `cutover.0b` - Tier-M 14-row perf-gate run (B38 partial); launch
   blocker.
3. B49/B50 MFA hardening + notification delivery - `9.UX.1a` queues
   `event_outbox` rows only; true notification delivery rides Phase 10a
   bridge. Only revisit if user-facing copy promises in-app/email
   delivery.
4. Mandatory admin-tier MFA enforcement - explicitly deferred until
   post-launch stability + explicit approval. Not a launch blocker.

**Then continue:**

1. `7.58` - Primary Driver audit.
2. `10a` - Shared state v1 (`event_outbox` -> Pub/Sub/WebSocket bridge;
   `NOTIFY` is wake-up only and never the source of truth).
3. `10.5` - Live daypart shift.
4. `9.5` - El Podio learning identity.
5. `9.75` - Staff daily companion.
6. `7.61` - Freshness audit.
7. `8` and `8R` - POS/labor/finance and reservation transport.
8. `8.5` - narrowed outbound finance integrations.
9. `11b`, `11b.1`, `11b.2` - Advisor UX, schema sweep, causal queries.
10. `12.0-12.5` - Workflow platform foundation and flagship workflows.
11. `11A.7-10`, `10b`, `9.8`, `cutover.0a`, `cutover.0-5`.

Slice scopes live in their phase plans. Architecture rationale lives in
`phase_11a_decision_register.md` and the Phase 9 scalability decisions doc.

## Phase Board

| Phase | Status | Plan |
| --- | --- | --- |
| `7.57` | complete | archived |
| `11a` | accepted | `phase_11a_advisor_infrastructure_plan.md` |
| `9.0-9.10` (incl. `9.0a`) | accepted; Cloud Armor monitored, iOS physical deferred | `phase_9/phase_9_auth_plan.md` + `phase_9/phase_9_execution_backlog.md` |
| `9.0 Sigma b-k` | complete on master and applied to staging + Production1 | `phase_9/phase_9_scalability_decisions_2026-04-27.md` + backlog B23-B32 |
| `9.UX.*` family | active; accepted: `9.UX.0`/`1`(incl.`1a`)/`2`/`4`/`5`/`account-info`/`inheritance-hint.0`; owed: `9.UX.3`/`6`/`7`/`grant-payload.0` | `phase_9/phase_9_auth_plan.md` `Frontend Exposure` |
| `11A.0-6` | active; accepted: `11A.0`/`1`/`2`; owed: `11A.3-6` (`11A.5`/`11A.6` blocked on B44/B45/B47 producers) | `phase_11A_operations_console_plan.md` |
| `7.58`, `7.61` | queued | their respective plans |
| `10a`, `10.5` | queued | their respective plans |
| `9.5`, `9.75` | queued | their respective plans |
| `8` | queued | phase 8 plan |
| `8R` | queued | phase 8R plan |
| `8.5` | queued | `phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` |
| `11b` / `11b.1` / `11b.2` | queued | `phase_11b/phase_11b_advisor_ux_plan.md` |
| `12.0-12.5` | queued (gated by B41 live apply/smoke) | `phase_12_workflow_platform/phase_12_workflow_platform_plan.md` |
| `11A.7-10` | queued | `phase_11A_operations_console_plan.md` |
| `10b` | queued | `phase_10b/phase_10b_full_offline_sync_plan.md` |
| `9.8` | queued (lands last) | `phase_9_8/phase_9_8_compliance_and_legal_plan.md` |
| `cutover.0a`, `cutover.0b`, `cutover.0-5` | queued | `phase_production_cutover/phase_production_cutover_plan.md` |

## Hard Gates

The 10 Hard Promises in `CLAUDE.md` are the durable rule set. Tracker-
specific gates only:

- Tracker truth cannot move ahead of repo truth.
- All `7.58` sub-slices accept before `11b.0`; all `7.61` sub-slices
  accept before Phase 8.
- `cutover.0b` Tier-M 14-row perf gate (launch blocker).
- Production migrations use online-migration patterns once real operator
  data exists; transition point is `cutover.4` accepting.
- 35 scalability locks (2026-04-27) are in
  `phase_9/phase_9_scalability_decisions_2026-04-27.md`.

Architecture rationale: `phase_11a/phase_11a_decision_register.md`.
Cadence + parallel-lane rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Decision Locations

- Architecture / cost / pricing / dormancy / fallback rationale:
  `phase_11a/phase_11a_decision_register.md`.
- 35 locked scalability decisions (Q1-Q22 + Q3.1-Q3.10):
  `phase_9/phase_9_scalability_decisions_2026-04-27.md`.
- Performance audit + 14-row perf gate:
  `phase_9/phase_9_scalability_performance_audit_2026-04-27.md`.
- Active 11a tasks: `phase_11a/phase_11a_advisor_infrastructure_plan.md`.
- Other phase plans: routed via `Phase Board` above.
- Pre-lean history: `docs/archive/trackers/PROJECT_TRACKER_2026-04-26_PRE_LEAN_AZURE_PIVOT.md`.

## Notes

- `$HOME/.forge_flow/forge_flow.secrets.ps1` is the canonical private local
  env loader. It is outside the repo and must not be committed or pasted.
  `.env.local` remains ignored if recreated, but is no longer the source of
  truth for local keys.
- Supabase reports under `docs/archive/phases/phase_11a/phase_11a_11b*` and
  `phase_11a_11c2/11c3*` are historical after the Azure pivot.
- If an active prompt seems to require a key, account, cloud project, CLI,
  billing setup, dashboard setup, or infrastructure choice, the prompt must say
  so in Block 1 before Claude receives the paste block.
