# Phase 7.55p.3 — Dollar Impact Accumulation Model
Status: Landed

## Goal
Replace the run-rate Dollar Impact card with a closed-truth accumulation
model so Variance explains impact as target-vs-actual accumulation through
the latest closed business date, not as weekly extrapolation.

## Scope
- In: This Week Dollar Impact card — week, month, 60-day, and annualized
  accumulation windows; card copy cleanup; compat-path accumulation parity
- Out: Full Week table, History cards, primary-driver logic, WeekRecord
  historical dollar-gap semantics, notifications, freshness, Shift polish

## What Changed

### WeekData accumulation fields
`WeekData` gains optional `monthDollarImpact` and `sixtyDayDollarImpact`
fields populated from closed-shift date-range queries. New
`annualizedDollarImpact` getter derives from 60-day:
`sixtyDayDollarImpact * (365 / 60)`. Returns null when 60-day data is
unavailable — no fallback to weekly × 52.

Existing `dollarGap` and `dollarGapAnnualized` are unchanged for
downstream compatibility.

### ShiftService accumulation logic
Both `_buildLockedWeekToDate()` (locked path) and `getWeekToDate()`
(compat fallback path) compute month and 60-day dollar impact windows
after determining the latest closed business date. Each window uses
`getClosedShiftsInDateRange()` and accumulates dollar impact per-shift
using each shift's own locked targets:

```
per-shift impact = actual labor − theoretical labor
  actual labor      = fohLaborDollar + bohLaborDollar
  theoretical labor = modelFohHours(covers, targetCPLH) × targetFohWage
                    + modelBohHoursFromSales(actualSales, targetSPLH) × targetBohWage
```

Month window: first of current calendar month through latest closed date.
60-day window: (latest closed date − 60 days) through latest closed date.

Compat path: derives `maxClosedDate` from `businessDate` on the closed
rows. When business dates are unavailable, month/60-day stay null and
the card omits those rows.

### Annualized formula
```
annualized = sixtyDayDollarImpact × (365 / 60)
```
Not `weeklyGap × 52`. Null when 60-day data is unavailable.

### Dollar Impact card copy
- Removed `covers WTD` and `run rate`
- Card now shows week / month / 60-day / annualized impact rows
- Each tier conditionally rendered — only appears when data exists
- Context line: `Through {day}` — the latest closed business date
- Each row independently signed (+/−) and colored

## Touched Writers

| File | What changed |
|---|---|
| `lib/models/week_data.dart` | Added `monthDollarImpact`, `sixtyDayDollarImpact` fields; `annualizedDollarImpact` getter (nullable, no fallback) |
| `lib/data/shift_service.dart` | Both `_buildLockedWeekToDate()` and `getWeekToDate()` compute month/60-day windows; `_accumulateDollarImpact()` helper |
| `lib/screens/variance_report.dart` | `_DollarImpactCard` redesigned for 4-tier accumulation; all tiers nullable/conditional |
| `test/wtd_variance_logic_test.dart` | Accumulation model tests including null-annualized behavior |
| `test/variance_visual_widget_test.dart` | Card copy tests |

## Unchanged

- `WeekData.dollarGap` / `dollarGapAnnualized` — preserved for compatibility
- `WeekRecord.dollarGap` / `dollarGapAnnualized` — History semantics unchanged
- `LaborModel` — no formula changes
- Primary-driver logic — untouched
- Full Week table — untouched

## Follow-up Gaps
- Early-data honesty: when 60-day window has fewer than 60 days of
  closed shifts, annualized still extrapolates from whatever data exists.
  A minimum-data threshold could be a product decision.
- Compat path: if closed shifts lack `businessDate` fields, month/60-day
  stay null and the card omits those rows. This is honest — no false
  accumulation from incomplete data.
