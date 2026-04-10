# Phase 7.55c - Schedule Forecast Demand Source Model

Updated: 2026-04-09
Owner: Codex planning / tracker truth
Status: 7.55c.1 planning complete; 7.55c.2 app-side model and Schedule wiring complete; live POS transport not implemented

## Purpose

Clarify and then implement the Schedule demand-source architecture before live integrations arrive.

Phase 7.55b corrected the visible Schedule table so FOH is cover-driven and BOH is forecast-sales-driven. Phase 7.55c goes one layer deeper and defines where the forecast demand numbers come from.

## Key Product Truth

```text
POS (60-day closed shifts) → total covers → ÷ (60/7) → weekly avg covers (FORECAST)
weekly avg covers × target PPA → forecasted sales (ALWAYS DERIVED)
```

```text
Baseline supplies standards (targets).
POS 60-day history supplies forecast demand (covers).
Sales is always derived from covers × PPA.
LaborModel combines standards and demand.
```

## Architecture

Schedule needs two kinds of input:

```text
1. Demand forecast (covers and sales)
2. Active target profile (CPLH, SPLH, PPA, wages)
```

Demand forecast answers: "How much business do we expect?"
Active target profile answers: "What standards should we plan against?"

### Demand Forecast Flow

```text
POS / labor system (60-day closed shifts)
→ total covers tracked
→ ÷ (60/7 weeks)
→ weekly average covers = FORECASTED COVERS

forecasted covers × target PPA = FORECASTED SALES (always derived, never direct input)
```

### Formula Layer

```text
FOH required hours = forecasted covers ÷ target CPLH
BOH required hours = forecasted sales ÷ target SPLH
```

### Source Map

```text
POS closed shifts (60 days)
→ historicalWeeklyAvgCovers
→ ScheduleForecastDemand.forecastCovers
→ ScheduleForecastDemand.forecastSales (= covers × targetPPA)

Closed historical shifts
→ Baseline selection
→ ActiveTargetProfile (CPLH, SPLH, PPA, wages, labor %)

ScheduleForecastDemand + ActiveTargetProfile
→ LaborModel
→ required FOH hours and required BOH hours
```

## What Changed From Original 7.55c Plan

The original plan assumed vendors would provide forecast sales or forecast covers as direct inputs. This was wrong. The correct architecture:

1. **Covers always come from POS 60-day history** — your own operation averaged across 60 days of real trading
2. **Sales are always derived** as covers × target PPA — never a direct vendor input
3. **No vendor forecast inputs** for covers or sales
4. **No manager editing** of forecast values on Schedule
5. **Manager influence is limited to Baseline target profile override** — adjusting standards (CPLH, SPLH, PPA, wages), not demand

### Removed Concepts

- `ForecastDemandSource.vendorForecast` — removed. POS provides raw shift data, the app derives the forecast.
- `ForecastDemandSource.appDerivedFromSalesAndPpa` — removed. Covers are never derived from sales. Sales is always derived from covers.
- Explicit `forecastSales` / `forecastCovers` resolver parameters — removed. The resolver only accepts `historicalWeeklyAvgCovers`.
- Manager-entered forecast covers/sales — removed. Manager influence is Baseline only.

## Current Implementation

### Domain Model

```dart
enum ForecastDemandSource {
  appDerivedFromHistoricalAverage,        // POS 60-day weekly avg (primary)
  appDerivedFromCoversAndPpa,             // sales = covers × PPA (always)
  appDerivedFromReservationAndWalkInModel, // Phase 8R future
  demoFallback,                           // demo mode only
  unavailable,                            // no data available
}
```

```dart
class ScheduleForecastDemand {
  final double? forecastSales;
  final int? forecastCovers;
  final ForecastDemandSource salesSource;
  final ForecastDemandSource coversSource;
}
```

### Resolver Waterfall

```dart
ScheduleForecastDemandResolver.resolve(
  targetPPA: profile.targetPPA,
  historicalWeeklyAvgCovers: baselineData.historicalWeeklyAvgCovers,
  demoMode: isDemoMode,
)
```

1. If `historicalWeeklyAvgCovers` exists and > 0:
   - covers = historicalWeeklyAvgCovers
   - sales = covers × targetPPA
   - coversSource = `appDerivedFromHistoricalAverage`
   - salesSource = `appDerivedFromCoversAndPpa`

2. If demo mode and no historical data:
   - covers = 1200 (demo fallback constant)
   - sales = covers × targetPPA
   - coversSource = `demoFallback`

3. Otherwise: unavailable

### Schedule Display

Schedule forecast is read-only. No editable input. Displays:

```text
Forecast source: 60-day weekly average
```

The Schedule table shows:

```text
DAY | COVERS | SALES | FOH | BOH
```

All values are system-resolved from the demand forecast + target profile.

## Integration Guardrails

Allowed:
- POS / labor system supplies historical closed shifts
- App derives forecast covers from 60-day POS history
- App derives forecast sales from covers × target PPA
- Manager influences standards via Baseline target profile override

Not allowed:
- Vendor directly supplies forecast covers or forecast sales
- Manager edits forecast covers or sales on Schedule
- Baseline silently overwrites a live forecast
- Reservation `in the books` covers become forecast covers
- Demo `1200` remains the invisible default in non-demo/live contexts

## Relationship To Baseline

Baseline provides:
- target CPLH, target SPLH, target PPA
- wage targets (FOH, BOH)
- OPZ range
- historical weekly average covers as the forecast source

Baseline is the owner of both standards AND the 60-day historical context that produces the forecast. This is correct: the forecast IS the 60-day average of your own POS data.

## Implementation Files

- `lib/domain/models/schedule_forecast_demand.dart` — model + enum
- `lib/domain/services/schedule_forecast_demand_resolver.dart` — resolver
- `lib/screens/schedule_builder.dart` — notifier + display
- `test/schedule_forecast_demand_resolver_test.dart` — 8 focused tests

## Example Calculation (Jim Taylor)

Your FOH inputs:
```text
Forecasted Covers  →  1,200  (10,286 total ÷ 8.57 weeks)
Target CPLH        →  4.5    (from your best sustainable daypart range)
PPA                →  $42    (your 60-day average spend per guest)
FOH Wage           →  $16.50/hr
```

Your BOH inputs:
```text
Target SPLH        →  $180   (from your best sustainable daypart range)
BOH Wage           →  $21.35/hr
```

```text
Step 1: Required FOH Hours = Forecasted Covers ÷ Target CPLH
        1,200 ÷ 4.5 = 267 FOH hours

Step 2: Required BOH Hours = Forecasted Sales ÷ Target SPLH
        Forecasted Sales = 1,200 × $42 = $50,400
        $50,400 ÷ $180 = 280 BOH hours
```

## Non-Goals

Do not implement in this phase:
- live POS integration
- live labor integration
- live reservation integration
- vendor-provided forecast transport
- cross-device forecast sync
- advanced reservation plus walk-in forecast modeling
- machine-learning forecasts
- new target math
- UI redesign beyond small forecast-source clarity

## Tracker Truth

Phase 7.55c makes the app-side demand-source architecture explicit:
- Covers always from POS 60-day history
- Sales always derived from covers × PPA
- No vendor forecast inputs, no manager editing on Schedule
- Manager influence limited to Baseline target profile override
- Phase 8 replaces the transport (fixture → live POS) but not the derivation logic
