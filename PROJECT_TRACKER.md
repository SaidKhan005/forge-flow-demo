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
- `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Product Split

- This Week = diagnose what lever matters first right now
- History = teach what leaks repeat over time
- Learn = summarize recurring leaks, benchmarks, and repeatable wins

## Active Focus

- Current phase: Phase 7.55 restaurant timing + service-period runtime foundation
- Current prompt: `7.55n.1` - restaurant timing config persistence seam
- Current goal: persist the minimum restaurant-owned timing settings so business-date, week-start, service-period, and shift-close runtime rules can read one app-owned config seam
- Current live-integration scope: one restaurant/location, not multi-location org management
- Naming guardrail: keep internal `Baseline` / `Schedule` names unchanged during this alignment pass

## Current Lane Status

- `7.55l` complete:
  - delivered `TargetCycle` + `WeeklyPlanSnapshot` runtime architecture
- `7.55m` complete:
  - delivered runtime-truth cleanup
  - closeout: `docs/archive/phases/7_55m/phase_7_55m_7_runtime_truth_closeout_handoff.md`
- `7.55k.1` complete:
  - daypart scope audit
- `7.55k.2` complete:
  - service-period decoupling plan
- `7.55k.3` complete:
  - daypart pattern summary model
  - `7.55k.3a` evidence-contract cleanup landed:
    - unknown lever IDs excluded from benchmark/leak evidence
    - exemplar fallback IDs made deterministic
- `7.55k.4` complete:
  - Variance Full Week projection semantics landed
  - `7.55k.4a` honesty cleanup landed:
    - mixed-status day rows now visibly indicate non-final composition
    - open-row detail header now reads as plan context instead of current actuals
- `7.55k.5` complete:
  - History benchmark dayparts upgraded to evidence-backed closed-truth summaries
  - `7.55k.5a` honesty cleanup landed:
    - compact History rows now show favorable wins against total sample depth
    - ranking ties now resolve explicitly by canonical day / service-period order
- `7.55k.6` complete:
  - Learn Repeatable Wins upgraded to evidence-backed closed-truth summaries
  - `7.55k.6a` honesty cleanup landed:
    - per-row lever chips now distinguish rows with different dominant win levers
    - coaching copy is explicitly scoped to the top-ranked win
- `7.55k.7` complete:
  - interim visibility rules landed
  - `7.55k.7a` honesty cleanup landed:
    - Repeatable Wins empty state no longer falls back to legacy benchmark-daypart labels
    - strong History benchmark evidence is now prioritized ahead of early signals when slots are limited
- `7.55k.8` complete:
  - integration implications documented and fed back into `7.55j`
  - `7.55k.8a` truth cleanup landed:
    - active `7.55j` docs no longer describe `TargetCycle` / `WeeklyPlanSnapshot` as hypothetical future models
    - gate sequencing now treats `7.55k` as landed input into `7.55j.3` / `7.55j.4`
- Current:
  - `7.55n.1` restaurant timing config persistence seam
- Next:
  - `7.55n.2` through `7.55n.6` timing/runtime foundation follow-through
  - `7.55p.1` Shift driver trust audit
  - `7.55p.2` Variance WTD / Full Week alignment
  - `7.55p.3` Dollar Impact accumulation model
  - `7.55p.4` refresh / replay integrity / notifications
  - `7.55p.5` Benchmark OPZ and graph honesty audit
  - `7.55o.1` shared widget extraction / variance shell slimming
  - then `7.55o.2` through `7.55o.6`
  - then resume `7.55j.3` and `7.55j.4`
- Queued future lane:
  - `7.55n` restaurant timing + service-period runtime foundation
    - owns the implementation gaps named in the time boundary contract
    - lands after `7.55k`, before `10.5`
  - `7.55p` post-`7.55n` product/alignment lane
    - owns driver trust, WTD / Full Week alignment, Dollar Impact, refresh / notification trust, and OPZ graph honesty
    - lands after `7.55n`, before `7.55o`
  - `7.55o` file extraction / engineering hygiene
    - implements the queued extraction work captured in:
      - `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`
    - lands after `7.55p`, before resuming `7.55j.3` / `7.55j.4`

## Global Watchlist

- Phase 8 is still blocked on vendor selection only
- `7.55j.gate` is complete; simple-swap readiness is still not passed
- `7.55i` stays stopped after `7.55i.3a`; do not revive `7.55i.4`
- `7.56` is app-side only and must not be described as live reservation integration
- `10.5` still owns live Shift service-period behavior, live time-into-service, and daypart-live driver teaching

## Active Guardrails

- standards lock on a 60-day `TargetCycle`
- demand can roll from level 1 baseline + fixed 3-week recent trend
- the operating week should auto-generate one locked `WeeklyPlanSnapshot`
- no new manager workflow
- no draft/publish state in the UI
- no intended manager-facing UX change in Benchmark, Schedule, History, or Learn
- widgets should not own source-truth decisions
- widgets should not own service-period bucketing rules
- Full Week projection semantics should come from a read service / read model, not mixed screen helpers
- we are not fully integration-ready yet; do not describe SQL-backed internal simulation as simple-swap readiness
- Learn is partially migrated today:
  - Repeatable Wins is evidence-backed
  - Benchmark Set / Recurring Leak / Coach Next Week still use compatibility seams
- fixed `14 shifts` debt is broader than one runtime condition:
  - runtime
  - replay seeding
  - tests
  - UI copy
  - active integration docs
- Baseline Manager is not extraction-only:
  - its first future touch must also fix wage-authority alignment in the preview path

## Active Planning Docs

- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md`
- `docs/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md`
- `docs/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md`
- `docs/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md`
- `docs/phases/7_55k/phase_7_55k_4_variance_full_week_projection_semantics.md`
- `docs/phases/7_55n/phase_7_55n_restaurant_timing_service_period_runtime_foundation.md`
- `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`

## Working Prompt Queue

- Current:
  - `7.55n.1` - restaurant timing config persistence seam
- Then:
  - `7.55n.2` - BusinessDateResolver
  - `7.55n.3` - ServicePeriodDefinitionResolver
  - `7.55n.4` - week-start wiring
  - `7.55n.5` - service-period close vs shift finalization
  - `7.55n.6` - metadata timestamp normalization
  - `7.55p.1` - Shift driver trust audit
  - `7.55p.2` - Variance WTD / Full Week alignment
  - `7.55p.3` - Dollar Impact accumulation model
  - `7.55p.4` - refresh / replay integrity / notifications
  - `7.55p.5` - Benchmark OPZ and graph honesty audit
  - `7.55o.1` - shared widget extraction / variance shell slimming
  - `7.55o.2` - Variance shell split
  - `7.55o.3` - Schedule planning surface separation
  - `7.55o.4` - Settings surface split
  - `7.55o.5` - Baseline Manager decomposition plus wage-authority alignment
  - `7.55o.6` - SQLite bootstrap breakup only if still justified
  - `7.55j.3` - vendor endpoint checklist template
  - `7.55j.4` - gap report

## Notes

- Detailed slice-by-slice history was archived to `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`.
- Completed `7.55l` and `7.55m` phase docs now live under `docs/archive/phases/7_55l/` and `docs/archive/phases/7_55m/`.
- Active architecture authority docs now live under `docs/contracts/`.
- Use `docs/archive/**` only when a prompt explicitly needs historical detail.
