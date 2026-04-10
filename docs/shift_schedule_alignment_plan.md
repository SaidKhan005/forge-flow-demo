# Shift ↔ Schedule Alignment — Full Map

Updated: 2026-04-09
Status: Planned, not yet implemented

## Context

The demo seed simulates a live POS/labor integration. The user wants all screens to display as though a live integration is running, with traceable, consistent numbers. Four visible inconsistencies exist between Shift and Schedule. The root cause is that the historical data feeding the Baseline/Schedule demand resolver doesn't produce a realistic weekly average, which cascades into cover count, sales, and hour mismatches downstream.

---

## Root Cause: `historicalWeeklyAvgCovers` Misalignment

```
historicalWeeklyAvgCovers = historicalTotalCoversTracked / (60 / 7)
```

**Static fallback** (`_seedRecords`, 55 records): 9,138 covers / 8.57 = **1,066**
**Runtime** (after primeManagerOverride loads ALL weeks from SQLite): ~14,000+ covers / 8.57 = **~1,630+** (inflated)

Neither produces the expected ~1,200. The 60/7 divisor assumes exactly 60 days of data, but:
- Static fallback: 55 records represent a curated sample, not complete weeks → deflated
- Runtime: loads ALL 12 weeks (~84 days) of data but divides by 8.57 → inflated

**In production**: Phase 8's 60-day query filter would naturally bound this. The demo path doesn't have that filter.

### Fix: Scope `historicalContextRecords` to the 60-day window at load time

In `BaselineManagerService.primeManagerOverride()`, filter candidate shifts to only include week IDs within the 60-day window (W05–W12). This is not a "logic change" to `BaselineData` — it's the data load boundary that Phase 8 would enforce via a SQL `WHERE` clause.

**After fix**: W05–W12 expanded shifts total ~9,612 covers / 8.57 weeks = **~1,121 weekly avg**. This is close to 1,200 (slight variance because W12=1152 and W11=1260).

With ~1,121 weekly covers, Schedule would compute:
- Friday total: round(220 × 1121/1200) = **205 covers**
- Friday dinner (40%): **82 covers**
- Friday dinner sales: 82 × 41.79 = **$3,427**
- Friday dinner model FOH: round(82/4.58) = **18 hours**
- Friday dinner model BOH: round(3427/180.07) = **19 hours**

---

## Issue 1: CPLH Rounding Mismatch (Independent Fix)

**Problem**: ZoneStatusCard OPZ gauge uses `.toStringAsFixed(2)`, CPLH InputMetricCard uses `.toStringAsFixed(1)`.

**Fix**: Standardize to `.toStringAsFixed(1)`.

**File**: `lib/widgets/zone_status_card.dart`
- Line 60: current CPLH display
- Line 402: OPZ floor label
- Line 420: target label
- Line 441: ceiling label

---

## Issue 2+3: Forecast Covers / Sales / Hours Mismatch

**Problem**: `ShiftSnapshot.shiftForecastCovers = 220` is hardcoded. Schedule resolves ~82 Friday dinner covers (after root cause fix). Sales and model hours diverge accordingly.

**Fix**: After the root cause fix produces a realistic weekly average, update `ShiftSnapshot` fixture values to derive from the same demand resolution.

**File**: `lib/data/legacy_fixture_data.dart` — `ShiftSnapshot` class

Update `shiftForecastCovers` to match Schedule's Friday dinner covers (~82). Then:
- `scheduledFohHours` / `scheduledBohHours`: realistic scheduling values for ~82 covers (slightly over model to show coaching overschedule narrative, e.g., model=18 → scheduled=20)
- `actualCPLH = actualCovers / scheduledFohHours`
- `actualSPLH = (actualCovers × actualPPA) / scheduledBohHours`
- `modelFohHours` / `modelBohHours`: from `LaborModel.modelFohHours(forecastCovers, targetCPLH)`
- `actualCovers`: scale proportionally to preserve "covers light" narrative (e.g., ~52 covers = 63.6% of 82 forecast)

**SQLite seed** in `sqlite_database.dart` reads from `ShiftSnapshot` constants → auto-updates.

---

## Issue 4: Blended Wage — No Real Target (Independent Fix)

**Problem**: BLENDED WAGE card displays `snapshot.blendedWage` as both current AND target.

**Architecture**: 
- `ActiveTargetProfile` has `fohWage` (16.50) and `bohWage` (21.35) — target wage rates
- `OpenShiftSnapshot.blendedWage` = actual total labor dollars / actual total hours — shift-level actual
- Target blended wage must be computed from model hour mix
- `WeekToDate.theoreticalBlendedWage = 19.02` already does this at weekly level: `(345×16.50 + 373×21.35) / 718`

**Fix**: Compute `targetBlendedWage` from model hour mix:

```dart
final modelFoh = LaborModel.modelFohHours(snapshot.forecastCovers, profile.targetCPLH);
final modelBoh = LaborModel.modelBohHours(snapshot.forecastCovers, profile.targetPPA, profile.targetSPLH);
final totalModelHours = modelFoh + modelBoh;
final targetBlendedWage = totalModelHours > 0
    ? (modelFoh * profile.fohWage + modelBoh * profile.bohWage) / totalModelHours
    : 0.0;
```

Display real delta and status (higher wage = unfavorable).

**File**: `lib/models/shift_dashboard_read_model.dart` — `_buildMetricCards` (lines 293–302)

**Integration readiness**: In Phase 8, `snapshot.blendedWage` comes from the labor adapter (actual labor $ / actual hours). `targetBlendedWage` stays computed from model hours + target wages. No LaborModel changes needed.

---

## User Insight on Wages

> "I THINK THIS IS A FULL MAP NEEDED, WE'LL NEED WAGES FROM LABOR MANAGEMENT THEN DO CALCULATIONS"

Confirmed: In a live integration, wages flow as follows:
- **Actual labor dollars**: From POS/labor system → `ShiftRecord.storedFohLaborDollar` / `storedBohLaborDollar`
- **Blended wage (actual)**: `totalLaborDollar / totalHours` — a derived metric, not stored directly
- **Target FOH/BOH wages**: From `ActiveTargetProfile.fohWage` / `bohWage` — currently from `MeridianConfig`, eventually configurable per restaurant
- **Target blended wage**: Computed from model hour mix at target wages (as above)
- **Wage variance**: `actualBlendedWage - targetBlendedWage`

Currently `MeridianConfig.fohWage = 16.50` and `MeridianConfig.bohWage = 21.35` are hardcoded. In Phase 8/9 these become restaurant-specific configuration. The formula layer (`LaborModel`) doesn't change — only the wage inputs change.

---

## Implementation Order

1. **Root cause**: Filter `primeManagerOverride()` to 60-day window weeks only
   - `lib/data/baseline_manager_service.dart`
2. **Issue 1**: CPLH rounding standardization
   - `lib/widgets/zone_status_card.dart`
3. **Issue 4**: Blended wage target computation
   - `lib/models/shift_dashboard_read_model.dart`
4. **Issue 2+3**: Update `ShiftSnapshot` fixture values to align with resolved demand
   - `lib/data/legacy_fixture_data.dart`
5. **Verify**: Run tests, reseed, check all 4 screens

---

## Files Modified

| File | Change |
|------|--------|
| `lib/data/baseline_manager_service.dart` | Filter 60-day window in primeManagerOverride |
| `lib/widgets/zone_status_card.dart` | CPLH rounding: 2 decimals → 1 decimal |
| `lib/models/shift_dashboard_read_model.dart` | Compute real targetBlendedWage |
| `lib/data/legacy_fixture_data.dart` | Update ShiftSnapshot fixture constants |

---

## Verification

1. `flutter analyze` — clean
2. `flutter test` — full suite green
3. Reseed via Settings → Load Demo Data
4. Baseline: weekly avg covers in ~1,100–1,200 range
5. Schedule: Friday dinner covers matches Shift forecast
6. Shift: forecast sales = forecastCovers × targetPPA matches Schedule dinner sales
7. Shift: BLENDED WAGE shows real target, delta, and status
8. Shift: CPLH gauge and card use same decimal precision
9. Settings audit panel: cross-check all values
