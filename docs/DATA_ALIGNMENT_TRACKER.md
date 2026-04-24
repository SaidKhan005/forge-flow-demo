# Data Alignment Tracker

Updated: 2026-04-24
Owner: You
Purpose: keep the app aligned for live POS, labor, and reservation integrations before Phase 8 / 8R

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Desired Separation

Vendor APIs / Fixture Replays
-> Adapter DTOs
-> Canonical source facts
-> Domain services / use cases
-> Repositories
-> SQLite persistence
-> In-memory app state
-> UI

In plain terms:

- adapters pull source data
- the app reshapes it into canonical facts immediately
- SQLite holds the rolling restaurant truth plus active planning state
- providers/notifiers expose repository-backed app state
- UI renders app state without knowing vendor payload shape

## Active Alignment Baseline

- transport is still fixture/replay/demo-backed
- the internal app path is already canonical-model -> SQLite -> app state -> UI
- Phase 8 should replace transport, not create a second UI-facing truth path

## Delivered Foundations

| Slice | Status | Summary |
| --- | --- | --- |
| `7.55l` | complete | `TargetCycle`, `DemandForecastContext`, and `WeeklyPlanSnapshot` runtime architecture landed |
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
| `7.55q` | complete | architecture-conformance lane landed through `7.55q.10`: single-plan / single-benchmark-target rule codified, non-closed Variance rewired 1:1, History restored to preserved locked-target truth, planned labor killed, whole-day Shift target alignment landed, post-q authority/test hygiene synced, cycle-backed Benchmark override wiring landed, and Dollar Impact card unified with frozen-at-close parity (SQLite v22 migration + shared widget) |
| `7.55o` | active | shared-surface extraction / shell split lane resumed after the q-lane source-truth cleanup |

## Current Next Steps

- Current:
  - resume `7.55o.1` through `7.55o.6`
  - follow the automatic Codex prompt loop in `docs/CODEX_PROMPT_GENERATION_STANDARD.md`: verify repo truth, update tracker truth only after accepted slices, then generate the next prompt from the updated trackers
  - use the `7.55o` companion docs before any code movement:
    - non-behavior-change contract
    - verification matrix
    - extraction ownership map
  - treat the broad UX shell/header pass as already landed:
    - shared sticky/fading headers
    - Shift / Variance / History / Learn / Plan / Benchmark shell cleanup
    - Settings visual rework
- Then:
  - revisit canonical live-facts contract planning
  - use `7.55j.3` and `7.55j.4` as the active pre-Phase-8 vendor packaging authority
  - revisit `docs/internal/status_ledger_post_7_55p_deep_check.md` before any new pre-Phase-8 readiness answer
  - keep the bounded post-audit cleanup list visible without treating it as
    a new q-lane:
    - dev-only audit-panel service wrap + drift detection + cycle/week
      provenance readout (`7.55r`)
    - persisted timing/service-period wiring closeout (`7.55r`)
    - UTC metadata timestamp normalization (`7.55r`)
    - non-locked WTD business-date membership audit (`7.55r`)
    - editable restaurant timing + service-period settings write path
      (`10a`)

## Alignment Guardrails

- 60-day benchmark snapshot is calibration evidence
- `TargetCycle` locks standards for 60 days
- `DemandForecastContext` can roll from level 1 baseline + fixed 3-week recent trend
- `WeeklyPlanSnapshot` auto-generates and locks the week for comparison surfaces
- the locked weekly plan is the current-week plan authority; the app should not carry a second competing live plan for the in-force week
- Benchmark sets the standard, Plan decides the week, Shift manages right now, Variance compares plan vs actual, History preserves what closed, and Learn teaches from repeated closed results
- non-closed Variance rows should inherit benchmark targets + locked-plan targets 1:1 rather than recomputing per surface
- closed Full Week rows stay locked historical truth
- blended wage should come from one shared benchmark target value, not multiple screen/model recomputations
- whole-day Shift target alignment landed through `7.55q.7`; `10.5` still owns live service-period/daypart-aware Shift behavior and driver teaching
- app-owned service-period definitions + timestamp bucketing remain the preferred direction
- restaurant timing + service-period runtime implementation landed in `7.55n`
- `7.55n` now extends into current-state freshness / live-data behavior before the remaining `7.55p` benchmark cleanup
- current runtime freshness is reload-driven today; `7.55p.4a` through `7.55p.4d` own the later connector-fed live freshness / invalidation policy
- intended manager behavior is:
  - live floor data when fresh enough to be treated as current
  - explicit freshness age when not live
  - Shift as the highest-priority live surface
- file extraction / engineering hygiene is now back on the active path in `7.55o`
- the broad `7.55o` UX shell pass is already landed; remaining `7.55o` work should not reopen the source-truth-neutral shell/header cleanup
- Shift's whole-day view is authoritative; `10.5` adds an additive daypart view alongside it without replacing whole-day
- History stays closed-truth only
- Learn benchmark-context and coaching-summary cleanup landed through
  `7.55l.8` + `7.55k`; active alignment truth no longer treats named
  Learn surface seams as open
- no new manager workflow
- no draft/publish language in the UI
- fixed `14 shifts` debt spans runtime, replay seeding, tests, UI copy, and active integration docs
- `7.55p.5` is fully landed through `7.55p.5j`; use the status ledger for the detailed recommendation, graph, wage-authority, and planned-labor closeout notes instead of treating the active tracker as the long-form archive
- `7.55q` is fully landed through `7.55q.10`; use the phase docs and status ledger for the detailed architecture-conformance, Shift-alignment, post-q hygiene, cycle-backed override-wiring, and Dollar Impact card unification closeout notes
- use `docs/internal/status_ledger_post_7_55p_deep_check.md` as the reference sheet for older ask reconciliation:
  - what `7.55p.2` / `7.55p.3` / `7.55p.4d` / `7.55p.5` did and did not close
  - what to revisit before `7.55o.*` polish work and `7.55j.4` readiness review
- wage-authority reminder:
  - the app should keep one resolved FOH/BOH wage authority path
  - any improved Settings wage setup should still end by syncing resolved wages into the active target profile
  - do not create a second UI-only wage truth path
- internal SQL-backed simulation is not the same thing as full integration readiness

## Current Source Ownership Guardrails

- POS owns:
  - business date when POS is the sales authority
  - sales
  - checks/tickets
  - covers when exposed reliably
  - close/finalization semantics where available
- Labor owns:
  - schedules
  - punches/timecards
  - actual worked hours
  - role assignments
  - labor dollars or wage truth when exposed
- Reservation platform owns:
  - reservation party size
  - reservation time
  - reservation status and status timestamps
- App owns:
  - benchmark snapshot
  - `TargetCycle`
  - `DemandForecastContext`
  - weekly plan snapshot
  - app-side service-period mapping
  - reservation-book aggregation
  - whole-day Shift behavior until `10.5`

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
- `docs/phases/7_55q/phase_7_55q_10_dollar_impact_card_unification.md`
- `docs/internal/status_ledger_post_7_55p_deep_check.md`
- `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`
- `docs/phases/7_55o/phase_7_55o_refactor_non_behavior_change_contract.md`
- `docs/phases/7_55o/phase_7_55o_verification_matrix.md`
- `docs/phases/7_55o/phase_7_55o_extraction_ownership_map.md`
- `docs/phases/phase_7_55r/phase_7_55r_foundation_closeout_plan.md`
- `docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md`
- `docs/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md`
- `docs/phases/7_55j/phase_7_55j_4_gap_report.md`
- `docs/phases/7_56/phase_7_56_reservation_book_signal_plan.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`
- `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`

## Archive And Reference

- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
