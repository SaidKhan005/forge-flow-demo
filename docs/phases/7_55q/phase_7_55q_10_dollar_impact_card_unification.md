# Phase 7.55q.10 - Dollar Impact Card Unification (Frozen-At-Close Parity)

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Close the divergence between the **current-week Variance** Dollar Impact
card and the **closed-week Week Detail** Dollar Impact card so that the
moment a week's 14th shift closes and the week rolls to history, the
Dollar Impact view stays identical — same 4 rows, same numbers, frozen.

Aligns Dollar Impact with the same "preserve closed truth in the context
that was in force at close" guarantee Phase 7.55q.5 already gave to plan
hours (`lockedRequiredFohHours` / `lockedRequiredBohHours`).

## Why

User intent: *all 14 shifts close → week rolls to Week Detail, and what
was on screen at the moment of close stays on screen forever.* That's
correct per Rule 11 of `phase_7_55_architecture_contract.md` (history is
closed truth with preserved provenance), but Dollar Impact never got
that treatment.

Before this slice:

- `_DollarImpactCard` in `lib/screens/variance_report.dart` (live WTD)
  rendered up to 4 conditional rows (Week / Month / 60-day / Annualized)
  with a "Through {lastClosedDay}" footer.
- `_DollarImpactCard` in `lib/screens/week_detail_screen.dart` (history)
  was a **separate copy** of the widget that hard-coded 2 rows
  (Week / Annualized) with a static "At $3M annual sales. One location."
  footer. The annualized formula also diverged (`(365/60)` trend vs
  `dollarGap × 52`), so the same week could show two different annualized
  numbers depending on which screen you were on.
- `WeekRecord` carried no `monthDollarImpact`, `sixtyDayDollarImpact`, or
  `closedAt` — so even if Week Detail wanted to render 4 rows, the data
  wasn't there.
- The duplicated widget code is what allowed the cards to drift in the
  first place, and is what would let them drift again.

## Scope

In:

- V22 schema migration: three nullable additive columns on `week_records`
  (`month_dollar_impact REAL`, `sixty_day_dollar_impact REAL`,
  `closed_at TEXT`).
- `WeekRecord` model: three new optional fields + `frozenAnnualizedImpact`
  getter mirroring `WeekData.annualizedDollarImpact`.
- `ShiftService._buildWeekRecord`: capture month + 60-day windows at
  close via the same `getClosedShiftsInDateRange` + `_accumulateDollarImpact`
  seam the live WTD path uses; persist `closedAt` from the latest
  closed business date.
- New shared widget `lib/widgets/dollar_impact_card.dart` consumed by
  both screens (single source of truth for layout, rows, dividers,
  footer).
- `lib/screens/variance_report.dart` + `lib/screens/week_detail_screen.dart`:
  delete local widget copies, call shared widget, add
  `_SectionLabel('DOLLAR IMPACT')` outside the card on Week Detail to
  match Variance's section-label pattern.
- `_fmtClosedAt('YYYY-MM-DD') → 'Mon DD'` helper (private to
  `week_detail_screen.dart`).
- Tests: extend `test/shift_service_close_shift_test.dart`; new
  `test/dollar_impact_card_widget_test.dart`; extend
  `test/variance_history_widget_test.dart` for the 4-row + new-footer path.

Out:

- `WeekData.annualizedDollarImpact` and the live WTD computation pipeline
  stay untouched. The variance card already shows the trend number; we
  are only making sure the same number is **frozen** at close.
- `LaborModel` — no shared `(365.0/60)` constant extracted in this
  slice. Two callsites is fine; revisit when a third appears.
- `lib/widgets/variance_banner.dart` and any export/print/share path.
- `shift_records` schema — `closedAt` derives from already-present shift
  business dates; no new shift columns.
- Tracker / commit / repo hygiene — none in this run.

## Runtime Seam (before / after)

Before close (current):

```
ShiftService.closeShift(14th shift)
  → _buildWeekRecord(closedShifts)
      → WeekRecord(dollarGap, lockedRequiredFohHours, ...)
            [no month/60-day/closedAt fields]
```

After close (V22+):

```
ShiftService.closeShift(14th shift)
  → _buildWeekRecord(closedShifts)
      → getClosedShiftsInDateRange(monthStart..maxClosedDate)   ← same seam as live WTD
      → getClosedShiftsInDateRange(sixtyDayStart..maxClosedDate)
      → _accumulateDollarImpact(...) [reuses existing static helper]
      → WeekRecord(
           dollarGap,
           monthDollarImpact,     ← frozen at close
           sixtyDayDollarImpact,  ← frozen at close
           closedAt,              ← last shift's businessDate
           lockedRequiredFohHours,
           ...)
```

Render:

```
Variance card (live):    DollarImpactCard(week, month, 60d, annualized,
                          footer="Through {lastClosedDay}")

Week Detail (closed):    DollarImpactCard(week, month, 60d, annualized,
                          footer="As of close, {closedAt}")
                          [legacy rows: month/60d/closedAt null →
                           2-row + boilerplate footer fallback]
```

## Files Touched

- `lib/infrastructure/persistence/sqlite/sqlite_database.dart`
  (`schemaVersion` → 22; new `_migrateToV22` + 3 nullable columns
  added to `CREATE TABLE week_records`).
- `lib/models/week_record.dart` (3 fields + `frozenAnnualizedImpact`
  getter + `toMap` / `fromMap` extended).
- `lib/data/shift_service.dart` (`_buildWeekRecord` capture block;
  `WeekRecord(...)` constructor call extended).
- `lib/data/mock_integration_replay_seed.dart`
  (`_deriveWeekRecord` now accepts a `historicalPool`; computes
  `closedAt` + month + 60-day windows for every demo historical
  `WeekRecord` so the History tab shows the new 4-row view after
  reseed without waiting for a fresh runtime close. New private
  `_accumulateDollarImpactSeed` mirrors the runtime helper using the
  seed's own target standards because seed shifts don't carry locked
  per-shift target fields).
- `lib/widgets/dollar_impact_card.dart` (NEW — shared widget).
- `lib/screens/variance_report.dart` (delete local
  `_DollarImpactCard`/`_ImpactRow`/`_ImpactDivider`; call shared widget).
- `lib/screens/week_detail_screen.dart` (delete local `_DollarImpactCard`;
  add `_SectionLabel('DOLLAR IMPACT')`; call shared widget; add
  `_fmtClosedAt` helper).
- `test/shift_service_close_shift_test.dart` (new group: frozen dollar
  impact windows at close).
- `test/dollar_impact_card_widget_test.dart` (NEW — shared-widget
  rendering behavior).
- `test/variance_history_widget_test.dart` (new fixture variant +
  test for 4-row + "As of close" footer path).
- `docs/phases/7_55q/phase_7_55q_10_dollar_impact_card_unification.md`
  (this file).

## Honest Legacy

Pre-V22 closed weeks have null `month_dollar_impact`,
`sixty_day_dollar_impact`, and `closed_at`. Week Detail then renders the
existing 2-row view (Week + Annualized via `dollarGapAnnualized` ×52
fallback) with the existing "$3M annual sales" boilerplate footer. No
silent re-modeling from actuals.

## Demo Reseed Required

The codebase pattern is **always pre-seed historical weeks via
`MockIntegrationReplaySeed`** (not via runtime close). A user who runs
the app against a database created before this slice landed will see
the legacy 2-row view on every historical week — V22 added the columns
but the rows remain null because they were inserted before the seed
update. To see the new 4-row view, reseed (Settings → Clear All Data,
then app re-init) or close a fresh week through the runtime path.

## Inherited Debt (flagged, not fixed)

The "14 shifts per week" assumption (7 days × 2 dayparts) sits one layer
above this slice in `_buildWeekRecord`'s close-detection. This slice does
not add new `14` constants and does not depend on the constant being
right — capture works under whatever upstream considers "week complete."

Already documented as debt:

- `PROJECT_TRACKER.md` line 90 / `docs/DATA_ALIGNMENT_TRACKER.md` line 92:
  *"fixed `14 shifts` debt spans runtime, replay seeding, tests, UI copy,
  and active integration docs"*
- `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 9: service
  periods are restaurant-owned settings, not hardcoded product constants.
- `docs/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md`:
  `ServicePeriodDefinition` shape is designed but not wired through
  runtime / seed / tests / UI.

Retiring the `14` constant is its own future slice (7.55r territory),
not this one.

## Remaining Gaps

- The Variance banner (`lib/widgets/variance_banner.dart`) reads
  `dollarGapAnnualized` from `WeekData` directly; not touched. If the
  banner ever needs trend-aware annualized parity, route it through the
  same shared formula then.
- No `LaborModel.annualizedFromSixtyDay()` constant extracted yet; the
  `(365.0/60)` lives in two places (`WeekData.annualizedDollarImpact`,
  `WeekRecord.frozenAnnualizedImpact`). Refactor when a third caller
  appears.
- This slice closes the dual-widget divergence flagged in the earlier
  debug. The 14-shifts close-detection debt is unowned.
