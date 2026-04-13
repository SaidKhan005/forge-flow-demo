# Forge & Flow Project Tracker

Updated: 2026-04-12
Owner: You
Execution model: We think, Claude codes
Active authority:
- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md`
- explicitly referenced active phase docs
Archive:
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Product Split

- This Week = diagnose what lever matters first right now
- History = teach what leaks repeat over time
- Learn = summarize recurring leaks, benchmarks, and repeatable wins

## Current Data Truth Clarification

- The app is not connected to a live POS, labor, or reservation vendor yet.
- Current visible app data still comes from fixture, replay, or demo-seeded transport.
- That input now flows through the same internal app-side path that live vendor data is expected to use:
  - canonical models
  - SQLite persistence
  - repositories, providers, and notifiers
  - UI
- Phase 8 / 8R should replace transport with live vendor feeds, not create a second UI-facing truth path.
- Active planning rule:
  - standards lock on a 60-day `TargetCycle`
  - demand can keep rolling from level 1 baseline + fixed 3-week recent trend
  - the operating week should auto-generate one locked `WeeklyPlanSnapshot`
  - no intended manager-facing UX change in Benchmark, Schedule, History, or Learn

## Active Focus

- Current phase: Phase 7.55 alignment remains active through downstream daypart semantics hardening, with verified `7.55a` through `7.55h`, `7.55i` intentionally stopped after verified `7.55i.3a`, `7.55l` complete, `7.55m` complete, and `7.55k` now active as the next semantics lane.
- Current prompt: `7.55k.3` - daypart pattern summary model
- Current goal: replace lightweight closed-shift pattern records with a richer evidence-carrying daypart summary layer that downstream History and Learn upgrades can build on.
- Current live-integration scope: one restaurant or location, not multi-location org management.
- Naming guardrail: keep internal `Baseline` / `Schedule` code and model names unchanged during this alignment pass, even though user-facing copy now says `Benchmark`, `Plan`, and `Weekly Operating Plan`.

### Phase Status

- Phase 7.5: complete
- Phase 7.51: complete on the app side
- Phase 7.52: complete
- Phase 7.53: complete
- Phase 7.54: complete
- Phase 7.55: active alignment lane
- Phase 7.56: complete on the app-side demo path
- Phase 8: blocked on vendor selection only
- Phase 8R: planned official reservation connector lane
- Phase 9: planning contract locked in `docs/phases/phase_9/phase_9_auth_plan.md`

### Active Planning Docs

- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`
- `docs/phase_7_55i_canonical_demand_schedule_plan_authority.md`
- `docs/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/phase_7_55i_plain_english_explainer.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md`
- `docs/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- `docs/archive/phases/7_55m/phase_7_55m_runtime_truth_surface_cleanup_plan.md`
- `docs/archive/phases/7_55l/phase_7_55l_1_target_cycle_contract.md`
- `docs/archive/phases/7_55l/phase_7_55l_2a_target_cycle_persistence_autorefresh.md`
- `docs/archive/phases/7_55l/phase_7_55l_3a_target_cycle_override_write_path.md`
- `docs/archive/phases/7_55l/phase_7_55l_4a_active_target_profile_projection.md`
- `docs/archive/phases/7_55l/phase_7_55l_5a_rolling_demand_context_v2.md`
- `docs/archive/phases/7_55l/phase_7_55l_5d_weekly_day_allocation_smoothing.md`
- `docs/archive/phases/7_55l/phase_7_55l_5f_demand_audit_truth_cleanup.md`
- `docs/archive/phases/7_55l/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- `docs/archive/phases/7_55l/phase_7_55l_6b_weekly_plan_snapshot_persistence_autolock.md`
- `docs/archive/phases/7_55l/phase_7_55l_7a_first_consumer_migration_slice.md`
- `docs/archive/phases/7_55l/phase_7_55l_8a_learn_source_target_migration.md`
- `docs/archive/phases/7_55l/phase_7_55l_8b_learn_selection_analytics_migration.md`
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md`
- `docs/phases/7_56/phase_7_56_reservation_book_signal_plan.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`

### Archive Pointers

- Prompt history and older decision log:
  - `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- Full pre-hygiene data-alignment tracker snapshot:
  - `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`
- Archived completed phase docs:
  - `docs/archive/phases/phase_7_55d_whole_day_shift_schedule_plan.md`
  - `docs/archive/phases/phase_7_55e_distribution_architecture_findings.md`
  - `docs/archive/phases/phase_7_55f_manager_override_calendar_plan.md`
  - `docs/archive/phases/phase_7_55g_schedule_sales_card_baseline_cleanup.md`
  - `docs/archive/phases/phase_7_55h_blended_wage_decimal_consistency.md`
- Archived reference/background material:
  - `docs/archive/reference/REFACTOR_AND_DECOUPLING.MD`

## Phase Roadmap

- [x] Phase 1 - Foundation
- [x] Phase 2 - History From Real Facts
- [x] Phase 3 - Close Shift / Ingest Path
- [x] Phase 4 - Target Consistency + OPZ
- [x] Phase 5 - Baseline Manager From History
- [x] Phase 6 - Variance Visual Overhaul
- [x] Phase 7 - Learn Layer
- [x] Phase 7.5 - Data Alignment + Decoupling + Fixture Replay
- [x] Phase 7.51 - Phase 8 App-Side Gate Closeout
- [x] Phase 7.52 - Cleanup + Product Identity + Private Barrio Build
- [x] Phase 7.53 - Native Dual-Build Hardening
- [x] Phase 7.54 - Runtime + Footprint Optimization
- [ ] Phase 7.55 - Release Stabilization
- [x] Phase 7.56 - Reservation Book Signal Demo
- [ ] Phase 8 - Live POS + Labor Adapters
- [ ] Phase 8R - Official Reservation Connector
- [ ] Phase 9 - Restaurant Auth + Login
- [ ] Phase 9.5 - El Podio Learning Identity
- [ ] Phase 10 - Shared Multi-Device Sync
- [ ] Phase 10.5 - Shift Daypart-Aware Service Period View + Primary Driver
- [ ] Phase 11 - Corporate / Franchise Layer

## Immediate Watchlist

- Phase 8 is blocked on vendor selection only.
- `7.55i` is intentionally stopped after `7.55i.3a`:
  - keep the verified delivered pieces: canonical demand context, shared SchedulePlan authority, and wage-source authority
  - do not revive `7.55i.4` as an active prompt
- `7.55j` inventory/gate work is complete for now:
  - `7.55j.1` codebase feature inventory - complete
  - `7.55j.2` required capability matrix - complete
  - `7.55j.gate` integration readiness pressure test - complete, verdict: not simple-swap ready yet
- `7.55j.3` / `7.55j.4` are parked temporarily while runtime truth stabilization lands:
  - `7.55j.3` vendor endpoint checklist template - parked behind `7.55m`
  - `7.55j.4` gap report - parked behind `7.55m` and `7.55k`
- `7.55l` is now complete as the implementation lane between integration inventory and downstream semantics:
  - complete: `7.55l.0` planning cleanup / handoff
  - complete: `7.55l.1` / `7.55l.1a` `TargetCycle` contract + policy cleanup
  - complete: `7.55l.2a` / `7.55l.2b` / `7.55l.2c` `TargetCycle` persistence + auto-refresh spine + correctness cleanup
  - complete: `7.55l.3a` / `7.55l.3b` override/replacement write path + provenance/history cleanup
  - complete: `7.55l.4a` `ActiveTargetProfile` projection from `TargetCycle`
  - complete: `7.55l.5a` / `7.55l.5b` / `7.55l.5c` rolling `DemandForecastContext` v2 + zero-demand truth propagation
  - complete: `7.55l.5d` / `7.55l.5e` weekly day-allocation smoothing + anchor-alignment cleanup
  - complete: `7.55l.5f` / `7.55l.5g` demand-audit truth cleanup + empty-state label alignment
  - complete: `7.55l.6a` / `7.55l.6a1` `WeeklyPlanSnapshot` contract + week-key invariant cleanup
  - complete: `7.55l.6b` / `7.55l.6b1` / `7.55l.6b2` / `7.55l.6b3` `WeeklyPlanSnapshot` persistence + auto-lock spine + same-week replay integrity cleanup
  - complete: `7.55l.7a` first consumer migration slice (`WeeklyPlanSnapshot -> SchedulePlan` locked read seam plus Shift dashboard / audit adoption)
  - complete: `7.55l.7b` / `7.55l.7b1` current-week Variance / WeekData migration onto locked weekly truth + locked WTD forecast completion
  - complete: `7.55l.7c` / `7.55l.7c1` current-week Full Week / `CurrentWeekState` migration onto locked weekly truth + current-week-only scoping cleanup
  - complete: `7.55l.7d` / `7.55l.7d1` historical week provenance migration for History / Week Detail + cycle-era provenance label completion
  - complete: `7.55l.8a` / `7.55l.8a1` Learn source/target migration off production `BaselineData` + fallback-tightening cleanup
  - complete: `7.55l.8b` / `7.55l.8b1` Learn selection-analytics migration off production `BaselineData` + default-benchmark semantics fix
  - complete: `7.55l.8c` / `7.55l.8c1` persisted benchmark-selection summary for Learn default benchmark truth + missing-summary recovery tightening
  - complete: `7.55l.8d` / `7.55l.8d1` Learn active-profile-without-cycle recovery cleanup + post-recovery canonical-profile enforcement
  - complete: `7.55l.8` Learn bridge cleanup + closeout
- `7.55m` is the new runtime-truth + surface-cleanup lane:
  - complete: `7.55m.0` planning / handoff
  - complete: `7.55m.1` / `7.55m.1a` date/business-date authority seam + day-order source unification
  - complete: `7.55m.2` / `7.55m.2a` mock replay drift contract + historical-truth clarification
  - complete: `7.55m.3` Shift time truthfulness cleanup
  - complete: `7.55m.4` / `7.55m.4a` driver parity audit / cleanup + placeholder-driver honesty tightening
  - complete: `7.55m.5` / `7.55m.5a` Benchmark OPZ truth audit / cleanup + source-set honesty tightening
  - complete: `7.55m.6` / `7.55m.6a` Plan / Benchmark / Settings surface cleanup + regression/copy alignment tightening
  - complete: `7.55m.7` / `7.55m.7a` closeout + handoff into `7.55k` / `10.5` + sequencing-note cleanup
- `7.55k` is now the active downstream daypart, History, Learn, and Variance semantics lane:
  - complete: `7.55k.1` / `7.55k.1a` / `7.55k.1b` daypart scope audit + audit-doc truth cleanup
  - complete: `7.55k.2` / `7.55k.2a` / `7.55k.2b` service-period decoupling plan + plan-doc truth cleanup + daypart-summary handoff-shape cleanup
  - current: `7.55k.3` daypart pattern summary model
  - then: `7.55k.4` through `7.55k.8` per the phase plan
- after `7.55k`:
  - resume `7.55j.3`, then `7.55j.4`
- `7.55j`, `7.55l`, and `7.55k` should all follow the active `TargetCycle + WeeklyPlanSnapshot` rules:
  - 60-day benchmark snapshot calibrates the next cycle
  - `TargetCycle` locks standards for 60 days
  - demand can roll from level 1 baseline + fixed 3-week recent trend
  - `WeeklyPlanSnapshot` auto-generates and locks the week for Variance and History comparison
- `7.55j.gate` is now complete:
  - verdict remains "not passed yet" for simple-swap readiness
  - yellow blockers remain around replay/demo transport and bridge-era dependencies
  - the red cycle/week runtime architecture blockers were implemented through `7.55l`
- Forecasting guardrail for the new architecture:
  - keep the demand stack explicit
  - no manager forecast adjustments in the first architecture cut
  - do not let forecast-side changes mutate standards
  - do not let weekly snapshot generation become ambiguous
  - smooth day allocation from 60-day baseline share + fixed 3-week trend so
    the weekly spread stays stable
- UX guardrail for the new architecture:
  - no new manager workflow
  - no draft/publish state in the UI
  - no intended UX change to Benchmark, Schedule, History, or Learn
  - use passive notifications/visibility for important automation only
- `7.55m` stabilized runtime truth first:
  - shared date/business-date authority (now landed through `7.55m.1` / `7.55m.1a`)
  - mock replay drift boundaries (now landed through `7.55m.2` / `7.55m.2a`)
  - truthful Shift time behavior (now landed through `7.55m.3`)
  - driver parity audit (now landed through `7.55m.4` / `7.55m.4a`)
  - OPZ truth audit (now landed through `7.55m.5` / `7.55m.5a`)
  - immediate Plan / Benchmark / Settings surface cleanup (now landed through `7.55m.6` / `7.55m.6a`)
- `7.55k` should now harden downstream daypart semantics and later Variance/History/Learn evidence work using app-owned service-period definitions plus timestamp bucketing rather than assuming vendor-native dayparts.
- `7.56` is app-side only and must not be described as live OpenTable/reservation integration.
- Barrio auth-dependent gaps, role enforcement, and El Podio identity work remain under `docs/phases/phase_9/phase_9_auth_plan.md`.
- Future restaurant-count scale should be treated as a data/query problem, not as a reason for tenant-specific source forks.

## Working Prompt Tracker

- Current: `7.55k.3` - daypart pattern summary model
- Complete:
  - `7.55m.0` - runtime truth + surface cleanup planning / handoff
  - `7.55m.1` / `7.55m.1a` - date/business-date authority seam + day-order source unification
  - `7.55m.2` / `7.55m.2a` - mock replay drift contract + historical-truth clarification
  - `7.55m.3` - Shift time truthfulness cleanup
  - `7.55m.4` / `7.55m.4a` - driver parity audit / cleanup + placeholder-driver honesty tightening
  - `7.55m.5` / `7.55m.5a` - Benchmark OPZ truth audit / cleanup + source-set honesty tightening
  - `7.55m.6` / `7.55m.6a` - Plan / Benchmark / Settings surface cleanup + regression/copy alignment tightening
  - `7.55m.7` / `7.55m.7a` - runtime-truth cleanup closeout + handoff into `7.55k` / `10.5` + sequencing-note cleanup
  - `7.55k.1` / `7.55k.1a` / `7.55k.1b` - daypart scope audit + audit-doc truth cleanup
  - `7.55k.2` / `7.55k.2a` / `7.55k.2b` - service-period decoupling plan + plan-doc truth cleanup + daypart-summary handoff-shape cleanup
  - `7.55l.0` - planning cleanup / handoff
  - `7.55l.1` / `7.55l.1a` - TargetCycle contract + policy cleanup
  - `7.55l.2a` / `7.55l.2b` / `7.55l.2c` - TargetCycle persistence + auto-refresh spine + correctness cleanup
  - `7.55l.3a` / `7.55l.3b` - TargetCycle override write path + provenance/history cleanup
  - `7.55l.4a` - ActiveTargetProfile as TargetCycle projection
  - `7.55l.5a` / `7.55l.5b` / `7.55l.5c` - rolling DemandForecastContext v2 + zero-demand truth propagation
  - `7.55l.5d` / `7.55l.5e` - weekly day-allocation smoothing + anchor alignment
  - `7.55l.5f` / `7.55l.5g` - demand audit truth cleanup + label alignment
  - `7.55l.6a` / `7.55l.6a1` - WeeklyPlanSnapshot contract + week-key invariant cleanup
  - `7.55l.6b` / `7.55l.6b1` / `7.55l.6b2` / `7.55l.6b3` - WeeklyPlanSnapshot persistence + auto-lock spine + same-week replay integrity cleanup
  - `7.55l.7a` - first consumer migration slice (locked weekly plan read seam + Shift dashboard / audit adoption)
  - `7.55l.7b` / `7.55l.7b1` - current-week Variance / WeekData migration onto locked weekly truth + locked WTD forecast completion
  - `7.55l.7c` / `7.55l.7c1` - current-week Full Week / CurrentWeekState migration onto locked weekly truth + current-week-only scoping cleanup
  - `7.55l.7d` / `7.55l.7d1` - historical week provenance migration for History / Week Detail + cycle-era provenance label completion
  - `7.55l.8a` / `7.55l.8a1` - Learn source/target migration off production `BaselineData` + fallback-tightening cleanup
  - `7.55l.8b` / `7.55l.8b1` - Learn selection-analytics migration off production `BaselineData` + default-benchmark semantics fix
  - `7.55l.8c` / `7.55l.8c1` - persisted benchmark-selection summary for Learn default benchmark truth + missing-summary recovery tightening
  - `7.55l.8d` / `7.55l.8d1` - Learn active-profile-without-cycle recovery cleanup + post-recovery canonical-profile enforcement
  - `7.55l.8` - Learn bridge cleanup + closeout
- Then:
  - `7.55k.3` - daypart pattern summary model
  - `7.55k.4` - Variance Full Week projection semantics
  - `7.55k.5` - History benchmark dayparts upgrade
  - `7.55k.6` - Learn repeatable wins upgrade
  - `7.55k.7` - interim visibility rules
  - `7.55k.8` - integration implications
  - `7.55j.3` - vendor endpoint checklist template
  - `7.55j.4` - gap report
