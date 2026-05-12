# Forge & Flow Project Tracker

Updated: 2026-05-08 (post-audit remediation wave: 9 lanes merged
across PRs #417–#426 — 4 of 5 P1 audit-addition items closed +
P2 partial bare-catch fix + Carve-out #3 blessed + closed-phase
plan archive + vendor doc path updates + phase_9 folder triage +
hardening_rls contract drift + RestaurantScopeService extraction +
8.demo-mode-banner slice. The AI-frozen `advisor_proxy.dart`
placeholder strings remain on the freeze-thaw checklist. **CI is
currently blocked on a GitHub Actions billing/spending limit** —
all jobs since #425 stopped before starting; no test runs against
master have completed for this remediation wave. Verification
deferred to next CI green run. Earlier 2026-05-08: multi-agent
deep-dive audit recorded 7 new findings in
`docs/POST_HARDENING_FOLLOWUPS.md` "Audit additions — 2026-05-08"
section; admin hierarchy lane excluded). Prior: 2026-05-07.
Owner: You · Execution: We think, Claude codes

Routing map only. This file shows **only what is left**. Completed phases /
slices live in `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

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
7. `docs/frameworks/deployFramework.md` ·
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

Detail + resume guide: `docs/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

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
| `11A.8` Support audit | not started | `phase_11A_operations_console/*` |
| `11A.9` Cross-operator reads | not started | `phase_11A_operations_console/*` |
| `11A.10` Operator impersonation | not started | `phase_11A_operations_console/*` |
| `9.8` inbound vendor T&Cs (code lane) | code-ready; operator-self-served content seeding pending | `phase_9_8/*` |
| `business-timing-live` full hierarchy + settings lanes | future | `phase_business_timing_live/*` |
| `admin-hierarchy-settings-overhaul` | complete (2026-05-12; evidence: `docs/_execution/admin_hierarchy_settings_overhaul/06_closure_evidence_2026-05-12.md`) | `docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md` |
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

- **2026-05-08 — GitHub Actions billing block.** Recent CI runs show
  "The job was not started because recent account payments have failed
  or your spending limit needs to be increased." All 3 master CI jobs
  (postgres-tests, repo-lints, analyze-and-test) plus the
  Apple-platform-verification workflow stop in <15s without starting.
  This blocks automated validation of the remediation wave merged
  2026-05-08 (PRs #417–#426). Action: resolve the GitHub billing /
  spending-limit issue, then re-run CI on master.
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

## Recently archived (see `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`)

2026-05-08 post-audit remediation wave (PRs #417–#426 merged):

- 2026-05-08 audit closeout (#417) — Carve-out #3 blessed, 5 closed-phase plan docs retired to `docs/archive/phases/`, audit findings recorded.
- POST_HARDENING wage-authority line drift fix + 2026-05-12 _execution sweep reminder (#418).
- Lane A — `audit_logs_repository` defense-in-depth GUC probe (#424); chose Option B over base-class extension to preserve atomic-with-business-write contract.
- Lane B — 4 admin integration write routes wired to `admin_request_idempotency` (#425).
- Lane C — `RestaurantScopeService` extraction; `notifications_screen` + `schedule_forecast_notifier` no longer import SQLite repo directly (#419).
- Lane D — typed catch arms in `auth_session_notifier` + `tenant_transaction` + `package_postgres_executor` (PR #364 pattern; advisor_proxy 16 sites still open) (#420).
- Lane E — `8.demo-mode-banner` slice: runtime per-(O, L, C) banner, AppShell mount, walkthrough, 5 widget tests (#426).
- Lane G — `hardening_rls_and_repository_pattern_contract.md` drift fixes (lint state past-tense, 4 wrapper function names corrected) (#421); subsequently revised post-Lane-A merge to reflect the sanctioned defense-in-depth exception.
- Lane H — 9 vendor docs in `docs/integrations/<vendor>/` updated to point at archived phase plan paths (#422).
- Lane I — `docs/phases/phase_9/` folder triage: 1 of 11 moved (the closed `admin_console_mfa_challenge_parity_plan.md`); 10 kept with documented reason (durable authority refs / evergreen runbooks / not-yet-shipped specs) (#423).

CI did NOT validate this wave — GitHub Actions billing block still
in effect at merge time. Re-run CI once billing is resolved.

2026-05-07 closeout pass moved the following accepted/closed phase rows out
of the active board:

- Phase `9` framework + `9.0Σ.b-l` + `9.UX.*` ACCEPT
- Phase `9.5.0` ACCEPT
- Phase `11A` foundation `0`–`7`/`UX.health` + cross-op parity `.12`/`.13`/`.14` ACCEPT 2026-05-06
- Phase `11W.0`–`.8` ACCEPT 2026-05-06 + 11W.7 live-wire fix
- Phase `8` / `8R` / `8.S` engineering-complete (PASS 2026-05-05 via `mobile-proof.v2`)
- `8.spine-bridge-sink-fanout` 14/14 lanes + `.7S.upgrade` ACCEPT
- `8.business_date_denorm` ACCEPT 2026-05-06
- `8.first-connect-backfill-wire-in` ACCEPT 2026-05-06 (PR #195)
- `business-timing-live` foundation + UI shell ACCEPT 2026-05-06
- `8.star-target-server-truth` ACCEPT 2026-05-06
- `8.weekly-plan-server-truth` MERGED 2026-05-07 (PR #226)
- `8.business-scope-selector` mobile foundation MERGED 2026-05-07 (PR #236)
- Claude V1 closure dispatch — all 7 lanes (V1.A–G) MERGED via PRs #198–202, #226, #236
- Phase `10a` real-time infra `.0`–`.5` + `UX.0`/`UX.1` ACCEPT 2026-05-06
- Phase `7.58` depth wave ACCEPT 2026-05-05
- `9.8.email` ACCEPT (PR #88)
- CODE_HEALTH remediation closed 2026-05-08 across 5 waves (52 findings closed across 41 PRs; archived at `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`; residuals consolidated into `docs/POST_HARDENING_FOLLOWUPS.md`, phase 11a decision register, phase 8 spine bridge plan, and the auth permission key catalog)
- Production1 runtime live 2026-05-06 (Cloud Run + Firebase + Postgres-CMK + production DNS for `app.forgeflow.app` + `mail.forgeflow.app`)
- Phase 8 plug-and-play V1 onboarding engineering-complete 2026-05-07 (PRs #280-#301 across operator-self-service descriptors / validators / route alignment / test-connection / disconnect / api-key paste / location integrations list / OAuth refresh closures / backfill adapter factory / analyzer sweep). Detail: `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`. Operations work (Production1 migration apply + Cloud Run vendor app creds + partner-portal redirect URIs) gates each Wave D `*.live.*` slice firing.

Detail in `PROJECT_TRACKER_ARCHIVE.md`.
