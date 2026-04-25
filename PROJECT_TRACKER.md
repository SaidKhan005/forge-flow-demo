# Forge & Flow Project Tracker

Updated: 2026-04-24
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

- Current phase: `7.56c` Plan + Benchmark authority alignment is complete
- Last accepted prompt: `7.56c.1` expanded the dev-only data alignment audit into a full source-alignment monitor across live / actual provenance and Plan / Benchmark target authority
- Next decision is owner-driven: move to `Phase 8` / `8R` vendor-selection prep, continue bounded pre-Phase-8 cleanup, or pause for owner prioritization
- Prompt sequencing: automatic Codex loop per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`; after an accepted slice, verify repo truth, update trackers, then generate the next prompt from the updated tracker state
- Current UX / extraction state: the broad header / shell / Learn / Settings / Plan / Benchmark / Variance visual pass is landed, and `7.55o` structural extraction is complete through SQLite bootstrap breakup
- Current live-integration scope: one restaurant/location, not multi-location org management
- Naming guardrail: keep internal `Baseline` / `Schedule` names unchanged during pre-Phase-8 cleanup

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
| `7.55q` | complete | architecture-conformance lane landed through `7.55q.10`: single-plan / single-benchmark-target contract codified, non-closed Variance rewired 1:1, History restored to preserved locked-target truth, planned labor killed, whole-day Shift target alignment formalized, post-q authority/test hygiene synced, cycle-backed Benchmark override wiring landed, and Dollar Impact card unified with frozen-at-close parity between live Variance and Week Detail (SQLite v22 migration, `monthDollarImpact` / `sixtyDayDollarImpact` / `closedAt` on `WeekRecord`, shared `DollarImpactCard` widget) |
| `7.55o` | complete | shared-surface extraction / shell split lane completed through `7.55o.6`: shared comparison primitives, Variance shell split, Schedule planning separation, Settings surface split, Baseline Manager decomposition, and SQLite schema / seed / migration breakup accepted |
| `7.55r` | complete | bounded foundation closeout completed through `7.55r.2`: dev-only audit read service + drift flags + locked-week / target-cycle provenance readout landed, UTC metadata and non-locked WTD audits closed, and service-period runtime wiring verified with no production patch target |
| `7.56` | complete | reservation-book signal verified complete in `7.56a`; `7.56b` closed the pre-existing target-cycle `benchmark_selection_summaries` replay-stability failure; `7.56c.0` plus the projection-sales and target-hour field follow-ups aligned Full Week Plan / Benchmark authority, and `7.56c.1` expanded the dev-only audit into a full live / actual + Plan / Benchmark source-alignment monitor (grouped audit checks across 5 groups, 9 q-lane checks preserved) |

## Current And Next

- Current:
  - `7.56c` Plan + Benchmark authority alignment is closed; tracker truth and the two phase docs (`phase_7_56c0_full_week_projection_authority_alignment.md`, `phase_7_56c_data_alignment_audit_plan_benchmark_coverage.md`) reflect the accepted state
  - no in-flight slice — next prompt is owner-driven
- Then:
  - decide whether to move to `Phase 8` / `8R` vendor-selection prep, continue bounded pre-Phase-8 cleanup, or pause for owner prioritization
  - do not compare live operating results against targets as drift (`7.56c.1` design rule, retained going forward)
  - keep the landed UX shell pass recorded as done:
    - shared sticky/fading headers across core tabs
    - Shift header/live-time polish
    - Variance / History / Learn shell cleanup
    - Plan / Benchmark header-stat cleanup
    - Settings visual rework
  - revisit canonical live-facts contract planning after the bounded foundation closeout lane
  - keep `7.55j.3` vendor endpoint checklist template and `7.55j.4` gap report as the active pre-Phase-8 vendor-readiness authority
  - revisit `docs/internal/status_ledger_post_7_55p_deep_check.md` before any new pre-Phase-8 readiness answer
  - keep pre-launch sequencing truth visible:
    - `Phase 10a` is pre-launch shared state (Jul-Sep 2026 fourth contractor lane) and starts once `Phase 9` auth identity is usable
    - `Phase 10.5` is additive whole-day + daypart Shift behavior and ships at or near launch
    - `Phase 11a` runs in parallel with `Phase 8` / `8R` / `9`
    - `Phase 11a` + `11b` advisor work ships before `Phase 9.75` Barrio V1.1
    - `Phase 10b` remains post-launch future work
  - keep the post-audit bounded cleanup list visible without reopening the
    landed q-lane contracts:
    - dev-only `DataAlignmentAuditPanel` cycle/week provenance readout landed in `7.55r.1`
    - persisted timing/service-period wiring closeout verified / closed in `7.55r.2`
    - UTC metadata timestamp normalization and non-locked WTD membership audit are already documented in `7.55r` as closed / no-patch findings

## Active Guardrails

- standards lock on a 60-day `TargetCycle`
- demand can roll from level 1 baseline + fixed 3-week recent trend
- the operating week should auto-generate one locked `WeeklyPlanSnapshot`
- the locked weekly plan is the current-week plan authority; do not carry a second competing live plan for the in-force week
- Benchmark sets the standard, Plan decides the week, Shift manages right now, Variance compares plan vs actual, History preserves what closed, and Learn teaches from repeated closed results
- non-closed Variance rows should read one shared benchmark target object plus one shared locked-plan object 1:1, row by row, value by value
- non-closed Full Week daypart plan targets should come from the same shared daypart allocation used by Schedule; do not let `OpenShiftSnapshot` / `ShiftRecord` carry a competing projected plan target
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
- Learn benchmark-context and coaching-summary cleanup landed through
  `7.55l.8` + `7.55k`; active tracker truth no longer treats named Learn
  surface seams as open
- fixed `14 shifts` debt spans runtime, replay seeding, tests, UI copy, and active integration docs
- `7.55o` extraction is complete through SQLite bootstrap breakup; later naming/copy/refactor audits should be scoped separately rather than reopened as extraction acceptance work
- use `docs/internal/status_ledger_post_7_55p_deep_check.md` as the reference sheet for:
  - which older user asks are already done vs partial vs still open
  - post-`7.55o` naming / copy / refactor audit ideas after the landed shell pass
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
- `docs/phases/7_56/phase_7_56b_benchmark_selection_summary_replay_stability.md`
- `docs/phases/7_56/phase_7_56c0_full_week_projection_authority_alignment.md`
- `docs/phases/7_56/phase_7_56c_data_alignment_audit_plan_benchmark_coverage.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`
- `docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md`
- `docs/phases/phase_9_75/phase_9_75_staff_daily_companion_plan.md`
- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md`
- `docs/phases/operations_el_podio/operations_el_podio_stub.md`
- `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
- `docs/phases/phase_10b/phase_10b_full_offline_sync_plan.md`
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`
- `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md`

## Notes

- Detailed slice-by-slice history was archived to `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`.
- Completed `7.55l` and `7.55m` docs now live under `docs/archive/phases/7_55l/` and `docs/archive/phases/7_55m/`.
- Completed `7.55i`, `7.55k`, `7.55n`, `7.55p`, and the completed `7.55j.1` / `7.55j.2` / `7.55j.gate` docs now live under `docs/archive/phases/`.
- Active architecture authority docs now live under `docs/contracts/`.
