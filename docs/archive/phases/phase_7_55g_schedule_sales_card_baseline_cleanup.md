# Phase 7.55g — Forecasted Sales Card on Schedule + Baseline Cleanup

## Context

Three UI changes:
1. **Add Forecasted Sales card** at top of Schedule Builder (alongside Forecasted Covers)
2. **Remove Weekly Avg Covers card** from Baseline Tracker summary
3. **Remove Forecast Source label** from the Forecasted Covers card on Schedule

---

## Research Findings

### Schedule Builder Top Section (current layout)

**File**: `lib/screens/schedule_builder.dart`

```
┌─────────────────────────────┐
│  Next Week                  │  (display20 heading, line 297)
│  Schedule to Covers         │  (mono10 subtitle, line 304)
├─────────────────────────────┤
│  FORECASTED COVERS - NEXT WEEK  │  _ForecastDisplay (lines 343-378)
│  1,200                           │  notifier.weeklyCovers
│  Forecast source: 60-day...      │  notifier.forecastSourceLabel ← REMOVE
├─────┬─────┬─────┬───────────┤
│ REQ │ REQ │LAB %│ LABOR $   │  _DerivedSummaryCards (lines 380-439)
│ FOH │ BOH │20.5%│ $4,826    │  4-card row
└─────┴─────┴─────┴───────────┘
```

**Data already available on notifier** (line 133):
```dart
double get forecastedSales => _plan?.forecastSales ?? 0;  // e.g., $50,148
```

### Baseline Tracker Summary Cards (current layout)

**File**: `lib/screens/baseline_tracker.dart` (lines 149-197)

```
┌──────────────────┬─────────────────┐
│ TOTAL COVERS     │ WEEKLY AVG      │  _SummaryCards widget
│ LAST 60 DAYS     │ COVERS          │  ← REMOVE right card
│ 10,284           │ 1,200           │
└──────────────────┴─────────────────┘
```

`_SummaryCards` builds from a 2-element list. Removing "WEEKLY AVG COVERS" leaves "TOTAL COVERS LAST 60 DAYS" as a single full-width card.

### Forecast Source Label

**File**: `lib/screens/schedule_builder.dart` (lines 370-373)
```dart
Text(
  'Forecast source: ${notifier.forecastSourceLabel}',
  style: AppTextStyles.mono7(color: AppColors.textMuted),
),
```

Source comes from `SchedulePlan.coversSourceLabel` which maps the `ForecastDemandSource` enum to human-readable text. The label and its getter remain in the model (other consumers may use it), but the UI line is removed.

---

## Changes

### 1. Add Forecasted Sales card to Schedule top section

**File**: `lib/screens/schedule_builder.dart`

Add a `_ForecastSalesDisplay` widget after `_ForecastDisplay` (after line 310). Same styling pattern as `_ForecastDisplay`:

```dart
class _ForecastSalesDisplay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<ScheduleForecastNotifier>();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('FORECASTED SALES - NEXT WEEK', style: AppTextStyles.mono7()),
          const SizedBox(height: 8),
          Text('\$${Fmt.dollars(notifier.forecastedSales)}',
              style: AppTextStyles.mono22()),
        ],
      ),
    );
  }
}
```

**Layout option**: Side-by-side with Forecasted Covers in an `IntrinsicHeight` + `Row` (matching the pattern used for summary cards), or stacked below it. Side-by-side is more compact.

### 2. Remove Forecast Source from Forecasted Covers card

**File**: `lib/screens/schedule_builder.dart` (lines 369-373)

Remove:
```dart
const SizedBox(height: 4),
Text(
  'Forecast source: ${notifier.forecastSourceLabel}',
  style: AppTextStyles.mono7(color: AppColors.textMuted),
),
```

### 3. Remove Weekly Avg Covers from Baseline Tracker

**File**: `lib/screens/baseline_tracker.dart` (lines 152-155)

Change the cards list from 2 items to 1:
```dart
final cards = [
  ('TOTAL COVERS LAST 60 DAYS', BaselineData.historicalTotalCoversTracked.toString()),
];
```

The single card expands to full width via the existing `Expanded` wrapper.

---

## Key Files

| # | File | Change |
|---|------|--------|
| 1 | `lib/screens/schedule_builder.dart` | Add `_ForecastSalesDisplay`, remove forecast source text |
| 2 | `lib/screens/baseline_tracker.dart` | Remove "WEEKLY AVG COVERS" from `_SummaryCards` |
| 3 | Tests | Update any snapshot/widget tests that assert on removed elements |

---

## Data Flow (no new wiring needed)

```
SchedulePlanResolver → SchedulePlan.forecastSales
  → ScheduleForecastNotifier.forecastedSales (getter, line 133)
  → _ForecastSalesDisplay reads via context.watch
```

`forecastedSales = forecastCovers × targetPPA` — already computed in the plan, already exposed on the notifier. No new service or model changes.
