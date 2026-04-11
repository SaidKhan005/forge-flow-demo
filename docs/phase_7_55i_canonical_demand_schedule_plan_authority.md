# Phase 7.55i - Canonical Demand + Shared SchedulePlan Authority

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Retired after `7.55i.3a`; `7.55i.4` was intentionally dropped and is not an active lane

## Purpose

Phase 7.55i captured the architecture work that was not fully covered by 7.55e through 7.55h.

Phases 7.55d through 7.55h align the formulas, whole-day Shift behavior, distribution planning, manager override presentation, and wage/display consistency. They do not fully retire the remaining compatibility bridges.

This phase makes the app-side architecture airtight before Phase 8 live POS/labor adapters and Phase 8R official reservation adapters.

## Correct End State

```text
POS / labor / reservation adapters
-> raw import records
-> canonical operational facts
-> 60-Day Benchmark Snapshot
-> TargetCycle + ActiveTargetProfile
-> rolling Demand Forecast Context
-> SchedulePlan authority
-> WeeklyPlanSnapshot
-> Schedule + Shift + Audit
-> Variance + History + Learn
```

The important rule:

```text
ActiveTargetProfile is standards.
Demand Forecast Context is demand.
SchedulePlan combines both.
```

ActiveTargetProfile must not become the place that stores or owns weekly average covers. It contributes target PPA, CPLH, SPLH, wage standards, OPZ bounds, and theoretical standards. Demand Forecast Context owns forecast covers and provenance.

The same separation applies to wages:

```text
ActiveTargetProfile owns the current FOH/BOH wage standards in force.
Wage source authority determines where those standards came from.
Blended wage is always derived, never a source fact.
```

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

What 7.55h does not do:

- create a repository-backed wage source authority
- define how labor integrations replace config/default wage inputs
- provide an app-owned fallback when official labor APIs do not expose enough wage detail

## Verified So Far

### 7.55i.1 - Canonical Demand Forecast Context

Verified through `7.55i.1` and `7.55i.1a`:

- added canonical `DemandForecastContext` model/service/notifier
- anchored demand to mock replay current business date with latest-closed-date fallback
- replaced runtime direct demand reads from `BaselineData.historicalWeeklyAvgCovers` in Schedule, Shift, and Data Alignment Audit
- kept `ScheduleForecastDemandResolver` pure by adding a context-fed path instead of changing formulas
- made Schedule react when demand context loads or changes after provider creation
- removed the Data Alignment Audit's indirect old-demand bridge through `ShiftService.getShiftDashboard()`

### 7.55i.2 - Shared SchedulePlan Authority

Verified through `7.55i.2` and `7.55i.2a`:

- added shared `SchedulePlanReadService`
- moved Schedule, Shift, `ShiftService`, Data Alignment Audit, and Manager Override preview onto the same plan-resolution pipeline
- kept formulas in `ScheduleForecastDemandResolver` and `SchedulePlanResolver`
- removed the remaining direct screen/service resolver bypasses from the main production-facing plan consumers

## Sequencing Note

- The focused pre-`7.55i.3` capability checkpoint is now complete:
  - `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- Use that checkpoint as the architecture input for:
  - `7.55i.3` wage-source authority
  - later `7.55k` service-period and daypart separation work
- The newer planning authority now lives in:
  - `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
  - `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
  - `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Remaining work that `7.55i` did not finish now belongs to:
  - `7.55j.gate`
  - `7.55l`
  - later `7.55k`

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

### 3. Wage Standard Context + Integration-First Fallback

The app needs one repository-backed authority for wage standards.

Current presentation now shows FOH wage, BOH wage, and derived blended wage cleanly, but those values still come from bridge/default paths in some surfaces. Before Phase 8 live labor adapters arrive, 7.55i should define the canonical wage-source seam.

Minimum model shape:

```dart
enum WageStandardSource {
  laborDerivedFromActualDollars,
  laborDerivedFromRatesAndHours,
  appConfiguredGenerator,
  configFallback,
  unavailable,
}

class WageStandardContext {
  final String restaurantId;
  final double? fohWage;
  final double? bohWage;
  final double? referenceBlendedWage;
  final WageStandardSource source;
  final String builtAt;
}
```

Key rules:

- FOH wage standard and BOH wage standard are source-backed standards.
- Blended wage is derived from the wage mix and relevant hours, never stored as canonical source truth.
- When labor integrations expose official wage truth, that source wins.
- When labor integrations do not expose enough wage truth yet, the app can fall back to a restaurant-scoped wage setup/generator without creating a second UI-facing architecture seam.

Fallback plan that can be implemented before live integrations:

- persist a restaurant-scoped wage setup / wage generator profile
- allow role rows such as:
  - role name
  - FOH / BOH / manager classification
  - hourly rate
  - weighting input (hours or setup mix)
- derive:
  - FOH wage standard
  - BOH wage standard
  - reference blended wage

Integration-first precedence waterfall:

1. labor-derived FOH/BOH wage standards from official dollars/hours
2. labor-derived FOH/BOH wage standards from official rates/hours
3. app-configured wage generator/setup
4. config fallback
5. unavailable

Important:

- manager-role handling must be explicit
- if a labor vendor exposes managers separately, the app must decide whether they map to FOH, BOH, or a split rule
- if a vendor exposes only labor dollars and hours, that is still sufficient to derive wage standards

### 4. Retire Remaining `BaselineData` Compatibility Reads From Production Surfaces

Replace direct `BaselineData` reads in production-facing plan/demand paths.

Target surfaces:

- Schedule Builder plan initialization
- Shift Dashboard plan initialization
- ShiftService dashboard/audit helper path
- Data Alignment Audit plan section
- Manager Override plan preview where possible
- Learn benchmark/target context
- Baseline wage presentation where possible

Allowed remaining uses:

- fixture seeding
- legacy compatibility code with explicit comments
- tests that intentionally exercise fixture behavior
- Baseline UI while it is still the explicit bridge owner, if replacement is out of scope

The phase should end with a short grep/audit note listing any remaining `BaselineData` imports and why each one is allowed.

### 5. Original Planned Scope - WTD Variance Target Semantics

Current completed WeekRecord and closed-shift detail paths use locked historical targets. Live WTD still compares against the current active target profile.

This was part of the original `7.55i` planning scope, but it is no longer owned
by `7.55i`.

Later planning must decide and document one of these:

1. WTD is a live coaching surface, so it compares against the current active target profile.
2. WTD is closed-truth analysis, so it rolls up the locked weekly-plan
   comparison truth already in force for the week.

Whichever decision is chosen, tests should prove manager override behavior:

- a manager override must not rewrite closed ShiftRecord truth
- if WTD uses current active targets, that behavior must be explicitly labeled as live/current comparison
- if WTD uses locked weekly-plan truth, changing Manager Override midweek must
  not change WTD closed-shift target math

### 6. Original Planned Scope - Learn Off BaselineData Benchmark Context

Learn already studies pattern records from closed shifts. The remaining gap is
that its benchmark/target context still comes from the `BaselineData` bridge.

This was part of the original `7.55i` planning scope, but it is no longer owned
by `7.55i`.

Later planning should move Learn benchmark context to repository-backed state:

- ActiveTargetProfile for current standards
- persisted baseline selection summary for selected count/source label/range quality
- closed-shift history for repeated patterns

Learn must not depend on hand-authored summaries or mutable fixture globals for production behavior.

### 7. Acceptance Audit

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
- wage standards resolve through one source authority
- target blended wage remains derived from modeled hours plus FOH/BOH wage standards
- if labor wage truth is absent, the app-configured wage generator fallback still feeds the same authority path

## Out Of Scope

- Live POS/labor transport
- Official OpenTable or reservation-platform transport
- direct mobile vendor secrets
- multi-location org management
- cross-device sync
- new labor-model formulas
- live daypart-aware Shift coaching, which remains Phase 10.5
- vendor-specific wage endpoint names before 7.55j / Phase 8 capability work

## Implementation Guardrails

- Keep `LaborModel` as the formula source.
- Keep `SchedulePlanResolver` as the pure planning math source.
- Prefer a repository/query-service boundary over screen-level reads.
- Preserve nullable/unavailable states instead of fabricating production defaults.
- Do not turn reservation `In the books` into demand forecast truth.
- Do not let target PPA substitute for actual sales in closed/live actual analysis.
- Do not make ActiveTargetProfile carry demand fields.
- Do not make blended wage a stored source fact.
- Do not let each screen invent its own wage-source fallback.
- Do not delete demo fixtures just to hide architecture gaps; route fixtures through the same canonical path.

## Suggested Prompt Breakdown

### 7.55i.1 - Demand Forecast Context Authority

Done and verified through `7.55i.1` / `7.55i.1a`: added a repository-backed demand context read path from eligible closed-shift history, replaced the main production-facing direct demand reads from `BaselineData.historicalWeeklyAvgCovers`, made Schedule react to demand-context changes after creation, and removed the Data Alignment Audit's indirect `ShiftService` bridge.

### 7.55i.2 - Shared SchedulePlan Read Service

Done and verified through `7.55i.2` / `7.55i.2a`: one shared SchedulePlan read path now feeds Schedule, Shift, Data Alignment Audit, and Manager Override preview.

### 7.55i.3 - Wage Standard Context + Fallback Generator

Done and verified through `7.55i.3` / `7.55i.3a`: wage standards now flow through one repository-backed authority with explicit fallback behavior and wage-aware bootstrap paths.

### 7.55i.4 - Dropped

This slice is intentionally not part of the active roadmap anymore. Do not revive it under `7.55i`. Any future WTD, Variance, or Learn semantics work should be planned explicitly under later lanes such as `7.55k` or a dedicated follow-up.

## Delivered Before Retirement

- Schedule and Shift no longer independently choose demand inputs.
- The same restaurant/date/profile inputs produce one resolved SchedulePlan path.
- Wage standards flow through one repository-backed authority with explicit provenance and fallback behavior.
- Remaining `BaselineData` usage is audited and either retired or explicitly allowed as fixture/bridge-only.
- Learn benchmark-context migration is explicitly deferred beyond `7.55i`.
- WTD semantics are explicitly not owned by `7.55i`.
- final `TargetCycle` / `WeeklyPlanSnapshot` implementation is explicitly
  deferred beyond `7.55i`.
- Data Alignment Audit can show the full flow:
  - 60-day demand
  - active target profile
  - resolved SchedulePlan
  - Shift actual-vs-plan
  - downstream Variance/Learn follow-up remains separate
