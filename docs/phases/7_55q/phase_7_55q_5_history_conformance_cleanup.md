# Phase 7.55q.5 - History Conformance Cleanup (Drift 6 + Drift 7)

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Make History preserve locked week-target truth instead of re-modeling
from actuals, and make Week Detail teach the real hour-weighted
blended-wage metric instead of a simple FOH/BOH wage mean.

This is the `7.55q.1` conformance-Rule-5 fix for History:

> **History preserves locked week context / closed truth.** History
> (`WeekRecord` + `week_detail_screen`) must not re-model week targets
> from actuals and must not teach a fake blended-wage metric. Stored
> locked target fields and stored closed totals are the only inputs.

## Scope

- In: additive nullable locked plan-hour fields on `WeekRecord`
  (`lockedRequiredFohHours`, `lockedRequiredBohHours`); strict
  `targetFohHours` / `targetBohHours` getters read those stored fields;
  nullable `preservedTargetFohHours` / `preservedTargetBohHours`
  accessors for honest UI degradation; SQLite additive columns +
  migration; `ShiftService.closeShift` populates the new fields from
  the `WeeklyPlanSnapshot` in force for the week's business-date span;
  `week_detail_screen.dart` now renders hour-weighted blended wage
  for both actual and target sides and renders `—` for legacy rows
  where the preserved plan-hour fields are absent; stale "prorated"
  footnote removed; focused tests; this phase doc.
- Out: Variance / Benchmark / Plan / Schedule changes (handled by
  `7.55q.2` / `7.55q.3` / `7.55q.4`).
- Out: Learn-surface changes.
- Out: Backfilling preserved plan hours for pre-existing demo / legacy
  `WeekRecord` rows — they render `—` honestly.
- Out: Closed-shift `_ClosedShiftDetail` Rule 4 exception in Variance
  Full Week (locked truth — stays as-is).

## Why this slice existed

### Drift 6 — History week target-hour regeneration from actuals

`WeekRecord.targetFohHours` and `targetBohHours` were recomputed from
the post-close `totalCovers` and `avgPPA` via `LaborModel`:

```dart
int get targetFohHours =>
    LaborModel.modelFohHours(totalCovers, storedTargetCPLH);
int get targetBohHours =>
    LaborModel.modelBohHours(totalCovers, avgPPA, storedTargetSPLH);
```

That is actuals-anchored — the formula asks "what would the target
hours have been if the plan had matched actual volume exactly?" —
rather than preserving what the locked plan for the week actually
required. Internally consistent, but **violates Rule 5**: History
must not re-model week targets from actuals.

### Drift 7 — History blended-wage simple average

`week_detail_screen.dart` rendered blended wage as the unweighted mean
of the FOH and BOH wages:

```dart
final actualBlendedWage = (week.blendedFohWage + week.blendedBohWage) / 2;
final targetBlendedWage =
    (week.storedTargetFohWage + week.storedTargetBohWage) / 2;
```

That is genuinely incorrect math for "blended wage" — the honest
metric (per `7.55p.5e` Jim Taylor Ch. 1) is the hour-weighted
average:

```
(fohHours × fohWage + bohHours × bohWage) / (fohHours + bohHours)
```

Rule 5 explicitly forbids "fake blended-wage metric". This drift was
not just structural — it was mathematically wrong for the metric
label.

## Runtime seam

Before (drift):

```
WeekRecord
   ├── targetFohHours → LaborModel.modelFohHours(totalCovers, storedTargetCPLH)
   │                     ↑ re-models from actuals
   └── targetBohHours → LaborModel.modelBohHours(totalCovers, avgPPA, storedTargetSPLH)
                         ↑ re-models from actuals

week_detail_screen._GroupedSummaryTable
   ├── actualBlendedWage = (blendedFohWage + blendedBohWage) / 2
   │                        ↑ unweighted mean
   └── targetBlendedWage = (storedTargetFohWage + storedTargetBohWage) / 2
                            ↑ unweighted mean
```

After (`7.55q.5`):

```
WeekRecord (persisted at week close from locked plan snapshot)
   ├── lockedRequiredFohHours (int?) ← snapshot.requiredFohHours
   └── lockedRequiredBohHours (int?) ← snapshot.requiredBohHours

   ├── targetFohHours → _requireLockedInt(lockedRequiredFohHours)
   │                     ↑ preserved locked plan truth; throws if null
   ├── targetBohHours → _requireLockedInt(lockedRequiredBohHours)
   │                     ↑ same
   ├── preservedTargetFohHours → int? (null-safe accessor for UI)
   └── preservedTargetBohHours → int? (null-safe accessor for UI)

ShiftService.closeShift → _buildWeekRecord
   ├── anchorDate = closedShifts.first.businessDate
   ├── snapshot = WeeklyPlanSnapshotRepository
   │     .getSnapshotForBusinessDate(restaurantId, anchorDate)  ← read-only
   └── writes lockedRequiredFohHours / lockedRequiredBohHours
       from snapshot.requiredFohHours / snapshot.requiredBohHours
       when a snapshot is in force; null otherwise (honest legacy)

week_detail_screen._GroupedSummaryTable
   ├── actualBlendedWage = (totalFoh × blendedFohWage + totalBoh × blendedBohWage)
   │                        / (totalFoh + totalBoh)
   │                        ↑ hour-weighted actual
   ├── targetBlendedWage = (lockedFoh × storedTargetFohWage + lockedBoh × storedTargetBohWage)
   │                        / (lockedFoh + lockedBoh)
   │                        ↑ hour-weighted target, uses preserved plan hours
   ├── FOH / BOH Hours target cells ← "—" when preservedTargetFohHours/BohHours is null
   └── Blended Wage target cell ← "—" when preserved plan hours are absent
```

## Compatibility path for older rows

Historical `WeekRecord` rows seeded from `MockIntegrationReplaySeed` or
carried over from pre-`7.55q.5` week closes lack
`locked_required_foh_hours` / `locked_required_boh_hours` values. The
additive V21 migration leaves those rows' new columns as `NULL`.

On read, `preservedTargetFohHours` / `preservedTargetBohHours` return
null and the Week Detail UI renders `—` for those cells. We do NOT
silently fall back to re-modeling from actuals — that would be
exactly the drift this slice removes. Rows that close with a
persisted `WeeklyPlanSnapshot` in force get preserved hours; rows
without one degrade honestly.

Strict consumers (`targetFohHours` / `targetBohHours`) throw
`StateError` when the locked fields are null, matching the existing
`storedTargetCPLH` pattern. This prevents silent re-modeling and
forces callers to either read preserved truth or display `—`.

## Files touched

| File | Change |
|---|---|
| `lib/models/week_record.dart` | Added `int? lockedRequiredFohHours` and `int? lockedRequiredBohHours` constructor fields, `toMap` / `fromMap` entries, and `preservedTargetFohHours` / `preservedTargetBohHours` null-safe getters. Rewrote `targetFohHours` / `targetBohHours` to read the stored locked fields via a new `_requireLockedInt(...)` helper (throws `StateError` when null, matching the `_requireLocked` pattern). Removed the `legacy_fixture_data.dart` / `LaborModel` imports that supported the old re-modeling getters. |
| `lib/data/shift_service.dart` | `_buildWeekRecord` is now async. Added `SqliteWeeklyPlanSnapshotRepository` instance field. At week close, the method looks up the `WeeklyPlanSnapshot` for the first closed shift's `businessDate` (read-only — never auto-generates) and populates `lockedRequiredFohHours` / `lockedRequiredBohHours` from `snapshot.requiredFohHours` / `snapshot.requiredBohHours`. Missing snapshot or missing anchor date leaves the fields null (honest legacy). Callsite in `closeShift` now awaits `_buildWeekRecord`. |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Bumped `schemaVersion` from 20 to 21. Added `locked_required_foh_hours` / `locked_required_boh_hours` INTEGER columns to the `week_records` CREATE TABLE and to the in-upgrade `_migrateToV8` column list so post-V8 schemas include them. Added `_migrateToV21` that adds the columns via `ALTER TABLE ... ADD COLUMN` when absent; added the `oldV < 21 → _migrateToV21` dispatch in `_onUpgrade`. No backfill — legacy rows remain null. |
| `lib/screens/week_detail_screen.dart` | `_GroupedSummaryTable.build` now computes actual blended wage as the hour-weighted `(totalFoh × blendedFohWage + totalBoh × blendedBohWage) / totalHours` and target blended wage as the hour-weighted `(lockedFoh × storedTargetFohWage + lockedBoh × storedTargetBohWage) / totalPlanHours` using preserved locked plan hours. FOH Hours / BOH Hours target cells and the Blended Wage target cell render `—` when preserved plan hours are absent on the `WeekRecord`. Removed the stale `'* Target prorated for ... shifts completed.'` footnote — targets are no longer prorated from actual volume. |
| `test/variance_history_widget_test.dart` | Rewrote the three model-formula test groups to reflect the preserved-plan-hours contract: new `'WeekDetailScreen — targetFohHours / Bohhours read preserved locked plan hours'` group constructs a `WeekRecord` with explicit `lockedRequiredFohHours` / `lockedRequiredBohHours` and asserts those exact values are rendered; new `'WeekDetailScreen — legacy rows without preserved plan hours render —'` group asserts the `—` honest-degradation path; new `'WeekDetailScreen — blended wage is hour-weighted (7.55q.5)'` group proves actual and target blended wage follow the canonical hour-weighted formula (not the simple average); stale `'targetFohHours uses model formula'` group removed. |
| `test/wtd_variance_logic_test.dart` | Replaced the `'WeekRecord — model formula replaces naive proration'` group with `'WeekRecord — target hours read preserved locked plan hours (7.55q.5)'`: asserts `targetFohHours` / `targetBohHours` return the stored `lockedRequiredFohHours` / `lockedRequiredBohHours` exactly, asserts they are NOT derived from `totalCovers` + `storedTargetCPLH`, and asserts the strict getters throw `StateError` when the locked plan-hour fields are null. Non-`WeekRecord` groups left intact. |
| `test/shift_service_close_shift_test.dart` | Added test `'7.55q.5: closing all 14 shifts preserves locked plan FOH/BOH hours from the snapshot in force'`: ensures a `WeeklyPlanSnapshot` is persisted (via the auto-generating `getCurrentWeekSnapshot`), closes all 14 shifts, and asserts the resulting `WeekRecord.lockedRequiredFohHours` / `lockedRequiredBohHours` equal the snapshot's `requiredFohHours` / `requiredBohHours`. Added regression test `'7.55q.5: closing all 14 shifts without a snapshot leaves preserved plan hours null (honest legacy)'`: ensures no snapshot is present, closes 14 shifts, asserts the `WeekRecord.preservedTargetFohHours` / `preservedTargetBohHours` are null and the strict getters throw. |
| `test/target_state_alignment_test.dart` | Updated the `E — week truth stability` test assertion from the throwing `targetFohHours` getter to the null-safe `lockedRequiredFohHours` field comparison. Still proves the property the test name asserts — closed historical truth does not drift when the active profile changes — without depending on an explicit snapshot seed inside this suite. |
| `test/lever_logic_test.dart` | Updated the `WeekRecord — model formula targets and computed fields` test to construct the `WeekRecord` with explicit `lockedRequiredFohHours` / `lockedRequiredBohHours` and assert the new preserved-plan-hours behaviour, keeping the focused test passing without broadening scope. |
| `docs/phases/7_55q/phase_7_55q_5_history_conformance_cleanup.md` | **New** — this doc. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/screens/variance_report.dart` | Rule 4 closed-truth exception for closed Full Week rows; `7.55q.4` already handled the non-closed rewiring. |
| `lib/models/week_data.dart` | `7.55q.3` already routes WTD blended wage through the shared seam; this slice does not touch that. |
| `lib/screens/schedule_builder.dart` | Drift 1 — already landed in `7.55q.2`. |
| `lib/screens/baseline_tracker.dart` | Drift 2 — already landed in `7.55q.3`. |
| `lib/domain/models/weekly_plan_snapshot.dart` | No additive helper needed; `requiredFohHours` / `requiredBohHours` are already exposed. |
| `lib/infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart` | DAO uses `toMap` / `fromMap` — the additive fields flow through transparently. No repository-layer change. |
| `lib/data/mock_integration_replay_seed.dart` | Historical demo rows intentionally remain without preserved plan hours; Week Detail degrades honestly for those. Seeding them would require re-modeling from forecast / locked targets, and that is deliberately deferred (see "Remaining gaps"). |
| `test/persistence_scope_alignment_test.dart` | Not touched. The additive columns are nullable; the scope / restaurant_id schema contract this suite verifies is unaffected. |
| Tracker markdown files | Per prompt, no tracker updates in this run. |

## Remaining gaps (handed off)

- **Seed historical demo `WeeklyPlanSnapshot`s or backfill locked
  plan hours on demo `WeekRecord`s.** Would let the demo Week Detail
  render preserved-plan numbers for the historical weeks too. Out of
  scope here because it requires either a new seeding path or a
  re-derivation from forecast covers × locked targets — both broader
  than this slice and unrelated to the conformance drift this slice
  owns.
- **Planned labor kill (`7.55q.6`, parked).** The planned labor
  package still lives in the Schedule and Shift surfaces; the prompt
  explicitly parks that work until after `7.55q.5`.
- **Daypart-aware History.** Reserved for `Phase 10.5`.
- **Learn surface conformance.** Separate open gap; `7.55q.*` does
  not own Learn cleanup.

## Audit honesty notes

- The `—` display for legacy rows is not cosmetic — it is the honest
  resolution for "we did not preserve plan hours at the time this
  week closed." Any attempt to silently re-populate it from
  `LaborModel.modelFohHours(totalCovers, storedTargetCPLH)` would
  reintroduce Drift 6 under a different name.
- The strict getters (`targetFohHours` / `targetBohHours`) throwing
  for null is intentional: it guarantees non-UI callers (e.g. future
  services or aggregators) cannot silently read a default.
  UI callers must go through the null-safe `preservedTargetFohHours`
  / `preservedTargetBohHours` accessors and handle the legacy case.
- The new seam reads the snapshot read-only. If the snapshot is not
  yet persisted when a week closes, the preserved fields stay null;
  we do NOT auto-generate a snapshot at close time. Keeping that
  path read-only preserves the `7.55q.2-review-fix` spirit: no
  surface should silently bring a second plan authority into being.
