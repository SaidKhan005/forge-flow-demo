# Phase 7.55k - Daypart Separation, Variance, History, and Learn

Updated: 2026-04-10
Owner: Codex planning / tracker truth
Status: Planned, not implemented

## Purpose

Phase 7.55k captures the downstream implications of making the app more daypart-aware.

The app now has daypart-level closed shift facts and Schedule daypart distribution planning. That does not mean every downstream surface is already daypart-native. This phase prevents Variance, History, and Learn from overstating what they know while also preparing them to use daypart evidence more powerfully.

The key distinction:

```text
daypart-aware data exists
does not automatically equal
daypart-native coaching
```

## Current Truth

### Baseline

Baseline and Manager Override already operate on closed daypart shift candidates. That is the right level for selecting sustainable target standards because a lunch and a Saturday dinner are operationally different facts.

Remaining baseline/date cleanup is owned by 7.55f and 7.55i:

- 7.55f persists `business_date` and replaces week-id approximations with real 60-day windows.
- 7.55i creates canonical demand and shared SchedulePlan authority so downstream surfaces stop reading compatibility globals.

### Schedule

Schedule now has:

- weekly forecast covers
- weekly forecast sales derived from covers * target PPA
- weekly FOH/BOH model hours
- day-level allocation
- day x daypart distribution weights

Schedule dayparts are planning allocation rows. They are not live service-period actuals.

### Shift

Shift is intentionally whole-business-day today.

Current behavior:

- loads all snapshots for the current `business_date`
- aggregates closed + open actuals for covers/sales/labor actuals
- includes projected snapshots for scheduled hours where appropriate
- compares the whole day against the matching SchedulePlan day row
- aggregates reservation `In the books` across the business day

Shift is not daypart-live yet. That remains Phase 10.5.

### Variance

Variance has mixed scope today:

- This Week / WTD is aggregate week-to-date.
- Full Week Projection renders day rows and expandable daypart rows.
- Closed daypart detail uses locked target fields and actual-volume model hours.
- Open/projected daypart rows are converted from `OpenShiftSnapshot`.
- The screen still describes projected rows generically, and the weekly projection semantics are not yet centrally documented.

This is mostly correct structurally, but it needs a stronger read-model contract and clearer labels so managers understand whether they are seeing closed truth, live open truth, or projected plan context.

### History

History currently builds one `HistoryPatternRecord` per eligible closed shift:

- week id / label
- day label
- daypart
- primary lever id
- benchmark boolean

The History teaching analyzer then summarizes frequencies.

This is useful, but it is not yet a rich benchmark-daypart model. It can say "these dayparts repeatedly show favorable patterns." It cannot yet say with enough evidence "this daypart is the best benchmark because it held X CPLH, Y SPLH, Z PPA at N covers."

### Learn

Learn consumes the same lightweight pattern records.

Repeatable Wins currently means:

- most common favorable lever
- count of repeats
- daypart labels where favorable patterns appeared
- generic teaching copy from the lever card

That is a valid first pass, but it lacks the operational proof needed for stronger coaching: sample count, average covers, sales, PPA, CPLH, SPLH, FOH/BOH hours, labor percentage, and exemplar closed shifts.

## Architectural Problem

The app is close to having the right inputs, but the downstream teaching layer is still too thin.

Current data shape:

```text
Closed daypart ShiftRecord
-> HistoryPatternRecord(daypart + lever + benchmark flag)
-> History/Learn frequency summary
```

Desired 7.55k direction:

```text
Closed daypart ShiftRecord
-> DaypartPatternSummary with counts, averages, variance, and exemplar ids
-> History benchmark dayparts
-> Learn repeatable wins with proof
```

This keeps Shift whole-day while letting Variance, History, and Learn use closed daypart truth more honestly.

## Full Daypart Separation - Long-Term Plan

Full daypart separation means every operational surface can answer two questions without guessing:

```text
Which business day is this?
Which service period inside that business day is this?
```

The long-term identity should be:

```text
restaurantId + businessDate + daypart
```

`weekId` and `dayLabel` can remain useful labels and grouping fields, but they should not be the durable authority for daypart facts. This matters for holidays, shifted service calendars, late-night service, daylight saving time, imported corrections, and vendor-specific business-day definitions.

### Desired End State

```text
Official POS / labor / reservation APIs
-> vendor DTOs inside adapters only
-> raw import records + import runs + sync watermarks
-> canonical source facts
-> app-owned daypart classifier
-> closed/open/planned service-period facts
-> read services
-> UI read models
-> screens
```

The app should eventually have three separate service-period fact shapes:

- closed service-period fact: final truth from POS/labor, locked target snapshot, eligible for Baseline, Variance, History, and Learn
- open service-period fact: live in-progress truth for the current business day, not eligible for history
- planned service-period fact: schedule/forecast placeholder, not actual performance

The current models roughly map to these ideas:

- `ShiftRecord` = closed or projected daypart-shaped record, but it still lacks persisted `business_date`
- `OpenShiftSnapshot` = open/projected current-week daypart state with `businessDate`
- `SchedulePlan` = weekly/day plan authority with day rows and Schedule UI daypart subrows
- `HistoryPatternRecord` = lightweight closed daypart signal

The long-term refactor should make those boundaries explicit instead of letting UI widgets infer them.

## Decoupling and Refactoring Plan

### 1. Make Service-Period Identity First-Class

Add or formalize a small identity object:

```dart
class ServicePeriodKey {
  final String restaurantId;
  final String businessDate;
  final String daypart;
}
```

Use it for closed facts, open snapshots, reservation snapshots, schedule daypart rows, and read-model joins. This should land after or with 7.55f because `ShiftRecord` must first persist `business_date`.

### 2. Centralize Daypart Definitions

Today daypart ordering and daypart labels are repeated across widgets/services.

Long-term target:

- one app-owned daypart definition source per restaurant
- daypart id, label, sort order, start/end rules, and late-night rollover semantics
- adapters do not own daypart rules unless a vendor provides an official service-period field and the app explicitly maps it

This avoids hardcoding assumptions like `lunch -> dinner -> late_night` across screen helpers.

### 3. Move Mixed Screen Logic Into Read Services

Variance Full Week currently builds mixed day/daypart behavior inside widget helpers. Long-term, create read services such as:

```dart
VarianceWeekProjectionReadService
DaypartPatternSummaryService
LearnCoachingReadService
ShiftDayReadService
ShiftServicePeriodReadService // Phase 10.5
```

Screens should render read models. They should not decide which rows are closed truth, live truth, projected placeholders, benchmark evidence, or hidden due to insufficient sample size.

### 4. Keep Formula Ownership In Domain Services

Do not move formulas into UI or adapters.

Formula ownership should remain:

- `LaborModel` for labor math
- `SchedulePlanResolver` for plan math
- closed fact builders for final actual-vs-target lever detection
- read services for aggregation and presentation scope

### 5. Split Source Facts From Derived Summaries

The app should not treat `WeekRecord` or History summaries as source truth.

Long-term layering:

```text
source facts
-> closed ShiftRecords / service-period facts
-> derived week rollups
-> derived daypart summaries
-> UI read models
```

If an integration correction arrives after close, source facts and closed service-period facts update first; summaries rebuild from them.

## What Should Wait For Live Integration Capability Profiles

Some work should wait until official POS/labor/reservation API capability profiles are known. Otherwise the app risks coding around fake assumptions.

Wait for official integration details before finalizing:

- vendor endpoint names and transport shape
- whether POS provides check-level, order-level, or summarized shift-level data
- whether POS covers/guest count is reliable, missing, or channel-specific
- vendor business-date semantics
- timestamp semantics for opened, closed, paid, voided, refunded, and updated records
- whether intraday POS current sales/covers are available
- whether POS exposes service periods, revenue centers, or only timestamps
- how refunds, voids, comps, discounts, and late edits appear after close
- labor schedule granularity: shift, role, job, department, or employee
- labor actual granularity: punches, approved timesheets, payroll summaries, or daily totals
- whether labor dollars/wages are exposed or must be app-estimated
- current clocked-in labor availability
- reservation status vocabulary and status timestamps
- reservation webhook vs polling support
- whether reservation guest details must be discarded immediately

Do not wait for integration details to build app-owned abstractions. Do wait before hardcoding vendor-specific semantics into domain models.

## What Can Be Implemented Before Live Integration

The following is safe to implement with mock replay and current closed facts:

- service-period scope audit and labels
- `DaypartPatternSummary` derived from closed `ShiftRecord`s
- sample-size gating for benchmark dayparts
- closed-only rule for History and Learn
- Variance Full Week row-scope labels and reconciliation tests
- hiding or downgrading weak coaching claims when evidence is insufficient
- data alignment/audit rows that show whether a value is closed, open, projected, or derived
- integration capability placeholders in 7.55j

These do not require live vendor transport because they are app-side interpretation and presentation rules.

## What Should Stay Hidden Or Soft-Labeled For Now

Until full daypart separation and live integration capability profiles are ready, keep the following hidden or clearly soft-labeled:

- live service-period Shift primary driver
- any claim that Shift is judging the current lunch/dinner/late-night period
- role-level labor coaching
- labor-dollar claims when the labor connector does not expose actual dollars
- reservation-driven explanations in History/Learn
- benchmark dayparts when sample size is below threshold
- Repeatable Wins when the evidence is only one or two shifts
- projected rows presented as performance truth
- vendor forecast claims, since current policy is app-derived demand from POS history

Preferred labels:

- `Early signal` for thin sample history
- `Projected` for planned/non-final rows
- `Live in progress` for open rows
- `Closed truth` for finalized rows
- `Hidden until enough closed dayparts` when benchmark/repeatable-win evidence is weak

## Guardrails

- Do not make Shift daypart-live in 7.55k. That remains Phase 10.5.
- Do not create new labor formulas. Route calculations through `LaborModel` and locked target fields where applicable.
- Do not let target PPA substitute for actual sales in closed actual analysis.
- Do not let reservation `In the books` become actual covers or forecast covers.
- Do not rely on `BaselineData` for production-facing History/Learn benchmark context; that retirement is coordinated with 7.55i.
- Keep projected/open rows clearly labeled as non-final.
- Closed Variance detail must continue using locked target truth from the closed shift.
- Daypart benchmarks should require enough closed history to avoid treating one lucky shift as a repeatable win.
- Any UI copy must name the scope: closed truth, live/open, projected, WTD, full week, or benchmark history.

## 7.55k Work Breakdown

### 7.55k.1 - Daypart Scope Audit

Create a codebase audit focused on Variance, History, and Learn.

Deliverables:

- list every daypart-aware field and where it is consumed
- classify each surface as whole-day, WTD aggregate, day row, daypart detail, or historical pattern
- document where UI labels currently overstate precision
- add narrow tests or assertions where feasible to preserve the intended scope

Acceptance:

- Shift remains documented as whole-business-day.
- Variance Full Week is documented as a hybrid of closed, open, and projected daypart rows.
- History/Learn are documented as closed-history pattern surfaces, not live views.

### 7.55k.2 - Service-Period Decoupling Plan

Before adding more UI behavior, document and optionally scaffold the service-period boundary.

Deliverables:

- identify all current `weekId|dayLabel|daypart` keys that should become `restaurantId|businessDate|daypart`
- list every place where daypart ordering/labels are hardcoded
- propose the minimum `ServicePeriodKey`/daypart-definition model shape
- decide which read services should be introduced before Phase 10.5
- define which parts belong to 7.55f, 7.55i, 7.55k, and Phase 10.5

Acceptance:

- no screen should need to know vendor DTO shape
- no widget should decide closed/open/projected source truth
- `business_date` persistence remains explicitly owned by 7.55f
- full live service-period Shift remains Phase 10.5

### 7.55k.3 - Daypart Pattern Summary Model

Add a richer daypart pattern summary layer derived from closed `ShiftRecord`s.

Candidate model:

```dart
class DaypartPatternSummary {
  final String dayLabel;
  final String daypart;
  final int closedShiftCount;
  final int benchmarkCount;
  final int leakCount;
  final String? dominantBenchmarkLeverId;
  final String? dominantLeakLeverId;
  final double avgCovers;
  final double avgSales;
  final double avgPPA;
  final double avgCPLH;
  final double avgSPLH;
  final double avgFohHours;
  final double avgBohHours;
  final double avgLaborPct;
  final double avgVariancePts;
  final List<String> exemplarSourceShiftIds;
}
```

The exact shape can change during implementation, but the summary must keep enough proof to explain why a daypart is a benchmark or a recurring leak.

Acceptance:

- closed-only input
- grouped by day label + daypart
- stable ordering
- minimum sample threshold
- no projected/open rows included
- no mutable fixture globals in production-facing behavior

### 7.55k.4 - Variance Full Week Projection Semantics

Tighten Full Week Projection so it is clear what each row means.

Required decisions:

- closed rows = locked closed truth
- open rows = live in-progress snapshot, not final truth
- projected rows = forecast/planned placeholder, not actual performance
- day totals = aggregation of the rows currently visible for that day
- week projection = WTD closed truth plus remaining open/projected context

Implementation should consider a dedicated read model instead of leaving this mixed behavior in widget helpers.

Acceptance:

- closed daypart detail still uses actual covers and actual sales with locked target standards
- open/projected rows show status/provenance clearly
- day row totals reconcile to expanded daypart rows
- WTD aggregate and Full Week rows do not silently use different target semantics without labels
- the projected-row copy is updated if it still says "Projected from 60-day baseline" while the row actually comes from mock replay/open snapshot/SchedulePlan context

### 7.55k.5 - History Benchmark Dayparts Upgrade

Upgrade History benchmark dayparts from frequency labels to evidence-backed daypart summaries.

Desired behavior:

- benchmark dayparts come from closed shifts only
- favorable levers count toward benchmark candidacy
- recurring leak dayparts are tracked separately
- summaries include count and metric context, not just labels
- ties are deterministic and operationally meaningful

Example output concept:

```text
BENCHMARK DAYPARTS
Sat Dinner - 5 wins, avg 4.8 CPLH, 188 SPLH
Thu Dinner - 4 wins, avg 4.6 CPLH, 181 SPLH
```

The visible UI can stay compact, but the read model should carry the evidence.

### 7.55k.6 - Learn Repeatable Wins Upgrade

Make Repeatable Wins explain why the win repeats.

Desired behavior:

- show benchmark dayparts from the richer daypart summary
- show the dominant favorable lever
- show sample count
- show one or two metric proofs that made the win repeatable
- keep generic lever-card teaching as supporting copy, not the only evidence

Example output concept:

```text
Sat Dinner repeated 5 times.
What held: PPA stayed above target while SPLH stayed near model.
Protect: the staffing shape and pacing from those closed shifts.
```

Acceptance:

- no open/projected rows in Learn
- no live reservation data in repeatable wins unless a later phase explicitly adds explanatory reservation context
- source shift ids or dates are available for future drill-in
- Learn benchmark context migration remains aligned with 7.55i

### 7.55k.7 - Interim Visibility Rules

Add explicit gating for what users see while full daypart separation is not complete.

Suggested rules:

- show closed daypart evidence only when minimum sample count is met
- show `Early signal` instead of `Benchmark` when sample count is thin
- hide Repeatable Wins when there are no repeated favorable closed daypart patterns
- keep projected/open rows visible in Variance only as current-week context
- do not show reservation-based History/Learn explanations yet
- do not show live daypart Shift primary driver yet

Acceptance:

- no surface claims more certainty than the underlying data supports
- empty/partial states are intentional product states, not missing UI
- tests cover closed-only and minimum-sample behavior

### 7.55k.8 - Integration Implications

Feed any new endpoint needs back into 7.55j.

Daypart-native History/Learn require official integrations to provide or support:

- business date
- service timestamp or close timestamp
- sales/covers by check/order or shift
- labor scheduled and actual hours by role/time range
- wage or labor dollar data when available
- source ids for closed shift, labor shift, punch, and schedule rows
- correction/update feeds after close
- enough timestamp detail for app-owned daypart mapping

Reservation data remains optional explanatory context for these surfaces unless a later product decision promotes it into demand forecasting.

## Relationship To Other Phases

### 7.55f

7.55f supplies true `business_date`. 7.55k should use it once available so daypart summaries can be tied to real dates instead of week/day labels alone.

### 7.55i

7.55i supplies canonical demand and shared SchedulePlan authority. 7.55k should not duplicate that work. It should consume the canonical plan/target context where needed.

### 7.55j

7.55j inventories integration requirements. 7.55k should add daypart-history and repeatable-win requirements back into that inventory.

### Phase 10.5

Phase 10.5 is still the live daypart-aware Shift screen.

7.55k can make closed-history daypart coaching better, but it should not change the Shift dashboard from whole-day to current-service-period behavior.

## Closeout Criteria

7.55k can close when:

- Variance Full Week projection has explicit row-scope semantics and reconciliation tests.
- History benchmark dayparts are backed by closed-shift evidence, not only frequency labels.
- Learn Repeatable Wins uses daypart summary evidence and exposes why a win is repeatable.
- Open/projected data never enters benchmark or repeatable-win history.
- Remaining integration requirements are reflected in 7.55j or its handoff notes.
- Tracker notes clearly state that Shift remains whole-day until Phase 10.5.
