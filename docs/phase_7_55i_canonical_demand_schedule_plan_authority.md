# Phase 7.55i - Canonical Demand + Shared SchedulePlan Authority

Updated: 2026-04-10
Owner: Codex planning / tracker truth
Status: Planned, not implemented

## Purpose

Phase 7.55i captures the remaining architecture work that is not fully covered by 7.55e through 7.55h.

Phases 7.55d through 7.55h align the formulas, whole-day Shift behavior, distribution planning, manager override presentation, and wage/display consistency. They do not fully retire the remaining compatibility bridges.

This phase makes the app-side architecture airtight before Phase 8 live POS/labor adapters and Phase 8R official reservation adapters.

## Correct End State

```text
POS / labor / reservation adapters
-> raw import records
-> canonical operational facts
-> closed ShiftRecords with locked target snapshots
-> rolling 60-day Baseline Context
-> Demand Forecast Context + ActiveTargetProfile + distribution weights
-> SchedulePlan authority
-> Schedule + Shift + Audit
-> Variance + Learn from closed truth
```

The important rule:

```text
ActiveTargetProfile is standards.
Demand Forecast Context is demand.
SchedulePlan combines both.
```

ActiveTargetProfile must not become the place that stores or owns weekly average covers. It contributes target PPA, CPLH, SPLH, wage standards, OPZ bounds, and theoretical standards. Demand Forecast Context owns forecast covers and provenance.

## What 7.55e Through 7.55h Cover

7.55e covers distribution:

- replace hardcoded weekly-to-day weights with data-derived distribution
- replace flat daypart splits with day-specific daypart weights
- keep the plan side top-down from closed-shift history, not live same-day actuals
- replace production runtime reliance on hardcoded operational fixture lists with deterministic mock POS/labor replay into SQLite before live adapters arrive

7.55f covers date truth:

- persist `business_date` on `ShiftRecord`
- use true date-range queries instead of the 8-week approximation
- support Manager Override calendar navigation over the real 60-day window

7.55g covers Schedule/Baseline presentation:

- add Forecasted Sales to Schedule
- remove confusing Baseline/Schedule presentation pieces
- no new authority or persistence changes

7.55h covers wage and decimal consistency:

- show blended wage and wage standards cleanly
- standardize PPA/CPLH display precision
- preserve the rule that blended wage is derived, not a source fact

## What 7.55i Adds

### 1. Canonical Demand Forecast Context

Create a first-class repository-backed demand context instead of reading `BaselineData.historicalWeeklyAvgCovers` directly from screens/services.

Minimum model:

```dart
class DemandForecastContext {
  final String restaurantId;
  final int? historicalTotalCovers;
  final int? historicalWeeklyAvgCovers;
  final double weeksRepresented;
  final ForecastDemandSource coversSource;
  final String builtAt;
}
```

The exact model name can remain `ScheduleForecastDemand` if that is cleaner, but the ownership must be clear: this is baseline-derived demand context, not Schedule-owned widget state.

Required behavior:

- compute weekly forecast covers from eligible closed-shift history
- carry provenance
- represent unavailable/partial history honestly
- avoid demo fallback unless explicitly in demo mode
- never accept manager-entered Schedule forecast covers
- never treat reservation `In the books` as forecast covers

### 2. Shared SchedulePlan Authority

Create one app-side authority that resolves the current SchedulePlan from:

- Demand Forecast Context
- ActiveTargetProfile
- distribution weights

Schedule, Shift, Manager Override preview, and Data Alignment Audit should consume this shared authority instead of independently resolving the same plan from `BaselineData`.

Candidate service shape:

```dart
class SchedulePlanReadService {
  Future<SchedulePlan?> getCurrentWeeklyPlan(String restaurantId);
  Future<ScheduleDayPlan?> getPlanForBusinessDate(
    String restaurantId,
    String businessDate,
  );
}
```

The service can still delegate to `ScheduleForecastDemandResolver` and `SchedulePlanResolver`. The point is not to replace the formulas. The point is to centralize the input tuple and remove screen/service drift.

### 3. Retire Remaining `BaselineData` Compatibility Reads From Production Surfaces

Replace direct `BaselineData` reads in production-facing plan/demand paths.

Target surfaces:

- Schedule Builder plan initialization
- Shift Dashboard plan initialization
- ShiftService dashboard/audit helper path
- Data Alignment Audit plan section
- Manager Override plan preview where possible
- Learn benchmark/target context

Allowed remaining uses:

- fixture seeding
- legacy compatibility code with explicit comments
- tests that intentionally exercise fixture behavior
- Baseline UI while it is still the explicit bridge owner, if replacement is out of scope

The phase should end with a short grep/audit note listing any remaining `BaselineData` imports and why each one is allowed.

### 4. Define WTD Variance Target Semantics

Current completed WeekRecord and closed-shift detail paths use locked historical targets. Live WTD still compares against the current active target profile.

7.55i must decide and document one of these:

1. WTD is a live coaching surface, so it compares against the current active target profile.
2. WTD is closed-truth analysis, so it rolls up the locked targets from the closed shifts already in the week.

Whichever decision is chosen, tests should prove manager override behavior:

- a manager override must not rewrite closed ShiftRecord truth
- if WTD uses current active targets, that behavior must be explicitly labeled as live/current comparison
- if WTD uses locked shift targets, changing Manager Override midweek must not change WTD closed-shift target math

### 5. Migrate Learn Off BaselineData Benchmark Context

Learn already studies pattern records from closed shifts. The remaining gap is that its benchmark/target context still comes from the `BaselineData` bridge.

7.55i should move Learn benchmark context to repository-backed state:

- ActiveTargetProfile for current standards
- persisted baseline selection summary for selected count/source label/range quality
- closed-shift history for repeated patterns

Learn must not depend on hand-authored summaries or mutable fixture globals for production behavior.

### 6. Acceptance Audit

Add a focused audit/test proving these surfaces agree for one restaurant:

- Baseline-derived demand context
- Schedule weekly forecast covers/sales
- Schedule day row selected for today's business date
- Shift forecast covers/sales/FOH/BOH plan values
- Data Alignment Audit plan section
- Manager Override preview impact when target PPA changes

The acceptance proof should show:

- forecast covers remain fixed when target PPA changes
- forecast sales changes when target PPA changes
- BOH plan hours change when target PPA changes through forecast sales
- FOH plan hours change only when forecast covers or target CPLH changes
- actual sales/covers/PPA are never rewritten by target PPA

## Out Of Scope

- Live POS/labor transport
- Official OpenTable or reservation-platform transport
- direct mobile vendor secrets
- multi-location org management
- cross-device sync
- new labor-model formulas
- live daypart-aware Shift coaching, which remains Phase 10.5

## Implementation Guardrails

- Keep `LaborModel` as the formula source.
- Keep `SchedulePlanResolver` as the pure planning math source.
- Prefer a repository/query-service boundary over screen-level reads.
- Preserve nullable/unavailable states instead of fabricating production defaults.
- Do not turn reservation `In the books` into demand forecast truth.
- Do not let target PPA substitute for actual sales in closed/live actual analysis.
- Do not make ActiveTargetProfile carry demand fields.
- Do not delete demo fixtures just to hide architecture gaps; route fixtures through the same canonical path.

## Suggested Prompt Breakdown

### 7.55i.1 - Demand Forecast Context Authority

Add a repository-backed demand context read path from eligible closed-shift history. Replace direct demand reads from `BaselineData.historicalWeeklyAvgCovers` in Schedule and Shift plan initialization where feasible.

### 7.55i.2 - Shared SchedulePlan Read Service

Add `SchedulePlanReadService` or equivalent. Make Schedule, Shift, Data Alignment Audit, and Manager Override preview consume the same plan authority.

### 7.55i.3 - WTD + Learn Canonical Cleanup

Decide WTD target semantics, test manager override behavior, and migrate Learn benchmark context away from `BaselineData` to persisted active target/baseline summary state.

## Done Criteria

- Schedule and Shift no longer independently choose demand inputs.
- The same restaurant/date/profile inputs produce one resolved SchedulePlan path.
- Remaining `BaselineData` usage is audited and either retired or explicitly allowed as fixture/bridge-only.
- Learn no longer uses mutable fixture globals for production benchmark context.
- WTD target semantics are documented and tested.
- Data Alignment Audit can show the full flow:
  - 60-day demand
  - active target profile
  - resolved SchedulePlan
  - Shift actual-vs-plan
  - Variance/Learn closed-truth paths
