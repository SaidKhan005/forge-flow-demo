# Data Alignment Tracker

Updated: 2026-04-12
Owner: You
Purpose: Keep the app aligned for live POS, labor, and later official reservation integrations before Phase 8 / Phase 8R begins.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Desired Separation

This is the architecture the app is moving toward:

Vendor APIs / Fixture Replays
-> Adapter DTOs
-> Canonical source facts
-> Domain services / use cases
-> Repositories
-> SQLite persistence
-> In-memory app state
-> UI

In plain terms:

- API adapters should only pull the relevant POS, labor, and reservation data.
- The app should reshape that data into its own canonical format immediately.
- SQLite should hold the restaurant's rolling 60-day operational truth plus current-week and target-profile state.
- Providers and notifiers should expose repository-backed app state, not vendor payloads or screen constants.
- UI should render that app state without needing to know where the data came from.

Active planning rule:

- 60-day benchmark snapshot is calibration evidence
- `TargetCycle` locks standards for 60 days
- `DemandForecastContext` can roll from level 1 baseline + fixed 3-week recent trend
- `WeeklyPlanSnapshot` auto-generates and locks the week for comparison surfaces
- Forecasting discipline guardrail:
  - keep the demand stack explicit
  - no manager forecast adjustments in the first architecture cut
  - do not let forecast-side changes mutate standards
  - do not let weekly snapshot generation become ambiguous
  - smooth day allocation from 60-day baseline share + fixed 3-week trend so
    the weekly spread stays stable
- UX guardrail:
  - no new manager workflow
  - no draft/publish language in the UI
  - no intended UX change to Benchmark, Schedule, History, or Learn
  - use passive notifications/visibility for important automation only

## Live Data Clarification

- The current repo is not connected to a live POS, labor, forecast, or reservation vendor yet.
- Current displayed data is still fixture, replay, or demo-backed at the transport layer.
- Internally, that data now flows through the same aligned path that live vendor data should use:
  - canonical source facts
  - SQLite persistence
  - app state and read models
  - UI rendering
- Phase 8 should replace fixture or replay transport with live vendor transport.
- Phase 8 should not replace the internal app-side data flow.

## Current Alignment Focus

- Phase `7.55i` is intentionally stopped after `7.55i.3a`.
- Verified so far:
  - `7.55i.1` / `7.55i.1a` added canonical repository-backed Demand Forecast Context and moved runtime demand reads off direct `BaselineData`
  - `7.55i.2` / `7.55i.2a` centralized shared SchedulePlan consumption so Schedule, Shift, Audit, and Manager Override preview consume one resolved plan authority
  - `7.55i.3` / `7.55i.3a` finalized wage-source authority with the integration-first path plus fallback generator
- Focused capability checkpoint complete:
  - `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
  - confirmed preferred architecture: app-owned service-period definitions + timestamp bucketing, not vendor-native dayparts
  - confirmed wage authority should be integration-first, with a restaurant-scoped fallback wage generator when official labor wage truth is incomplete
- New planning rule locked:
  - `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
  - target standards should not drift daily
  - rolling forecast demand stays separate from standards
  - Variance and History should compare against a locked weekly plan, not a forecast that kept moving after the week started
- Current next steps:
  - `7.55j.1` and `7.55j.2` are complete:
    - codebase feature inventory complete
    - required capability matrix complete
  - `7.55j.gate` is complete:
    - honest readiness answer recorded
    - simple-swap verdict still not passed
  - `7.55l` is now complete and implements the missing runtime architecture:
    - complete: `7.55l.1` / `7.55l.1a` `TargetCycle` contract + policy cleanup
    - complete: `7.55l.2a` / `7.55l.2b` / `7.55l.2c` persistence + auto-refresh spine + correctness cleanup
    - complete: `7.55l.3a` / `7.55l.3b` override/replacement write path + provenance/history cleanup
    - complete: `7.55l.4a` `ActiveTargetProfile` projection from `TargetCycle`
    - complete: `7.55l.5a` / `7.55l.5b` / `7.55l.5c` rolling `DemandForecastContext` v2 + zero-demand truth propagation
    - complete: `7.55l.5d` / `7.55l.5e` weekly day-allocation smoothing + anchor-alignment cleanup
    - complete: `7.55l.5f` / `7.55l.5g` demand-audit truth cleanup + label alignment
    - complete: `7.55l.6a` / `7.55l.6a1` `WeeklyPlanSnapshot` contract + week-key invariant cleanup
    - complete: `7.55l.6b` / `7.55l.6b1` / `7.55l.6b2` / `7.55l.6b3` persistence + auto-lock spine + same-week replay integrity cleanup
    - complete: `7.55l.7a` first consumer migration slice (locked-week read seam + Shift dashboard / audit adoption)
    - complete: `7.55l.7b` / `7.55l.7b1` current-week Variance / WeekData migration onto locked weekly truth + locked WTD forecast completion
    - complete: `7.55l.7c` / `7.55l.7c1` current-week Full Week / `CurrentWeekState` migration onto locked weekly truth + current-week-only scoping cleanup
    - complete: `7.55l.7d` / `7.55l.7d1` historical week provenance migration for History / Week Detail + cycle-era provenance label completion
    - complete: `7.55l.8a` / `7.55l.8a1` Learn source/target migration off production `BaselineData` + fallback-tightening cleanup
    - complete: `7.55l.8b` / `7.55l.8b1` Learn selection-analytics migration off production `BaselineData` + default-benchmark semantics fix
    - complete: `7.55l.8c` / `7.55l.8c1` persisted benchmark-selection summary for Learn default benchmark truth + missing-summary recovery tightening
    - complete: `7.55l.8d` / `7.55l.8d1` Learn active-profile-without-cycle recovery cleanup + post-recovery canonical-profile enforcement
    - complete: `7.55l.8` Learn bridge cleanup + closeout
  - next: `7.55m.0` runtime truth + surface cleanup planning / handoff
  - then: `7.55m.1` shared date/business-date authority seam
  - then: `7.55m.2` mock replay drift contract
  - then: `7.55m.3` Shift time truthfulness cleanup
  - then: `7.55m.4` driver parity audit / cleanup
  - then: `7.55m.5` Benchmark OPZ truth audit / cleanup
  - then: `7.55m.6` Plan / Benchmark / Settings surface cleanup
  - then: `7.55m.7` closeout + handoff into `7.55k` / `10.5`
  - then: `7.55k` downstream daypart, History, Learn, and Variance semantics hardening
  - then resume: `7.55j.3` vendor endpoint checklist template and `7.55j.4` gap report

## Current Runtime-Truth Cleanup Scope

`7.55m` owns the current-product cleanup that should land before deeper
daypart semantics:

- shared date / business-date authority
- mock replay drift boundaries
- truthful Shift clock / time behavior
- driver parity checks across Shift and Variance
- Benchmark OPZ truth audit
- Plan / Benchmark / Settings surface cleanup

`7.55k` remains the downstream semantics lane for:

- Full Week row-scope semantics
- History / Learn daypart evidence honesty
- longer-term `restaurantId + businessDate + daypart` hardening

## Current Source Ownership Guardrails

- POS owns:
  - business date when POS is the sales authority
  - sales
  - checks or tickets
  - covers when exposed reliably
  - close/finalization semantics where available
- Labor owns:
  - schedules
  - time punches / timecards
  - actual worked hours
  - job or role assignments
  - labor dollars or wage truth when exposed
- Reservation platform owns:
  - reservation party size
  - reservation time
  - reservation status and status timestamps
- App owns:
  - rolling 60-day benchmark snapshot
  - current `TargetCycle`
  - cycle-projected active target profile (with transitional bridge writes still coexisting elsewhere)
  - rolling forecast demand context
  - weekly demand/day allocation logic
  - weekly plan snapshot
  - forecast sales derivation as covers * target PPA
  - SchedulePlan construction from Demand Forecast Context + Active Target Profile + distribution weights
  - daypart mapping rules
  - reservation-book aggregation
  - whole-day Shift plan-vs-actual behavior until Phase 10.5

## Active Planning Docs

- `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`
- `docs/phase_7_55i_canonical_demand_schedule_plan_authority.md`
- `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phase_7_55j_integration_feature_endpoint_inventory.md`
- `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- `docs/phase_7_55m_runtime_truth_surface_cleanup_plan.md`
- `docs/phase_7_55l_1_target_cycle_contract.md`
- `docs/phase_7_55l_2a_target_cycle_persistence_autorefresh.md`
- `docs/phase_7_55l_3a_target_cycle_override_write_path.md`
- `docs/phase_7_55l_4a_active_target_profile_projection.md`
- `docs/phase_7_55l_5a_rolling_demand_context_v2.md`
- `docs/phase_7_55l_5d_weekly_day_allocation_smoothing.md`
- `docs/phase_7_55l_5f_demand_audit_truth_cleanup.md`
- `docs/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- `docs/phase_7_55l_6b_weekly_plan_snapshot_persistence_autolock.md`
- `docs/phase_7_55l_7a_first_consumer_migration_slice.md`
- `docs/phase_7_55k_daypart_variance_history_learn_plan.md`
- `docs/phase_7_56_reservation_book_signal_plan.md`
- `docs/phase_9_auth_plan.md`

## Archive And Reference

- Full pre-hygiene tracker snapshot:
  - `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
- Project prompt history / tracker archive:
  - `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- Archived completed phase docs:
  - `docs/archive/phases/phase_7_55d_whole_day_shift_schedule_plan.md`
  - `docs/archive/phases/phase_7_55e_distribution_architecture_findings.md`
  - `docs/archive/phases/phase_7_55f_manager_override_calendar_plan.md`
  - `docs/archive/phases/phase_7_55g_schedule_sales_card_baseline_cleanup.md`
  - `docs/archive/phases/phase_7_55h_blended_wage_decimal_consistency.md`
- Archived background reference:
  - `docs/archive/reference/REFACTOR_AND_DECOUPLING.MD`

## Working Reminder

- Keep top-level docs focused on active authority.
- Treat `docs/archive/**` as historical/reference material unless a prompt explicitly points there.
- Preserve live-integration realism: future vendor work should replace transport, not create a second UI-facing truth path.
- Treat `7.55j.gate` as complete and use its blocker list as the handoff into `7.55l`.
