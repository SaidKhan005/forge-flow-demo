# Phase 7.55h — Blended Wage on Baseline + PPA/CPLH Decimal Consistency

## Context

Three issues:
1. **Baseline has no blended wage** — the Baseline Tracker shows CPLH, SPLH, PPA, Labor %, OPZ bounds but no wage data at all
2. **PPA needs 2dp everywhere** — currently 0dp on Baseline targets card and daypart table
3. **CPLH needs 2dp everywhere** — currently 1dp on Shift cards, Baseline targets card, and daypart table. The CPLH range bar already uses 2dp (line 389 of baseline_tracker.dart) — that's the reference standard

---

## Research Findings

### Blended Wage Architecture

**Target blended wage** is NOT a single stored field. It's computed from the FOH/BOH hour mix:
```
targetBlendedWage = (planFohHours × fohWage + planBohHours × bohWage) / totalModelHours
```

**Source**: `shift_dashboard_read_model.dart` lines 358-363:
```dart
final wageTotalModelHours = planFohHours + planBohHours;
final targetBlendedWage = wageTotalModelHours > 0
    ? (planFohHours * profile.fohWage + planBohHours * profile.bohWage) /
        wageTotalModelHours
    : 0.0;
```

**Actual/live blended wage** is computed from daypart snapshots weighted by actual hours:
```dart
// shift_dashboard_read_model.dart lines 169-173
final actualWageDollars = actualSnapshots.fold<double>(
    0, (s, r) => s + r.blendedWage * (r.scheduledFohHours + r.scheduledBohHours));
final actualTotalHours = actFoh + actBoh;
final avgBlendedWage = actualTotalHours > 0 ? actualWageDollars / actualTotalHours : 0.0;
```

**Live integration (Phase 8)**: Labor management system provides `actualFohLaborDollars` + `actualBohLaborDollars` via `ClosedShiftInput`. `ShiftFactBuilder` (lines 25-30) uses actual labor dollars when available, falls back to `hours × targetWage`. Blended wage is always derived: `totalLaborDollars / totalHours`.

**Wage rates on ActiveTargetProfile**: `fohWage: 16.50`, `bohWage: 21.35` (from MeridianConfig defaults, will be restaurant-configured in Phase 9).

### Current Decimal Place Inconsistencies

| Location | PPA dp | CPLH dp |
|----------|--------|---------|
| **Shift Dashboard cards** | 2 ✅ | 1 ❌ |
| **Baseline — CPLH range bar target** | — | 2 ✅ (reference) |
| **Baseline — targets card** | 0 ❌ | 1 ❌ |
| **Baseline — daypart table** | 0 ❌ | 1 ❌ |
| **Variance report** | 2 ✅ | 2 ✅ |
| **Week detail** | 2 ✅ | 2 ✅ |

---

## Changes

### 1. Baseline Tracker — Add Blended Wage to Targets Card

**File**: `lib/screens/baseline_tracker.dart` → `_BaselineTargetsCard` (line 475)

The target blended wage can be computed from the same data the targets card already has:
```dart
final targetBlendedWage = () {
  final foh = LaborModel.modelFohHours(
      BaselineData.historicalWeeklyAvgCovers, BaselineData.derivedTargetCPLH);
  final boh = LaborModel.modelBohHoursFromSales(
      BaselineData.historicalWeeklyAvgCovers * BaselineData.derivedTargetPPA,
      BaselineData.derivedTargetSPLH);
  final total = foh + boh;
  return total > 0
      ? (foh * MeridianConfig.fohWage + boh * MeridianConfig.bohWage) / total
      : 0.0;
}();
```

Add to the targets list:
```dart
('BLENDED WAGE', '\$${targetBlendedWage.toStringAsFixed(2)}'),
```

Also show FOH and BOH wage rates:
```dart
('FOH WAGE', '\$${MeridianConfig.fohWage.toStringAsFixed(2)}'),
('BOH WAGE', '\$${MeridianConfig.bohWage.toStringAsFixed(2)}'),
```

### 2. PPA → 2 decimal places

**Baseline targets card** (`baseline_tracker.dart` line 478):
```dart
// Before:
('PPA', '\$${BaselineData.derivedTargetPPA.toStringAsFixed(0)}'),
// After:
('PPA', '\$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}'),
```

**Daypart table** (`daypart_table.dart` line 44):
```dart
// Before:
'\$${stat.avgPPA.toStringAsFixed(0)}',
// After:
'\$${stat.avgPPA.toStringAsFixed(2)}',
```

### 3. CPLH → 2 decimal places

**Shift dashboard cards** (`shift_dashboard_read_model.dart` lines 396-398):
```dart
// Before:
currentFormatted: actualCPLH.toStringAsFixed(1),
targetFormatted: 'Target ${profile.targetCPLH.toStringAsFixed(1)}',
// ...cplhDelta.toStringAsFixed(1)
// After:
currentFormatted: actualCPLH.toStringAsFixed(2),
targetFormatted: 'Target ${profile.targetCPLH.toStringAsFixed(2)}',
// ...cplhDelta.toStringAsFixed(2)
```

**Baseline targets card** (`baseline_tracker.dart` line 476):
```dart
// Before:
('CPLH', BaselineData.derivedTargetCPLH.toStringAsFixed(1)),
// After:
('CPLH', BaselineData.derivedTargetCPLH.toStringAsFixed(2)),
```

**Daypart table** (`daypart_table.dart` line 42):
```dart
// Before:
stat.avgCPLH.toStringAsFixed(1),
// After:
stat.avgCPLH.toStringAsFixed(2),
```

**OPZ Floor/Ceiling** (`baseline_tracker.dart` lines 483-484):
```dart
// Before:
('OPZ FLOOR', BaselineData.opzFloorCPLH.toStringAsFixed(1)),
('OPZ CEILING', BaselineData.opzCeilingCPLH.toStringAsFixed(1)),
// After:
('OPZ FLOOR', BaselineData.opzFloorCPLH.toStringAsFixed(2)),
('OPZ CEILING', BaselineData.opzCeilingCPLH.toStringAsFixed(2)),
```

---

## Key Files

| # | File | Change |
|---|------|--------|
| 1 | `lib/screens/baseline_tracker.dart` | Add blended wage + FOH/BOH wage to targets card; fix PPA/CPLH/OPZ dp |
| 2 | `lib/widgets/daypart_table.dart` | Fix PPA (0→2dp) and CPLH (1→2dp) |
| 3 | `lib/models/shift_dashboard_read_model.dart` | Fix CPLH card formatting (1→2dp) |
| 4 | Tests | Update any assertions on formatted strings |

---

## Blended Wage — Live Integration Path

```
Phase 8 POS/Labor adapter
  → ClosedShiftInput.actualFohLaborDollars, actualBohLaborDollars
  → ShiftFactBuilder resolves (actual dollars if present, else hours × targetWage)
  → ShiftRecord.blendedWage = totalLaborDollar / totalHours (computed getter)
  → OpenShiftSnapshot.blendedWage (for live dashboard)
  → buildWholeDay() aggregates weighted by actual hours
  → Metric card shows actual vs target
```

Target wage rates (`fohWage`, `bohWage`) stay on `ActiveTargetProfile`. Actual labor dollars come from the labor system. Blended wage is always derived, never stored as a source fact.
