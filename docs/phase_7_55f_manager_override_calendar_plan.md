# Phase 7.55f - Manager Override: Calendar + Clear Selection + business_date

## Status Snapshot

Current 7.55f state:

- Verified complete:
  - `7.55f.1`: `business_date` foundation on closed `ShiftRecord`s + true date-range querying
  - `7.55f.1a`: malformed-row migration hardening
  - `7.55f.1b`: strict week-id parsing + no lib-side sentinel business dates
  - `7.55f.2`: latest-closed-date anchored 60-day Manager Override candidate loading, candidate historical actual labor %, draft-only Clear All
  - `7.55f.3`: Manager Override calendar navigation UI
  - `7.55f.3a`: DST-safe calendar grid hardening
  - `7.55f.3b`: suggested-star-day legend + Manager Override copy polish
  - `7.55f.3c`: lever-meaning preservation on candidate tiles
  - `7.55f.4`: scenario-level mock replay reset / advance

7.55f is now complete and this doc remains the close-out record for the lane.
Non-blocking note: some test/preview compatibility surfaces still intentionally read `MockIntegrationReplaySeed.output`, so they remain fixed to the default scenario while runtime SQLite-backed surfaces move with the mock replay clock.

## Context

The Manager Override screen (`baseline_manager_screen.dart`) currently shows a scrollable list of closed shifts grouped by daypart (Lunch/Dinner/Late Night). The user toggles star-shift selections, and targets recalculate live in the preview panel.

Five improvements are needed:

1. **Clear selection button** - no explicit "clear all" exists; the user must manually deselect each shift.
2. **Calendar navigation** - replace the daypart-grouped list with a 60-day calendar as the primary navigation. Tap a date, see that day's closed daypart shifts, then toggle selection.
3. **Persist `business_date` on `ShiftRecord`** - it is already on `ClosedShiftInput` but gets dropped during `ShiftFact -> ShiftRecord` conversion. It is needed for real date queries and the calendar UI.
4. **Mock replay business-date reset / advance** - reset or advance the mock integration clock by reseeding coherent mock replay state, not by mutating one `business_date` field.
5. **Candidate shift labor percentage visibility** - each Manager Override candidate shift should show its historical actual labor percentage in addition to CPLH, covers, SPLH, PPA, and lever. This is separate from the preview panel's downstream plan labor percentage.

## Research Findings

### Current Manager Override Architecture

- **Screen**: `lib/screens/baseline_manager_screen.dart`
- **Service**: `lib/data/baseline_manager_service.dart` orchestrates DB ops and override application.
- **Selection state**: draft held in local `Set<String> _draftKeys`, persisted to `baseline_selected_records` on DONE.
- **RecordKey format**: `'${weekId}|${dayLabel}|${daypart}'`
- **Propagation**: `saveSelection() -> primeManagerOverride() -> _persistActiveTargetProfile() -> ActiveTargetProfileNotifier.refresh()`
- **Current candidate tile metrics**: individual shift tiles show CPLH, covers, SPLH, PPA, and lever. They do not yet show the closed shift's actual labor percentage.
- **Current preview labor %**: the preview panel already shows downstream `SchedulePlan.theoreticalLaborPct`. Keep that as plan impact; do not confuse it with candidate-shift actual labor percentage.

### Current 60-Day Window

- Computed as **8 most recent unique weekIds** from closed shifts, which is approximately 56 days, not a true 60-day window.
- `BaselineManagerService.primeManagerOverride()` owns the current approximation.
- Existing code comments note that production Phase 8 should enforce this with a SQL `WHERE` clause.

### business_date Gap

- `ClosedShiftInput` has `businessDate: DateTime`, the real calendar date.
- `OpenShiftSnapshot` has `businessDate: String`, persisted in `open_shift_snapshots`.
- `ShiftRecord` has no `business_date`; it only has `weekId`, `dayLabel`, and `daypart`.
- The date is known at close time but dropped during conversion.

### Business-Date Reset / Mock Replay Clock

- Current reset behavior reseeds the app back to the mock replay's default open business date.
- That is acceptable as a reset-to-known-scenario action, but it is not a true configurable business-date reset.
- Do **not** implement date reset by only updating `open_shift_snapshots.business_date`; that would make Shift look date-native while Baseline, Schedule distribution, Variance, and History still depend on week/day labels.
- 7.55f should make reset/advance date-native by driving it through a mock replay scenario/current-date controller:

```text
mock replay scenario/current business date
-> reseed shift_records with business_date
-> reseed week_records
-> reseed open_shift_snapshots
-> reseed reservation_book_snapshots
-> repositories/notifiers reload from SQLite
```

- This keeps the mock path shaped like the future official POS/labor integration path.
- Business-date reset/advance must stay scenario-level and coherent across Baseline, Schedule, Shift, Variance, and History.

### No Clear All Button

- Reset is implicit: user must deselect each shift individually, then tap DONE.
- `saveSelection(Set<String>())` with an empty set triggers `BaselineData.clearManagerOverride()`.

## Part 1: Add `business_date` to ShiftRecord

### Schema Migration

**File**: `lib/infrastructure/persistence/sqlite/sqlite_database.dart`

Add a column to the `shift_records` table:

```sql
business_date TEXT
```

Use ISO 8601 date strings, for example `2026-03-27`.

Add a migration for existing databases by incrementing the DB version and using `ALTER TABLE` where needed.

### Persist During closeShift()

**File**: `lib/data/shift_service.dart`

`ClosedShiftInput.businessDate` already carries the date. Pass it through `ShiftFact -> ShiftRecord` conversion.

**File**: `lib/models/shift_record.dart`

Add `final String? businessDate`. Update `fromMap()`, `toMap()`, `copyWith()`, equality-sensitive test builders if present, and any seed/backfill paths.

### Seed / Replay Data

**File**: `lib/infrastructure/persistence/sqlite/sqlite_database.dart`

After 7.55e.5/e.6, operational seed truth should come from deterministic mock integration replay rather than hardcoded `DemoData` lists. 7.55f should add `business_date` to whatever replay path is active, computing the date from `weekId + dayLabel` only as a migration/backfill compatibility step.

**File**: `lib/data/mock_integration_replay_seed.dart`

Add a small scenario/current-date surface if needed so reset/advance can regenerate a coherent mock business day. The reset should move the whole replay scenario together; it should not patch only the open snapshot date.

### DAO Query Method

**File**: `lib/infrastructure/persistence/sqlite/dao/shift_record_dao.dart`

Add:

```dart
Future<List<ShiftRecord>> getClosedShiftsInDateRange(
  String restaurantId,
  String startDate,
  String endDate,
) async {
  // WHERE status = 'closed'
  //   AND business_date >= ?
  //   AND business_date <= ?
  // ORDER BY business_date DESC
}
```

## Part 2: Clear Selection Button

### UI Change

**File**: `lib/screens/baseline_manager_screen.dart`

Add a "Clear All" button visible only when `_draftKeys.isNotEmpty`:

```dart
void _clearAll() {
  setState(() => _draftKeys.clear());
}
```

Preview panel updates instantly because it is already reactive to `_draftKeys`. No persistence occurs until DONE.

## Part 3: Calendar Navigation

Replace `_CandidateList` with a two-level calendar flow.

### Level 1 - Calendar Grid

- Show the previous 60 days from the current business date / mock replay clock.
- Each date cell shows the date number.
- Add a dot if closed shifts exist for that date.
- Highlight a date if any shifts on that date are selected.
- Tap a date to open the day detail.

### Level 2 - Day Detail

- Shows closed daypart shifts for the tapped date, for example Lunch and Dinner.
- Each shift tile shows the daypart label, CPLH, SPLH, PPA, covers, historical actual labor %, and lever using the same metric chips as the current UI.
- Toggle selection per shift using the existing `_toggle()` mechanism.
- Back/collapse returns to the calendar grid.

### Data Loading

**File**: `lib/data/baseline_manager_service.dart`

Replace or supplement `getCandidateShifts()` with date-range-aware loading:

```dart
Future<List<BaselineCandidateShift>> getCandidatesForDateRange(
  String startDate,
  String endDate,
) async {
  final shifts = await _shiftRepo.getClosedShiftsInDateRange(
    restaurantId,
    startDate,
    endDate,
  );
  final selectedKeys = await _baselineRepo.getSelectedRecordKeys(restaurantId);
  // Map to BaselineCandidateShift with isSelected flag.
}
```

### Calendar Data Structure

```dart
Map<String, List<BaselineCandidateShift>> _shiftsByDate;
// Key: '2026-03-27', value: [lunch shift, dinner shift]
```

Build once on screen load from the 60-day query. Calendar grid reads keys for dots; day detail reads values for shift tiles.

### Preview Panel + Selection Persistence

No behavior change. Preview still shows live aggregated targets from `_draftKeys`. DONE still calls `saveSelection(_draftKeys)`.

## Key Files To Modify

| # | File | Change |
|---|------|--------|
| 1 | `lib/models/shift_record.dart` | Add `businessDate` field, update fromMap/toMap/copyWith |
| 2 | `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Add column, migration, backfill, and seed `business_date` |
| 3 | `lib/infrastructure/persistence/sqlite/dao/shift_record_dao.dart` | Add `getClosedShiftsInDateRange()` |
| 4 | `lib/domain/repositories/shift_record_repository.dart` | Add date-range method to interface |
| 5 | `lib/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart` | Implement date-range method |
| 6 | `lib/data/shift_service.dart` | Pass `businessDate` through `closeShift()` |
| 7 | `lib/data/baseline_manager_service.dart` | Add date-range loading, keep existing save flow |
| 8 | `lib/screens/baseline_manager_screen.dart` | Replace list with calendar navigation and clear-all button |
| 9 | `lib/models/baseline_candidate_shift.dart` | Add `businessDate` and actual labor percentage fields for grouping and candidate tile display |
| 10 | `lib/data/mock_integration_replay_seed.dart` | Add scenario/current-date reset or advance support if needed |
| 11 | Tests | Update Manager Override tests and add business_date plus mock replay reset coherence tests |

## Live Integration Path

With `business_date` persisted on `ShiftRecord`:

- Phase 8 POS adapter writes `ClosedShiftInput` with real `businessDate`.
- `closeShift()` stores that date in SQLite.
- Calendar queries use a true rolling date window instead of "8 most recent weekIds".
- Rolling windows update naturally as new shifts close and old shifts age out.
- Mock integration reset/advance behaves like a replayed vendor feed: regenerate coherent operational facts, then let Baseline, Schedule, Shift, Variance, and History read from repositories.

## Guardrails

- Do not make a fake date switch that only changes `open_shift_snapshots`.
- Do not reintroduce hardcoded screen-level demo truth.
- Do not start live vendor integration in 7.55f.
- Do not change labor formulas.
- Do not change the meaning of Manager Override selection; this phase changes navigation and date correctness, not the target math contract.
- Candidate tile `LABOR %` must mean historical actual labor percentage from the closed shift, preferably `ShiftRecord.totalLaborPct` or the existing persisted equivalent. Preview panel `LABOR %` must continue to mean downstream SchedulePlan theoretical labor percentage.

## Close-Out Summary

### `7.55f.3` - Manager Override calendar navigation UI

- Replaced the flat candidate list with a 60-day calendar -> day-detail flow anchored to candidate `businessDate`.
- Preserved preview semantics, draft-only selection behavior, and candidate actual `LABOR %`.

### `7.55f.3a` - DST-safe calendar grid hardening

- Removed DST-sensitive `difference(...).inDays` / `add(Duration(...))` iteration from the calendar renderer.
- Added focused regression proof around the spring-forward boundary.

### `7.55f.3b` / `7.55f.3c` - suggested-star-day + copy polish

- Calendar now distinguishes available / suggested / selected date states with a legend.
- Suggested-star-day highlighting remains advisory only and does not shrink the candidate pool.
- Day detail uses human-friendly business-date text.
- Clear All is now a real touch target.
- Lever chips now preserve full canonical lever meaning instead of collapsing distinct levers into generic metric buckets.

### `7.55f.4` - scenario-level mock replay reset / advance

- Added persistent mock replay business-date state.
- Reset and advance now reseed coherent scenario truth across:
  - `shift_records`
  - `week_records`
  - `open_shift_snapshots`
  - `reservation_book_snapshots`
- Manager Override now prefers the mock replay business date as its 60-day anchor when available.
- Runtime SQLite-backed surfaces now move with the mock replay clock instead of relying on a fixed Friday-only scenario.
