# Forge & Flow Project Tracker

Updated: 2026-04-15
Owner: You
Execution model: We think, Claude codes

## Active Authority

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md` when the slice is alignment-heavy
- explicitly referenced active phase docs

Archive:
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Active Focus

- Current phase: `7.55o` refactor / extraction lane resumed after `7.55q.1` through `7.55q.9`
- Current prompt: `7.55o.1` - shared surface primitives extraction
- Current goal: resume extraction without reopening the landed single-plan / single-benchmark-target / whole-day-Shift source-truth contracts
- Current UX shell state: the broad header / shell / Learn / Settings / Plan / Benchmark / Variance visual pass is already landed; remaining `7.55o` work should build on it rather than reopen it
- Current live-integration scope: one restaurant/location, not multi-location org management
- Naming guardrail: keep internal `Baseline` / `Schedule` names unchanged during this alignment pass

## Phase Summary

| Phase | Status | Summary |
| --- | --- | --- |
| `7.55l` | complete | `TargetCycle` + `WeeklyPlanSnapshot` runtime architecture landed |
| `7.55m` | complete | runtime-truth cleanup landed |
| `7.55k` | complete | daypart / Variance / History / Learn plan landed through `7.55k.8a` |
| `7.55n` | complete | restaurant timing + service-period runtime foundation landed through `7.55n.6a`; freshness / live-data extension landed through `7.55n.13` |
| `7.55p.1` | complete | Shift driver trust audit landed against Chapter 10 |
| `7.55p.2` | complete | Variance WTD target alignment and Full Week target-package / carry-forward cleanup landed through `7.55p.2a` |
| `7.55p.3` | complete | Dollar Impact accumulation model landed through `7.55p.3a` |
| `7.55p.4a` | complete | app-owned refresh / invalidation policy landed through `7.55p.4a1` |
| `7.55p.4b` | complete | connector-fed live freshness propagation landed through `7.55p.4b1` |
| `7.55p.4c` | complete | replay integrity / mock-to-live transition audit landed through `7.55p.4c1` |
| `7.55p.4d` | complete | persisted passive notifications landed through `7.55p.4d1` |
| `7.55p.5` | complete | Benchmark OPZ / graph honesty audit, OPZ-width research, target-labor package contract, Variance theoretical-package verification, blended-wage audit, recommendation-statistics contract cleanup, wage-mix setup UX, the app-owned recommended benchmark selection service, its restaurant-scope runtime fix, the Benchmark graph fallback/explainer cleanup, and the scope-aware planned labor package contract + wiring landed through `7.55p.5j` |
| `7.55q` | complete | architecture-conformance lane landed through `7.55q.9`: single-plan / single-benchmark-target contract codified, non-closed Variance rewired 1:1, History restored to preserved locked-target truth, planned labor killed, whole-day Shift target alignment formalized, post-q authority/test hygiene synced, and cycle-backed Benchmark override wiring landed |
| `7.55o` | active | shared-surface extraction / shell split lane resumed now that the q-lane source-truth contracts are landed |

## Current And Next

- Current:
  - `7.55o.1` shared surface primitives extraction
- Then:
  - `7.55o.2` Variance shell split
  - `7.55o.3` Schedule planning surface separation
  - `7.55o.4` Settings surface split
    - keep the read-only timing authority visible there; defer editable
      timezone/timing authority until full restaurant-local timezone
      conversion and persisted timing-control wiring are landed
  - `7.55o.5` Baseline Manager decomposition plus remaining candidate-truth / bridge cleanup
  - `7.55o.6` SQLite bootstrap breakup only if still justified
  - keep the landed UX shell pass recorded as done:
    - shared sticky/fading headers across core tabs
    - Shift header/live-time polish
    - Variance / History / Learn shell cleanup
    - Plan / Benchmark header-stat cleanup
    - Settings visual rework
  - revisit canonical live-facts contract planning after the extraction lane
  - `7.55j.3` vendor endpoint checklist template
  - revisit `docs/internal/status_ledger_post_7_55p_deep_check.md` before `7.55j.4` / the pre-Phase-8 readiness answer
  - `7.55j.4` gap report
  - keep the post-audit bounded cleanup list visible without reopening the
    landed q-lane contracts:
    - dev-only `DataAlignmentAuditPanel` service wrap
    - persisted timing/service-period wiring closeout
    - UTC metadata timestamp normalization
    - non-locked WTD business-date membership

## Active Guardrails

- standards lock on a 60-day `TargetCycle`
- demand can roll from level 1 baseline + fixed 3-week recent trend
- the operating week should auto-generate one locked `WeeklyPlanSnapshot`
- the locked weekly plan is the current-week plan authority; do not carry a second competing live plan for the in-force week
- Benchmark sets the standard, Plan decides the week, Shift manages right now, Variance compares plan vs actual, History preserves what closed, and Learn teaches from repeated closed results
- non-closed Variance rows should read one shared benchmark target object plus one shared locked-plan object 1:1, row by row, value by value
- closed Full Week rows stay locked historical truth
- blended wage should be a shared benchmark target value, not recomputed separately by screen/model helpers
- whole-day Shift target alignment landed through `7.55q.7`; `10.5` still owns live service-period/daypart-aware Shift behavior and driver teaching
- no new manager workflow
- no draft/publish state in the UI
- widgets should not own source-truth decisions
- widgets should not own service-period bucketing rules
- Full Week projection semantics should come from a read service / read model, not mixed screen helpers
- we are not fully integration-ready yet; do not describe SQL-backed internal simulation as simple-swap readiness
- current runtime freshness is reload-driven today; `7.55p.4a` through `7.55p.4d` own the connector-fed live freshness / invalidation policy
- intended manager behavior is stronger than reload-driven freshness:
  - show live floor data when current-state is fresh enough to be treated as live
  - otherwise show explicit freshness age such as `Updated 7 min ago`
  - Shift is the highest-priority live surface
- stale current-state must not masquerade as live
- Learn is partially migrated today:
  - Repeatable Wins is evidence-backed
  - Benchmark Set / Recurring Leak / Coach Next Week still use compatibility seams
- fixed `14 shifts` debt spans runtime, replay seeding, tests, UI copy, and active integration docs
- Baseline Manager is not extraction-only; its first future touch should focus on the remaining candidate-truth / bridge cleanup rather than reopening the already-landed wage-authority fix
- use `docs/internal/status_ledger_post_7_55p_deep_check.md` as the reference sheet for:
  - which older user asks are already done vs partial vs still open
  - the remaining `7.55o.*` naming/polish lane after the landed shell pass
  - the later `7.55j.4` readiness-check conversation
- `10.5` still owns live Shift service-period behavior, live time-into-service, and daypart-live driver teaching

## Active Planning Docs

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/7_55q/phase_7_55q_1_architecture_conformance_contract_and_drift_codification.md`
- `docs/phases/7_55q/phase_7_55q_2_plan_authority_cleanup.md`
- `docs/phases/7_55q/phase_7_55q_3_benchmark_target_object_cleanup.md`
- `docs/phases/7_55q/phase_7_55q_4_variance_linearity_rewiring.md`
- `docs/phases/7_55q/phase_7_55q_5_history_conformance_cleanup.md`
- `docs/phases/7_55q/phase_7_55q_6_kill_planned_labor_package.md`
- `docs/phases/7_55q/phase_7_55q_7_shift_whole_day_target_alignment.md`
- `docs/phases/7_55q/phase_7_55q_8_authority_sync_and_test_hygiene_cleanup.md`
- `docs/phases/7_55q/phase_7_55q_9_benchmark_override_cycle_wiring.md`
- `docs/internal/status_ledger_post_7_55p_deep_check.md`
- `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`
- `docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md`
- `docs/phases/7_56/phase_7_56_reservation_book_signal_plan.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`

## Notes

- Detailed slice-by-slice history was archived to `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`.
- Completed `7.55l` and `7.55m` docs now live under `docs/archive/phases/7_55l/` and `docs/archive/phases/7_55m/`.
- Completed `7.55i`, `7.55k`, `7.55n`, `7.55p`, and the completed `7.55j.1` / `7.55j.2` / `7.55j.gate` docs now live under `docs/archive/phases/`.
- Active architecture authority docs now live under `docs/contracts/`.
