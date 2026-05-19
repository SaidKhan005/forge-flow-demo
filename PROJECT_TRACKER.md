# Forge & Flow Project Tracker

Updated: 2026-05-18. Routing map only: shows **only what is left**.
Completed phases/slices: `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
Stale sprint-execution docs: `docs/archive/_execution/`. `docs/archive/**`
is history; ignore unless explicitly named.

**Active work:** Per-Daypart Targets V1 (forward plan
`docs/_indices/NEXT_WAVE_PLAN.md`; plan
`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`).
Workflow is executor-agnostic per CLAUDE.md "Workflow". CI is intentionally
dark until 2026-06-01 (workflow_dispatch only) — verify high-risk slices
with disclosed local `dart analyze`/`flutter test`.

Owner: You · Execution: We think, agents code (orchestrator-audited).

**Index:** Authority Order · Indices · Hard Product Rule
(Hierarchy-Scoped Settings) · Open Work (operator-blocked · cutover ·
engineering) · Vendor live rollout · Paused · Prompt Fetch Map ·
North Star · Active Lanes · Hard Gates · Notes ·
Recently landed · Recently archived.

Phases retired to `docs/archive/phases/` 2026-05-13: `phase_10b`,
`phase_11b`, `phase_12_workflow_platform`, `phase_8_5_external_integrations`
(paused per V1 lean cut — no V1 launch dependency).

## Authority Order (Active Read Order)

1. `PROJECT_TRACKER.md` (this file) — routing.
2. `docs/contracts/**` — durable rules.
3. `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items.
4. The active phase doc named for the slice (Prompt Fetch Map below).
5. Decision registers when the slice needs arch/cost/security rationale:
   `docs/phases/phase_11a/phase_11a_decision_register.md`,
   `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`,
   `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
6. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape, parallel-lane rules.
7. `runbooks/deploy_runbook.md` ·
   `docs/frameworks/PERFORMANCE_FRAMEWORK.md` ·
   `docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md` ·
   `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` — applied per slice when relevant.

Feature implementation work also uses
`docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` whenever a
slice edits or adds product functionality, route/schema behavior, runtime
behavior, settings, permissions, or any feature with hidden plumbing risk.

`docs/archive/**` is history; ignore unless explicitly named. Authority is
normative in `CLAUDE.md`.

Prefer `.mcp.json` servers for orientation: `forgeflow_docs`,
`forgeflow_sqlite_schema`, `graphify`.

## Indices (current state)

| Index | Audience | Purpose |
| --- | --- | --- |
| `docs/_indices/NEXT_WAVE_PLAN.md` | All | Forward 6-phase pipeline. **Phase 2.5 — Per-Daypart Targets V1 is the active feature work** (output of Phase 2 mobile walkthrough). |
| `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` | All | **Active feature plan.** Self-contained; 14 decisions locked; 9 slices; 44 gaps consolidated; reusable audit method. |
| `docs/_indices/WAVE_2_LEDGER.md` | Reference | Wave 2's slice ledger. Operator-web + admin lanes CLOSED 2026-05-14; mobile lane closed for walkthrough 2026-05-15 (transitioned to Per-Daypart Targets V1). |
| `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` | All | Source-of-truth on every brain-dump ask from `debug.md` mapped to ✅/🚧/❌/🔍 with citations. |
| `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` | Operator (paste-ready) | General Claude executor handoff. |
| `docs/_indices/CODEX_HANDOFF_PROMPT.md` | Operator (paste-ready) | Same shape for Codex (dormant; out of quota). |
| `docs/_indices/README.md` | All | Explains the index pattern + when to read which doc. |

**Archived indices** (closed-wave artifacts retired 2026-05-15):
`docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md`
(Wave 1 ledger),
`docs/archive/_indices/wave_2_closeout_2026_05_15/` (Claude2-lane
handoffs + R-2L proposal + help queues — Wave 2 operator-web + admin
lanes closed),
`docs/archive/_indices/CLAUDE_LANE_INDEX_2026-05-13.md` +
`CODEX_LANE_INDEX_2026-05-13.md` (post-Codex wave lane indices).

## Hard Product Rule - Hierarchy-Scoped Settings

Every setting that can affect a business account resolves through the operator
hierarchy. A value may be set at the business/operator level and inherited by
all descendants. The same setting may also be set at any org-unit or location
level. The lowest configured scope wins; missing lower scopes inherit from the
nearest ancestor.

All admin, operator web, proxy, migration, and mobile surfaces that expose
settings must support that rule or explicitly document why a capability is
backend-only, gated, incomplete, or intentionally unsurfaced. The UI must show
the selected scope, the inherited source, and the effective value before any
mutation. Integrations are the known exception: they still prompt for hierarchy
context, but edits are location-level because vendor connections are bound to a
specific location.

## Open Work — V1 launch path

Three workstreams remain before V1 declaration. Two are operator-blocked,
one is engineering-blocked.

### 1. Operator-blocked (no engineering)

Detail + resume guide: `docs/archive/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

| Item | Owner | Blocks |
|---|---|---|
| Firebase Auth action-domain switch (`auth.feflow.org` → `forge-flow-production1.web.app`, set `callbackUri`, run 4 validation checks) | You / Cloud | `cutover.0` preflight |
| Decide + apply 2 remaining Production1 migrations (first-connect-backfill jobs + 11W.7 operator account fields). 18 of 20 already staging-verified; full queue in `docs/POST_HARDENING_FOLLOWUPS.md` P0 | You + runbook | First-connect on prod, operator-web Account writes on prod |
| Seed operator-authored T&C content into `tos_versions` (universal + per-vendor scopes) at deploy time. Operator self-authors per `docs/contracts/operator_self_served_tos_contract.md`; no external legal-review gate. | You / Eng | `cutover.2` |
| Sandbox creds for trio: Lightspeed K-Series · Libro · QuickBooks Time | You / Vendors | `*.live.sandbox` slices for trio |

### 2. Cutover sequence (gate-driven, not date-driven)

Plan: `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`.

| Gate | Status | Notes |
|---|---|---|
| `cutover.0` preflight | not started | Read-only smoke on Production1; harness ready (V1.G). Needs Firebase Auth switch + 2 pending migrations applied |
| `cutover.1` corpus load | not started | Voyage embeddings + Anthropic Contextual Retrieval; cost approval gate |
| `cutover.0b` Tier-M perf gate | not started | Launch-blocking; needs `cutover.1` corpus first |
| `cutover.2` first operator onboarding | not started | Vanessa on production1; needs operator-authored T&C content seeded in `tos_versions` |
| `cutover.3` traffic switch | not started | DNS / env-var flip |
| `cutover.4` 7-day stability watch | not started | Non-negotiable before V1 declaration |
| `cutover.5` post-launch hardening | not started | After V1 declaration |

### 3. Engineering still in scope

| Slice | Status | Plan |
|---|---|---|
| **Per-Daypart Targets V1** (Phase 2 mobile walkthrough output) | **active implementation; Slices 0 to 5 landed (covers-source per-period schema + bottom-up locked weekly-plan snapshot + per-period verdict carry); later slices + benchmark-rework follow-ups in flight** | **`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`**: 9 slices (0 to 1 to 1.5 to 2 to 2.5 to 3 to 4 to 5 to 6); 44 gaps consolidated post-audit; removes recommendation engine's pooling kludge so per-period targets flow end-to-end; restores Promise 3 / Layer 9. Slice 0 amends `phase_7_55_time_boundary_contract.md` Rules 5+6 and `phase_7_55_target_cycle_weekly_plan_rules.md` Rule E for Option 2 cycle gating. Landed covers-source de-hardcode R5/R7a to R7d (#943/#972/#975 to #977; **#977 schema-destructive: drops legacy whole-day columns + trims view scalars**); run `migration_drift_scanner` + `migration_cutoff_lint` after any further `db/migrations` change. |
| `11A.8` Support audit | not started | `phase_11A_operations_console/*` |
| `11A.9` Cross-operator reads | not started | `phase_11A_operations_console/*` |
| `11A.10` Operator impersonation | not started | `phase_11A_operations_console/*` |
| `9.8` inbound vendor T&Cs (code lane) | code-ready; operator-self-served content seeding pending | `phase_9_8/*` |
| `business-timing-live` full hierarchy + settings lanes | future | `phase_business_timing_live/*` |
| `admin-hierarchy-settings-overhaul` | complete (2026-05-12; evidence: `docs/archive/_execution/admin_hierarchy_settings_overhaul/06_closure_evidence_2026-05-12.md`) | `docs/archive/_execution/admin_hierarchy_settings_overhaul/` (plan archived to `docs/archive/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md`) |
| HP#11 cross-surface parity (admin DI wiring) | complete (closed 2026-05-16; real admin timing-surface effective-value resolution + My Account / business-timing-resolution production DI hops landed #906/#923/#925) | cross-surface-parity backlog wave closed |
| Doc 1 item 7 — physical connected-device E2E | simulated proof documented; physical/emulator proof pending | new sprint `8.connected-device-e2e-smoke`; needs physical device |
| Doc 1 item 9 — push delivery proof | preflight documented; needs staging apply + device | `8.push-notification-connected-device-proof` |
| Group / region / company rollup truth | future | follows server rollup snapshots |

## Vendor live rollout (rolling, parallel — does NOT block V1 launch)

All 17 INTEGRATE adapters are at lifecycle = `documented`. Each `*.live.sandbox`
and `*.live.prod` slice fires only when vendor credentials arrive. Tracker:
`phase_8_live_rollout/phase_8_live_rollout_plan.md`. Soft-blocked on V1.E
`vendor-now-available` email fan-out being already merged (it is).

| Wave | Vendors | Lane id |
|---|---|---|
| Wave 1 — needed for launch UX | Lightspeed K-Series · Libro · QuickBooks Time | `8.LSK.live.{sandbox,prod}` · `8R.LB.live.{sandbox,prod}` · `8.S.QBT.live.{sandbox,prod}` |
| Wave D — partnership-paced | Toast · Clover · Oracle Simphony · ADP · Aloha · NCR · Square · 7shifts · Revel · Tock · OpenTable · SevenRooms · Humanity · Agendrix · Push Operations | matching `8*.<vendor>.live.{sandbox,prod}` |

## Paused

Resume notes: `memory/project_phase_pause_2026_05_03.md`,
`memory/project_barrio_paused.md`.

| Phase | Reason |
|---|---|
| `11b` / `.1` / `.2`, `12.0`–`12.5`, `11A.3` + `11A.3.x`, `11A.11`, `9.8` advisor portion, `10b` | AI freeze |
| `8.5`, `11W.9` | Outward-vendor freeze |
| `9.5.UX.*`, `9.75`, `lib/internal/barrio/**`, `lib/main_barrio.dart` | Barrio freeze |

**`11A.3.x` graphify-candidates — paused-by-design note (2026-05-07):** the
graphify candidate review proxy routes (`tool/advisor_proxy/advisor_proxy.dart`
`graph_candidates_not_configured` / `graph_candidates_unavailable` 503s)
ship as scaffolding and intentionally 503 without a hand-staged
`tool/advisor_proxy/graphify_candidates/candidates/` bundle. Confirmed
operator decision to keep this in the AI-paused set; do **not** build the
bundle staging automation during the freeze. Resume when `11b` / `11A.3.x`
unpause; first task on resume is graphify-candidates bundle staging.

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11A.*` | `phase_11A_operations_console/phase_11A_operations_console_plan.md` |
| `cutover.*` | `phase_production_cutover/phase_production_cutover_plan.md` |
| `9.8` | `phase_9_8/*` |
| `*.live.*` | `phase_8_live_rollout/phase_8_live_rollout_plan.md` |
| `8.5`, `9.5`/`9.75`, `11b*`, `11W.9`, `12.*` | matching `docs/phases/**` doc |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark
Snapshot → TargetCycle + DemandForecastContext → SchedulePlan →
WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases may
run in parallel. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Parallel Worktrees".

**Currently running**: nothing engineering-blocked. The remaining engineering
slices (11A.8/.9/.10, business-timing-live extensions, Doc 1 items 7/9)
are queued behind operator-blocked items above and have no active worktree.

**Wave D — rolling `*.live.*` slices** fire individually as credentials
arrive.

**Skip until unfreeze**: see Paused list above.

## Hard Gates

- `cutover.0b` Tier-M perf gate is launch-blocking; needs `cutover.1`
  corpus seed first.
- Production migrations use online-migration patterns once real operator
  data exists; transition at `cutover.4`.
- Migration changes: `dart run tool/migration_drift_scanner.dart --fix
  --strict-docs`, then `dart run tool/migration_cutoff_lint.dart`.
- Runtime-exposed slices should follow
  `docs/contracts/slice_runtime_acceptance_contract.md` (advisory pattern,
  not CI-enforced — reviewer judgment, not auto-blocking). Browser-exposed
  slices use Codex-driven Browser Use evidence per
  `runbooks/browser_use_codex_acceptance_workflow.md` (out-of-repo automation,
  not a binary in this tree) and full E2E uses
  `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`.
- Before staging console perf claims:
  `dart run tool/perf_gate/staging_console_probe.dart --run
  --admin-url=<url> --proxy-url=<url>` and attach JSON.
  `--enforce-budgets` for PR/release gates; `--include-health` only for
  bounded health probes.
- 35 scalability locks
  (`phase_9_scalability_decisions_2026-04-27.md`) authoritative; 10 Hard
  Promises in `CLAUDE.md` durable.

## Notes

- CI is intentionally dark until 2026-06-01 (see header). Verify
  high-risk slices with disclosed local `dart analyze` / `flutter test`;
  use `tool/pre_merge_gate.sh` and `tool/verify_pr_landed.sh`.
- Mobile architecture (canonical-fact dicts → operator-scoped Postgres
  `shift_records` → mobile SQLite via proxy sync) bound by
  `integration_spine_architecture_contract.md`.
- 2026-05-05 vendor-research falsehoods captured in
  `integration_spine_architecture_contract.md` "2026-05-05 falsehood
  corrections" section.
- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the
  canonical private env loader (outside repo).
- Closed-phase audits/closeouts live in `docs/_execution/`; follow
  CLAUDE.md "Phase Doc Hygiene" and retire to `docs/archive/phases/`
  within a week.
- If a prompt requires a key, account, cloud project, billing setup, or
  infrastructure choice, surface it in Block 1.
- **Notify before** any live Firebase mutation, key/account request,
  billing setup, provider call, or product decision.

## Recently landed (2026-05-16 to 2026-05-18; 92 non-merge commits on `origin/master`)

Themed digest of what landed since the last tracker refresh (commit
`54dbd2f5`). None of this changes the V1 launch path above; it is
feature build-out, doc alignment, and repo hygiene.

- **Covers-source per-period schema (Per-Daypart V1 Slice 0 to 5):**
  R5 covers-source de-hardcode + keyed-table backfill (#943); R7a
  per-period hierarchy view + scoped-override re-key, additive (#972);
  R7b proxy onto per-period keyed view, wire-compatible (#975); R7c
  dead legacy-column Dart removed (#976); **R7d FINAL,
  schema-destructive: drops legacy whole-day columns + trims view
  scalars (#977)**. Bottom-up locked weekly-plan snapshot (#917/#941);
  Slice 5 Variance Full Week non-closed rows read locked sub-rows
  (#951); SA/SD/SE benchmark-rework + per-period verdict carry
  (#907/#919/#926/#934).
- **Doc-alignment audit Phases 1 to 4 (contracts vs code):** Phase 1
  core_app_architecture.md alignment + 4 drift corrections
  (#981/#982); Phase 2 Tier-2 contracts + corrections (#983/#985);
  Phase 3 priority code/schema-binding contracts + corrections
  (#984/#985); Phase 4 remaining contracts (#986); full-scope fixes
  for 3 flagged items: ToS impl, migrations summary, 7.58 + accuracy
  lags (#987). Contract edits owned by that audit lane, not this
  tracker.
- **Choose Star Shifts redesign (R1 to R10):** operator-config daypart
  lens + 2-state hero calendar + pre-commit gate (#932); tap-day
  bottom sheet whole-day rollup (#940); Lean/Balanced/Generous band
  (#946); 4-period demo operator proving daypart de-hardcode (#929);
  align to committed prototype (#952); single continuous scroll +
  PLAN IMPACT dropdown (#959); per-daypart mix-and-match band +
  scope-label header (#966); spec + prototype docs (#947).
- **Variance Coaching V2 (Lanes A to G):** evolved copy catalog,
  Primary Driver arrow-chain widget, This Week / History V2 parity,
  History CPLH-vs-OPZ 60-day band, Learn restructure (#898 to #969
  range); Lane G wave-close test re-pin + verification (#915).
- **Mobile-UX polish:** readable type scale + spacing tokens + OS
  text scaling, premium surface system, off-scale spacing
  normalization across baseline_tracker / notifications / schedule /
  shift_dashboard, Shift gradient-card unification (#953 to #971
  range).
- **Advisor-proxy size discipline:** route groups extracted so the
  proxy falls back under its size ceiling, no behavior change (#979).
- **Repo hygiene + safety:** repo_janitor wired via the `post-merge`
  git hook with `pre_merge_gate` mandated while CI is dark;
  repo_janitor hardened to never auto-prune session/loop worktrees
  (#980); auto-hygiene enabled (dry-run default); repo-wide
  branch/worktree cleanup done; full lost-work rescue sweep completed
  (`rescue/*` branches pushed to `origin`).
- **Misc fixes:** closed-state Shift dashboard + closed-shift chrome
  suppression (#937/#950/#962), audit-panel RenderFlex overflow +
  wage-at-lock-time reframe (#920/#948), settings/integrations copy
  and DI fixes, deterministic polling-vendor filter test (#978),
  demo-seed reservation apportionment (#956).

## Recently archived

Full closed-phase / closed-wave history (2026-05-07 closeout pass,
2026-05-08 post-audit remediation wave PRs #417–#426, Phase 8/9/10a/11A/11W
accepts, CODE_HEALTH remediation, Production1 go-live) lives verbatim in
`docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`. Not duplicated here —
this file shows only what is left.
