# Forge & Flow Project Tracker

Updated: 2026-04-11
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

- Current phase: Phase 7.55 release stabilization / alignment planning remains active, with verified `7.55a` through `7.55h` and `7.55i` intentionally stopped after verified `7.55i.3a`.
- Current prompt: `7.55j.1` - codebase feature inventory
- Current goal: map official POS, labor, and reservation capabilities cleanly before more downstream Variance, History, Learn, and daypart semantics work.
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
- Phase 9: planning contract locked in `docs/phase_9_auth_plan.md`

### Active Planning Docs

- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`
- `docs/phase_7_55i_canonical_demand_schedule_plan_authority.md`
- `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/phase_7_55i_plain_english_explainer.md`
- `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phase_7_55j_integration_feature_endpoint_inventory.md`
- `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- `docs/phase_7_55k_daypart_variance_history_learn_plan.md`
- `docs/phase_7_56_reservation_book_signal_plan.md`
- `docs/phase_9_auth_plan.md`

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
- `7.55j` remains next and now breaks into:
  - `7.55j.1` codebase feature inventory
  - `7.55j.2` required capability matrix
  - `7.55j.gate` integration readiness pressure test
- `7.55l` is the missing implementation lane between integration inventory and downstream semantics:
  - `TargetCycle`
  - rolling `DemandForecastContext`
  - weekly demand/day allocation logic
  - `WeeklyPlanSnapshot`
  - consumer migration
  - Learn bridge cleanup
- `7.55j`, `7.55l`, and `7.55k` should all follow the active `TargetCycle + WeeklyPlanSnapshot` rules:
  - 60-day benchmark snapshot calibrates the next cycle
  - `TargetCycle` locks standards for 60 days
  - demand can roll from level 1 baseline + fixed 3-week recent trend
  - `WeeklyPlanSnapshot` auto-generates and locks the week for Variance and History comparison
- `7.55j.gate` is expected to record a "not passed yet" readiness answer until both bridge/demo blockers and cycle/week runtime architecture gaps are closed.
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
- `7.55k` should harden downstream daypart semantics and later Variance/History/Learn evidence work using app-owned service-period definitions plus timestamp bucketing rather than assuming vendor-native dayparts.
- `7.56` is app-side only and must not be described as live OpenTable/reservation integration.
- Barrio auth-dependent gaps, role enforcement, and El Podio identity work remain under `docs/phase_9_auth_plan.md`.
- Shift clock is still static; live ticking remains Phase 8 work.
- Future restaurant-count scale should be treated as a data/query problem, not as a reason for tenant-specific source forks.

## Working Prompt Tracker

- Current: `7.55j.1` - codebase feature inventory
- Then:
  - `7.55j.2` - required capability matrix
  - `7.55j.gate` - integration readiness pressure test
  - `7.55l.0` - planning cleanup / handoff
  - `7.55l.1` - TargetCycle contract
  - `7.55l.2` - TargetCycle persistence + auto-refresh rules
  - `7.55l.3` - weekly demand/day allocation rules
  - `7.55l.4` - ActiveTargetProfile as TargetCycle projection
  - `7.55l.5` - rolling DemandForecastContext v2
  - `7.55l.6` - WeeklyPlanSnapshot contract + auto-lock persistence
  - `7.55l.7` - consumer migration
  - `7.55l.8` - Learn migration + bridge retirement
  - `7.55j.3` - vendor endpoint checklist template
  - `7.55j.4` - gap report
  - `7.55k` - downstream daypart semantics and evidence-backed coaching
