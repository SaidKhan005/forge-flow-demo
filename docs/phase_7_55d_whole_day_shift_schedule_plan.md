# Phase 7.55d - Whole-Day Shift / Schedule Plan Alignment

Updated: 2026-04-10
Owner: Codex planning / tracker truth
Status: Closed through implementation report 7.55d.3c

## Closeout

Phase 7.55d is closed.

Implemented outcomes:

- `7.55d.1` added the SchedulePlan/ScheduleDayPlan planning contract and routed Schedule weekly/day planning math through the resolver.
- Follow-ups to `7.55d.1` made unavailable demand honest and reconciled day covers, FOH hours, and BOH hours exactly to weekly totals.
- `7.55d.2` moved Shift to whole-business-day SchedulePlan comparison using all current business-date snapshots.
- `7.55d.2b` moved Shift LABOR % to the whole-day ShiftDashboardReadModel instead of WTD WeekData.
- `7.55d.3` added Manager Override downstream SchedulePlan impact preview and expanded the Data Alignment Audit proof.
- `7.55d.3a` corrected WTD, WeekRecord, and ShiftFact BOH model-hour paths to use actual sales, not target PPA.
- `7.55d.3b` corrected closed Variance detail to use locked actual-volume model-hour getters.
- `7.55d.3c` backfilled static/demo closed-shift rows with stable locked target defaults so strict Variance getters remain safe without adding fallback behavior.

Verification reported by Claude:

- `flutter analyze` clean.
- Full `flutter test` passed with 622 tests after `7.55d.3c`.

Remaining architecture that is related but not part of 7.55d:

- data-driven day/daypart distribution belongs to 7.55e.
- true business-date windowing belongs to 7.55f.
- canonical Demand Forecast Context and shared SchedulePlan read-service authority belong to 7.55i.

## Purpose

Phase 7.55d closes the remaining architecture gap between Baseline, Schedule, Shift, and Manager Override before live integrations arrive.

The correction is subtle but important:

```text
Closed shifts
-> Rolling 60-day Baseline Build
-> Demand Forecast Context + Active Target Profile
-> SchedulePlan
-> Schedule
-> Shift whole-day plan-vs-actual
```

Demand Forecast Context and Active Target Profile are sibling outputs of the baseline process. They should not be mashed into one object, and they should not be treated as unrelated systems.

## Product Math Truth

Forecast covers come from the restaurant's own 60-day trading history:

```text
60-day total covers: 10,286
weeks in 60 days: 60 / 7 = 8.57
average weekly covers: 10,286 / 8.57 = 1,200
```

That 1,200 is the forecasted covers input. It is not a guess and it is not a manager-entered Schedule value.

The other planning standards come from the Active Target Profile:

- target CPLH
- target SPLH
- target PPA
- FOH wage standard
- BOH wage standard
- OPZ bounds
- theoretical labor standards
- target blended wage when derived from the planned FOH/BOH hour mix

SchedulePlan combines those two baseline outputs:

```text
forecast covers = 60-day total covers / (60 / 7)
forecast sales = forecast covers * target PPA
required FOH hours = forecast covers / target CPLH
required BOH hours = forecast sales / target SPLH
FOH labor dollars = required FOH hours * FOH wage
BOH labor dollars = required BOH hours * BOH wage
total labor dollars = FOH labor dollars + BOH labor dollars
labor percent = total labor dollars / forecast sales
target blended wage = total labor dollars / total required hours
```

Using the current example:

```text
forecast covers = 1,200
target CPLH = 4.5
target PPA = 42.00
target SPLH = 180.00
FOH wage = 16.50
BOH wage = 21.35

required FOH hours = 1,200 / 4.5 = 267
forecast sales = 1,200 * 42.00 = 50,400
required BOH hours = 50,400 / 180.00 = 280
FOH labor dollars = 267 * 16.50 = 4,405.50
BOH labor dollars = 280 * 21.35 = 5,978.00
total theoretical labor dollars = 10,383.50
```

## Architecture Decision

Active Target Profile is standards, not demand.

Demand Forecast Context is demand, not standards.

Both are produced from the 60-day baseline process:

- Demand Forecast Context uses the full eligible 60-day cover total.
- Active Target Profile uses the selected baseline/star-shift standards.

Then SchedulePlan combines both:

```text
Demand Forecast Context
  forecast covers
  source/provenance

Active Target Profile
  target PPA
  target CPLH
  target SPLH
  wage standards
  OPZ / theoretical standards

SchedulePlan
  forecast covers
  forecast sales
  required FOH hours
  required BOH hours
  theoretical labor dollars
  theoretical labor percent
  target blended wage
```

The current code name for the demand side is `ScheduleForecastDemand`. That is acceptable as long as the implementation remains clear that it is a baseline-derived demand context.

## Current Discrepancies To Resolve

- Schedule has the right formula direction, but some plan math still lives too close to `schedule_builder.dart`.
- Shift can still read a daypart-scoped open snapshot and show daypart forecast math where Phase 8 wants whole-business-day live service truth.
- Shift forecast covers, forecast sales, FOH hours, and BOH hours can diverge from Schedule because they are not forced through one shared SchedulePlan.
- Manager Override can change target PPA, but the preview does not clearly show that forecast covers remain fixed while forecast sales and BOH planning change.
- Reservation `In the books` is correctly contextual, but in Phase 7.55d it must align to the same business-date scope and must not become actual covers or forecast covers.

This plan supersedes any approach that fixes the mismatch by simply changing daypart fixture constants to match. Demo values can be corrected only by flowing through the same architecture that live integrations will use.

## Whole-Day Shift Decision

Phase 8 Shift should show whole-business-day running totals during service.

Daypart remains important, but it belongs at close/finalization time for now:

- Variance uses finalized daypart closed truth.
- History uses finalized daypart closed truth.
- Learn studies finalized daypart closed truth.
- Shift live service uses whole-day plan-vs-actual.

Live daypart-aware Shift coaching is deferred to Phase 10.5.

## Manager Override Decision

Manager Override changes active target standards by changing the selected baseline/star-shift set.

It can affect:

- target PPA
- target CPLH
- target SPLH
- wage standards where supported
- OPZ bounds
- theoretical labor standards
- SchedulePlan forecast sales
- SchedulePlan required BOH hours
- SchedulePlan theoretical labor dollars and percent
- target blended wage

It must not affect:

- the 60-day total cover count
- forecast covers
- actual sales
- actual covers
- reservation `In the books`
- closed historical facts
- locked Variance truth

Changing target PPA specifically:

- forecast covers stay fixed
- forecast sales changes
- BOH required hours changes
- FOH required hours does not change unless target CPLH or forecast covers changes
- actual sales do not change

## Planning Vs Actual PPA Guardrail

Phase 7.55d must keep planning math and actual/closed-truth math separate.

Planning BOH math uses forecast sales from SchedulePlan:

```text
forecast sales = forecast covers * target PPA
required BOH hours = forecast sales / target SPLH
```

Actual, live, WTD, closed-shift, Variance, and Learn analysis must use actual sales, or actual PPA derived from actual sales divided by actual covers:

```text
actual PPA = actual sales / actual covers
actual-volume BOH model hours = actual sales / target SPLH
```

Target PPA must never be used as a substitute for actual sales in closed truth, WTD actual analysis, Variance locked truth, Learn pattern analysis, or live actuals. Target PPA is a standard used for planning and comparison, not a rewrite of what happened.

This means a Manager Override that changes target PPA can change:

- SchedulePlan forecast sales
- planned BOH hours
- theoretical labor dollars and percent
- target blended wage
- Shift plan targets after Shift consumes SchedulePlan

It must not change:

- actual sales
- actual covers
- actual PPA
- closed shift facts
- locked Variance facts
- actual-volume BOH model hours for closed/WTD/live actual analysis

## Demo Now / Live Later

Allowed now:

- build SchedulePlan from the existing `ScheduleForecastDemandResolver` and `ActiveTargetProfile`
- make Schedule render from SchedulePlan
- make Shift read today's whole-day SchedulePlan
- aggregate current demo actuals at the business-date level through repository/read-model paths
- show source/provenance labels so values can be audited
- add focused tests proving Schedule and Shift share the same plan values

Required later with official integrations:

- POS/labor adapters write canonical closed shifts and live/current facts
- closed shifts rebuild the rolling 60-day baseline
- baseline process refreshes both Demand Forecast Context and Active Target Profile
- official reservation adapters write reservation snapshots through Phase 8R
- Shift uses the same plan/read model with live facts instead of fixture facts

## Non-Goals

- Do not implement live POS, labor, OpenTable, or reservation transport.
- Do not add vendor forecast sales or forecast covers.
- Do not let managers edit forecast directly on Schedule.
- Do not store guest-level reservation detail for the Shift covers signal.
- Do not build Phase 10.5 daypart-aware live Shift coaching.
- Do not move demand fields into `ActiveTargetProfile`.
- Do not rewrite closed historical shifts when Manager Override changes.
- Do not update tracker files from Claude prompts unless Codex explicitly asks after verification.

## Prompt Breakdown

Phase 7.55d should run as three Claude prompts, verified by Codex after each:

1. `7.55d.1` - Shared SchedulePlan authority
2. `7.55d.2` - Whole-day Shift dashboard alignment
3. `7.55d.3` - Manager Override impact preview + audit proof

## Prompt 7.55d.1 - Shared SchedulePlan Authority

### Message 1: Context

```text
Before you do anything else, read these files and treat them as the authority for this run:

- PROJECT_TRACKER.md
- docs/DATA_ALIGNMENT_TRACKER.md
- docs/phase_7_55c_schedule_forecast_demand_source_plan.md
- docs/phase_7_55d_whole_day_shift_schedule_plan.md
- docs/CODEX_PROMPT_GENERATION_STANDARD.md
- lib/screens/schedule_builder.dart
- lib/domain/models/schedule_forecast_demand.dart
- lib/domain/services/schedule_forecast_demand_resolver.dart
- lib/domain/models/active_target_profile.dart
- lib/services/labor_model.dart
- test/schedule_forecast_demand_resolver_test.dart
- test/labor_model_boh_sales_test.dart

Important:
- Follow the current phase and prompt order from PROJECT_TRACKER.md.
- This run is Phase 7.55d.1 only.
- Codex owns tracker truth. Do not update PROJECT_TRACKER.md, PROJECT_TRACKER_ARCHIVE.md, or docs/DATA_ALIGNMENT_TRACKER.md in this run.
- Do not broaden into Shift UI rewrites, Manager Override UI, live integrations, auth, or Phase 10.5 daypart-aware Shift coaching.
```

### Message 2: Implementation Prompt

```text
Do not analyze broadly. Do not redesign anything else.

Implement Phase 7.55d.1: create the shared SchedulePlan authority.

Goal
Move Schedule planning math out of screen-owned logic and into a reusable app/domain contract.

SchedulePlan must combine the two outputs of the 60-day baseline process:

1. Demand Forecast Context / ScheduleForecastDemand
   - forecast covers from eligible 60-day total covers / (60 / 7)
   - demand source/provenance

2. Active Target Profile
   - target PPA
   - target CPLH
   - target SPLH
   - FOH wage
   - BOH wage
   - OPZ / theoretical standards

Schedule should render from this shared plan. Shift should not be rewritten in this prompt.

Current issue
Schedule currently has the right demand-source direction, but too much of the planning contract still lives inside schedule_builder.dart. The next phase needs Shift and Manager Override to reuse the same plan, so this prompt creates that plan first.

Hard constraints
- ActiveTargetProfile remains standards-only. Do not add demand fields to it.
- Demand Forecast Context remains demand-only and comes from the 60-day baseline cover total, currently exposed through ScheduleForecastDemandResolver.
- Forecast covers = eligible 60-day total covers / (60 / 7), with existing demo fallback behavior only when no history exists.
- Forecast sales = forecast covers * target PPA.
- FOH required hours = forecast covers / target CPLH.
- BOH required hours = forecast sales / target SPLH.
- This prompt creates planning math only. Do not use target PPA as actual PPA, and do not touch actual/closed-truth BOH analysis.
- Do not add vendor forecast sales or forecast covers.
- Do not add Schedule manager editing.
- Do not change Shift behavior yet.
- Do not update tracker files.

Suggested files to modify
- Add a new domain/read-model file if appropriate, for example:
  - lib/domain/models/schedule_plan.dart
  - lib/domain/services/schedule_plan_resolver.dart
- Modify:
  - lib/screens/schedule_builder.dart
- Add focused tests, for example:
  - test/schedule_plan_resolver_test.dart

Files to inspect but avoid changing unless necessary
- lib/data/baseline_manager_service.dart
- lib/infrastructure/persistence/sqlite/sqlite_database.dart
- lib/widgets/schedule_day_row.dart
- lib/widgets/data_alignment_audit_panel.dart

Implementation tasks
1. Introduce an immutable SchedulePlan or equivalent read model that carries weekly and day-level planning values:
   - forecast covers
   - forecast sales
   - required FOH hours
   - required BOH hours
   - theoretical FOH labor dollars
   - theoretical BOH labor dollars
   - theoretical labor percent
   - target blended wage
   - source/provenance text or enum data from demand resolution
2. Add a resolver/service that builds this plan from ScheduleForecastDemand and ActiveTargetProfile.
3. Make ScheduleForecastNotifier or the Schedule screen consume the shared plan instead of recalculating the same formulas locally.
4. Preserve existing Schedule visuals unless tiny label wiring is needed to show the same provenance.
5. Add tests proving:
   - a 60-day total of 10,286 covers resolves to about 1,200 weekly forecast covers when divided by 60/7
   - target PPA changes forecast sales while forecast covers stay unchanged
   - FOH hours use covers / targetCPLH
   - BOH hours use forecastSales / targetSPLH
   - theoretical labor dollars and target blended wage use FOH/BOH wages and model hour mix
   - Schedule plan source provenance is preserved

Acceptance criteria
- Schedule values are produced by the shared plan contract.
- No demand fields are added to ActiveTargetProfile.
- The existing 7.55c demand-source rules remain intact.
- No Shift UI or Manager Override UI behavior is changed in this prompt.
- Focused tests pass.
- flutter analyze passes.

Run
- flutter analyze
- flutter test test/schedule_forecast_demand_resolver_test.dart test/labor_model_boh_sales_test.dart
- flutter test test/schedule_plan_resolver_test.dart, if added
- full flutter test if practical

When finished, report only:
- files changed
- behavior changes
- tests run and results
- blockers or skipped checks
```

## Prompt 7.55d.2 - Whole-Day Shift Dashboard Alignment

### Message 1: Context

```text
Before you do anything else, read these files and treat them as the authority for this run:

- PROJECT_TRACKER.md
- docs/DATA_ALIGNMENT_TRACKER.md
- docs/phase_7_55d_whole_day_shift_schedule_plan.md
- docs/phase_7_56_reservation_book_signal_plan.md
- lib/screens/shift_dashboard.dart
- lib/data/shift_dashboard_notifier.dart
- lib/data/shift_service.dart
- lib/models/shift_dashboard_read_model.dart
- lib/domain/models/schedule_plan.dart, if it exists from 7.55d.1
- lib/domain/services/schedule_plan_resolver.dart, if it exists from 7.55d.1
- lib/infrastructure/persistence/sqlite/sqlite_database.dart
- test/shift_dashboard_notifier_test.dart
- test/shift_dynamic_truth_test.dart
- test/shift_visual_widget_test.dart

Important:
- Follow the current phase and prompt order from PROJECT_TRACKER.md.
- This run is Phase 7.55d.2 only and depends on 7.55d.1.
- Codex owns tracker truth. Do not update PROJECT_TRACKER.md, PROJECT_TRACKER_ARCHIVE.md, or docs/DATA_ALIGNMENT_TRACKER.md in this run.
- Do not implement live integrations.
- Do not build Phase 10.5 daypart-aware live Shift coaching.
- Do not let reservation `In the books` change actual covers, forecast covers, labor percent, OPZ, or lever math.
```

### Message 2: Implementation Prompt

```text
Do not analyze broadly. Do not redesign the Shift screen.

Implement Phase 7.55d.2: align Shift to the whole-business-day SchedulePlan.

Goal
Shift should compare today's live/current whole-day actuals against today's shared SchedulePlan. It should no longer present daypart forecast math as if it were the whole Shift truth for Phase 8.

Current issue
Shift currently reads a daypart-scoped open shift snapshot and can show forecast/actual values that align only to a synthetic Schedule daypart row. Phase 8 requires Shift to show whole-day running totals during service; daypart split happens later at close/finalization time. Per-service-period Shift views are Phase 10.5.

Hard constraints
- Shift forecast covers and forecast sales must come from today's shared SchedulePlan.
- Shift target FOH and BOH hours must come from today's shared SchedulePlan.
- Live/current actual covers, sales, FOH hours, and BOH hours must be whole-business-day running totals.
- Planning BOH math must use SchedulePlan forecast sales; live actual BOH analysis must use actual sales, not target PPA as a substitute for actual sales.
- Demo data may be aggregated from existing fixture/SQLite facts, but do not introduce new screen constants as truth.
- Reservation `In the books` remains contextual only.
- Variance, History, Learn, and closed daypart facts must not be rewritten.
- Primary Driver should remain hidden unless it can be proven aligned to the whole-day scope.
- Do not update tracker files.

Suggested files to modify
- lib/data/shift_dashboard_notifier.dart
- lib/data/shift_service.dart
- lib/models/shift_dashboard_read_model.dart
- lib/screens/shift_dashboard.dart
- test/shift_dashboard_notifier_test.dart
- test/shift_dynamic_truth_test.dart
- test/shift_visual_widget_test.dart

Potential helper files
- a new application/query service for ShiftDashboard whole-day read model, if that matches the repo style
- fixture or seed adjustments only when they feed the repository/read-model path

Implementation tasks
1. Find the current Shift forecast path and remove any independent forecast math that should now come from SchedulePlan.
2. Build or update the Shift read path so today's plan values are pulled from the shared SchedulePlan:
   - forecast covers
   - forecast sales
   - target FOH hours
   - target BOH hours
   - theoretical labor dollars/percent if displayed
   - target blended wage if displayed
3. Aggregate current actuals at the business-date level for demo/current data:
   - actual covers
   - actual sales
   - actual FOH hours
   - actual BOH hours
   - actual labor dollars or blended wage where available
4. Keep daypart labels only as service context if currently needed, not as the scope of the plan math.
5. Aggregate reservation `In the books` for the same business-date scope or clearly document/surface the daypart context without letting it alter math.
6. Add focused tests proving Shift and Schedule share the same day plan values.
7. Add tests proving projected/future rows do not become actuals.

Acceptance criteria
- Shift forecast covers for today match the corresponding whole-day SchedulePlan row.
- Shift forecast sales for today match forecast covers * target PPA from the shared plan.
- Shift target FOH hours match covers / targetCPLH from the shared plan.
- Shift target BOH hours match forecastSales / targetSPLH from the shared plan.
- Shift actuals are whole-business-day running totals, not a single daypart forecast row.
- Shift actual sales/current PPA are not recalculated from target PPA.
- Any actual-volume BOH needed/model value uses actual sales or actual PPA derived from actual sales divided by actual covers.
- Reservation `In the books` displays as context only and does not change operational math.
- Existing Variance and closed-history behavior remain intact.

Run
- flutter analyze
- flutter test test/shift_dashboard_notifier_test.dart test/shift_dynamic_truth_test.dart test/shift_visual_widget_test.dart
- flutter test test/schedule_plan_resolver_test.dart, if present
- full flutter test if practical

When finished, report only:
- files changed
- behavior changes
- tests run and results
- blockers or skipped checks
```

## Prompt 7.55d.3 - Manager Override Impact Preview + Audit Proof

### Message 1: Context

```text
Before you do anything else, read these files and treat them as the authority for this run:

- PROJECT_TRACKER.md
- docs/DATA_ALIGNMENT_TRACKER.md
- docs/phase_7_55d_whole_day_shift_schedule_plan.md
- lib/screens/baseline_manager_screen.dart
- lib/data/baseline_manager_service.dart
- lib/domain/models/active_target_profile.dart
- lib/domain/models/schedule_plan.dart, if it exists from 7.55d.1
- lib/domain/services/schedule_plan_resolver.dart, if it exists from 7.55d.1
- lib/widgets/data_alignment_audit_panel.dart
- test/baseline_override_propagation_test.dart
- test/target_consistency_opz_test.dart

Important:
- Follow the current phase and prompt order from PROJECT_TRACKER.md.
- This run is Phase 7.55d.3 only and depends on 7.55d.1 and 7.55d.2.
- Codex owns tracker truth. Do not update PROJECT_TRACKER.md, PROJECT_TRACKER_ARCHIVE.md, or docs/DATA_ALIGNMENT_TRACKER.md in this run.
- Do not implement live integrations.
- Do not rewrite closed historical shifts.
- Do not make target PPA behave like actual sales. Planning BOH uses SchedulePlan forecast sales; actual/closed BOH analysis uses actual sales.
```

### Message 2: Implementation Prompt

```text
Do not analyze broadly. Do not redesign Baseline Manager beyond the impact preview and audit proof.

Implement Phase 7.55d.3: Manager Override downstream impact preview and audit proof.

Goal
When a manager changes the selected baseline shifts, the preview should show what the draft target profile would do to Schedule and Shift planning before the manager commits.

Current issue
Manager Override currently previews selected shift count and target standards, but it does not make the downstream planning impact auditable. The biggest missing piece is target PPA: changing target PPA should not change forecast covers, but it should change forecast sales and BOH planning.

Hard constraints
- Manager Override can change target standards through the active target profile.
- Forecast covers remain demand-side and unchanged by target PPA.
- Forecast sales = forecast covers * target PPA.
- FOH required hours = forecast covers / target CPLH.
- BOH required hours = forecast sales / target SPLH.
- Closed historical facts must remain immutable.
- Actual sales and actual covers must not be recalculated from target PPA.
- Target PPA must not be used as a substitute for actual sales in WTD, closed-shift, Variance, Learn, or live actual analysis.
- Do not update tracker files.

Suggested files to modify
- lib/screens/baseline_manager_screen.dart
- lib/data/baseline_manager_service.dart, only if a preview read model needs service support
- lib/widgets/data_alignment_audit_panel.dart
- test/baseline_override_propagation_test.dart
- test/target_consistency_opz_test.dart
- add a focused Manager Override impact-preview test if needed

Implementation tasks
1. Add or reuse a preview read model that builds a draft ActiveTargetProfile from the selected manager-override shifts.
2. Combine that draft target profile with the current ScheduleForecastDemand / SchedulePlan demand context.
3. In the Manager Override preview, show the planning impact:
   - forecast covers unchanged
   - target PPA
   - forecast sales
   - required FOH hours
   - required BOH hours
   - theoretical FOH labor dollars
   - theoretical BOH labor dollars
   - total theoretical labor dollars
   - FOH labor percent
   - BOH labor percent
   - total labor percent
   - target blended wage
4. If candidate shift rows have available fields, make their displayed data more live-ready:
   - business date
   - day/week/daypart
   - covers
   - sales
   - PPA
   - FOH hours
   - BOH hours
   - CPLH
   - SPLH
   - labor percent or labor dollars where available
   - source/finalization/data-quality status where available
5. Add an audit proof row or panel check showing that Baseline -> ActiveTargetProfile + DemandForecastContext -> SchedulePlan -> Shift are using the same plan values after override.
6. Add tests proving PPA ripple behavior:
   - changing target PPA changes forecast sales
   - changing target PPA changes BOH required hours
   - changing target PPA does not change forecast covers
   - changing target PPA does not rewrite actual sales or closed history
   - changing target PPA does not change actual PPA or actual-volume BOH model hours when actual sales and covers are unchanged

Acceptance criteria
- Manager Override preview makes downstream plan impact visible before commit.
- PPA behavior is mathematically correct and tested.
- Closed history remains untouched.
- Target PPA remains a planning/comparison standard, not a replacement for actual sales.
- The audit surface can help a reviewer verify Baseline -> ActiveTargetProfile + DemandForecastContext -> SchedulePlan -> Shift alignment.
- Existing manager override persistence behavior remains intact.

Run
- flutter analyze
- flutter test test/baseline_override_propagation_test.dart test/target_consistency_opz_test.dart
- flutter test test/schedule_plan_resolver_test.dart, if present
- any new focused Manager Override impact test
- full flutter test if practical

When finished, report only:
- files changed
- behavior changes
- tests run and results
- blockers or skipped checks
```

## Codex Verification After Each Prompt

After Claude finishes each sub-prompt, Codex should verify:

- no tracker files were changed by Claude
- architecture matches this plan
- Demand Forecast Context and Active Target Profile remain sibling baseline outputs
- formulas route through `LaborModel` or the approved shared SchedulePlan service
- no hardcoded demo constants were introduced as screen truth
- tests named in the prompt pass or skipped checks are explained
- full `flutter test` passes before declaring the sub-prompt done, when practical

Only after verification should Codex update tracker truth.
