# Phase 7.56c.0 - Full Week Projection Authority Alignment

Updated: 2026-04-24
Owner: Codex planning / tracker truth
Status: Complete - rolled into the `7.56c` phase close

## Closeout Note

Accepted alongside `7.56c.1`. The shared `DaypartPlanAllocator` lane plus
the projection-sales / target-hour field follow-ups landed before
`7.56c.1` and are exercised by the J1-J4 cases in
`test/current_state_alignment_test.dart` — those tests now sit in the
`J — 7.56c.0 Full Week plan daypart alignment` group and are part of the
green closeout evidence (`flutter test test/current_state_alignment_test.dart`,
all 40 tests passing as of 2026-04-24).

## Goal

Repair Variance Full Week projection so open/projected daypart rows read the
same Plan-owned and Benchmark-owned authority values as the rest of the app.

This slice intentionally runs before `7.56c.1` audit expansion. The audit
should measure the repaired architecture shape, not document a known
production drift as the new baseline.

## Plain English

Full Week projection should not have its own version of the plan. If Plan says
Saturday dinner is 178 covers with 39 FOH hours and 43 BOH hours, the matching
Full Week Saturday dinner projected row should show those same plan targets,
while Benchmark targets like PPA, CPLH, wages, and theoretical labor % come from
the active Benchmark profile.

## Triggering Finding

A live demo probe on 2026-04-24 showed Full Week projected/open plan values can
drift from the locked weekly plan / Schedule daypart presentation:

| Day | Locked plan day covers | Full Week child forecast sum |
| --- | ---: | ---: |
| Fri | 231 | 220 |
| Sat | 223 | 230 |
| Sun | 106 | 110 |

The same probe also showed projected rows carrying `snapshotBlendedWage = 0.00`.
`VarianceWeekProjectionReadService` treats that zero as real labor dollars for
collapsed day-row labor %, while expanded detail falls back to the active
Benchmark target blended wage. Result: all-projected days can render `0.0%`
labor and a false `-20.1 pts` gap.

## Architecture Authority

This slice follows `7.55q.1` conformance rules:

- Rule 1: the in-force week has one locked weekly plan object.
- Rule 2: Benchmark target metrics come from one shared
  `ActiveTargetProfile`.
- Rule 3: non-closed Variance rows read shared objects 1:1.
- Rule 4: closed Full Week rows stay locked historical truth.

### Non-Closed Full Week Rows

Open/projected rows should read:

| Metric family | Authority |
| --- | --- |
| Forecast covers | Plan / locked `WeeklyPlanSnapshot` daypart allocation |
| Forecast sales | Plan / locked `WeeklyPlanSnapshot` daypart allocation |
| Required FOH hours | Plan / locked `WeeklyPlanSnapshot` daypart allocation |
| Required BOH hours | Plan / locked `WeeklyPlanSnapshot` daypart allocation |
| Target PPA | `ActiveTargetProfile.targetPPA` |
| Target CPLH | `ActiveTargetProfile.targetCPLH` |
| Target SPLH | `ActiveTargetProfile.targetSPLH` |
| FOH wage | `ActiveTargetProfile.fohWage` |
| BOH wage | `ActiveTargetProfile.bohWage` |
| Target blended wage | `ActiveTargetProfile.targetBlendedWage` |
| OPZ bounds | `ActiveTargetProfile.opzFloorCPLH` / `opzCeilingCPLH` |
| Theoretical FOH / BOH / total labor % | `ActiveTargetProfile` theoretical fields |

### Closed Full Week Rows

Closed rows should stay on their locked-at-close target and plan fields. Do not
re-read current `ActiveTargetProfile` or rewrite closed historical comparison
truth in this slice.

## Current Gap

Schedule already builds daypart subrows from locked `SchedulePlan` day rows:

- plan day covers split across service periods
- day sales split proportionally across subrow covers
- FOH hours split proportionally across subrow covers
- BOH hours split proportionally across subrow sales
- service-period order/labels from persisted restaurant timing definitions,
  with the existing demo fallback

Full Week currently reads open/projected plan-like fields from
`OpenShiftSnapshot` -> `CurrentWeekState.shiftRecordFromSnapshot` ->
`ShiftRecord`. Those snapshot values can diverge from the locked plan /
Schedule daypart allocation.

## Implementation Direction

Prefer extracting the Schedule daypart subrow allocation into a shared pure
helper/service rather than duplicating formulas.

Likely shape:

- create a shared allocator/read helper for locked plan daypart targets
  (covers, sales, FOH hours, BOH hours)
- make `ScheduleForecastNotifier.adjustedDayViews` and Variance Full Week use
  the same allocator
- preserve current service-period definition behavior:
  - persisted `RestaurantTimingConfig.servicePeriodDefinitions` when available
  - existing demo fallback when unavailable
- preserve existing distribution weight behavior:
  - data-driven `ScheduleDistributionWeights` when available
  - existing daypart cover weights fallback when unavailable
- update open/projected Full Week rows or the projection read model so
  Plan-owned cells and collapsed aggregates use the shared plan target package
  for the matching day + daypart
- update collapsed projected labor % so a zero/absent snapshot wage does not
  override the active Benchmark target blended wage

## Files To Consider

- `lib/screens/schedule/schedule_forecast_notifier.dart`
- `lib/screens/schedule/schedule_view_models.dart`
- `lib/services/variance_week_projection_read_service.dart`
- `lib/data/shift_service.dart`
- `lib/models/current_week_state.dart`
- `lib/models/variance_week_projection_row.dart`
- focused tests under `test/variance_week_projection_read_service_test.dart`
  and `test/current_state_alignment_test.dart`
- widget verification under `test/variance_visual_widget_test.dart` if the
  rendered Full Week values change

## Files To Leave Alone

- SQLite schema / migrations / seed files
- `target_cycle_service.dart`
- `weekly_plan_snapshot_service.dart`
- `schedule_plan_read_service.dart`
- reservation-book files
- Benchmark selection summary files
- closed-shift historical target semantics

## Out Of Scope

- Persisting daypart plan rows into `WeeklyPlanSnapshot`
- Changing SchedulePlan formulas
- Changing TargetCycle / ActiveTargetProfile formulas
- Changing closed-row Full Week locked target behavior
- Adding live POS/labor/reservation transport
- Adding Shift daypart-live driver teaching (`10.5` owns that)
- Expanding the Data Alignment Audit panel (`7.56c.1` owns that after this
  repair)

## Acceptance

- Non-closed Full Week daypart rows use the same Plan daypart target package
  as Schedule for forecast covers, forecast sales, required FOH hours, and
  required BOH hours.
- Non-closed Full Week daypart rows use `ActiveTargetProfile` for all
  Benchmark-owned target standards: PPA, CPLH, SPLH, wages, OPZ, blended wage,
  and theoretical labor percentages.
- Collapsed Full Week open/projected labor % no longer treats
  `snapshotBlendedWage = 0.00` as an authoritative zero-wage plan.
- Closed Full Week rows remain locked historical truth.
- WTD behavior remains unchanged.
- Schedule visible totals and daypart subrows remain unchanged except for
  being backed by a shared helper instead of private duplicated logic.
- Tests prove at least one mixed day and one all-projected day align to the
  shared Plan/Benchmark authorities.

## Required Tests

- `dart analyze`
- `flutter test test/variance_week_projection_read_service_test.dart`
- `flutter test test/current_state_alignment_test.dart`
- `flutter test test/variance_visual_widget_test.dart`
- `flutter test test/schedule_builder_widget_test.dart`
