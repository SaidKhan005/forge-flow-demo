# Phase 7.55l.7c - Current-Week Full Week / CurrentWeekState Migration

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented (scoping cleanup applied in 7.55l.7c1)

## Purpose

Finish the current-week migration seam by moving `CurrentWeekState`
and Full Week open/projected row target standards onto the locked
cycle/week architecture.

After 7.55l.7b/7b1, the WTD layer is fully locked. But
`getCurrentWeekState()` still delegates to `getWeekToDate()` (the
live/historical path), and `getFullWeekShifts()` still materializes
open/projected rows with the current live active profile. This slice
closes both gaps for the current week.

## What This Slice Adds

### getCurrentWeekState Migration

`getCurrentWeekState()` now uses `getLiveWeekToDate()` (the locked
current-week path) instead of `getWeekToDate()` for the current
week. This ensures the `WeekData` inside `CurrentWeekState` uses
locked snapshot forecast truth and snapshot-linked cycle standards.

Historical-week callers continue to use `getWeekToDate()` unchanged.

### Full Week Open/Projected Row Migration

`getFullWeekShifts()` now uses the snapshot-linked `TargetCycle`
projected profile for current-week open/projected row target fields
when both a locked snapshot and its linked cycle exist.

**Locked-cycle Full Week target adoption is current-week only.**
The `_resolveProfileForFullWeek` helper gates on `weekId ==
currentWeekId` before consulting the snapshot service. Non-current
and historical full-week reads remain on the legacy live
active-profile path and never trigger snapshot generation side
effects.

This means current-week open/projected rows get their target
standards (CPLH, SPLH, PPA, wages, theoretical labor %) from the
locked cycle, not the current live active profile.

Closed shift rows remain unchanged.

Fallback behavior: when no snapshot or linked cycle exists, or when
the requested week is not the current week, the existing live active
profile path is used unchanged.

### Daypart Semantics Intentionally Narrow

`WeeklyPlanSnapshot` only has locked day rows, not daypart rows.
This slice does NOT invent per-daypart locked forecast allocation.

Open/projected row operational fields remain sourced from
`OpenShiftSnapshot`:
- covers, forecastCovers
- ppa, cplh, splh
- scheduled hours

Only their target/theoretical fields change source: from the live
active profile to the locked cycle's projected profile.

## What This Slice Does Not Do

- No fake daypart snapshot semantics
- No historical-week migration (non-current reads stay on live path)
- No History / Learn migration
- No Schedule Builder migration
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No WeeklyPlanSnapshot persistence redesign
- No manager UX changes
- No tracker file changes

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- WTD migration: `docs/archive/phases/7_55l/phase_7_55l_7b_current_week_variance_migration.md`
- First consumer migration: `docs/archive/phases/7_55l/phase_7_55l_7a_first_consumer_migration_slice.md`
- Snapshot contract: `docs/archive/phases/7_55l/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- ShiftService: `lib/data/shift_service.dart`
- CurrentWeekState: `lib/models/current_week_state.dart`
