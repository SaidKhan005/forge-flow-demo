# Phase 7.55n.6 â€” Metadata Timestamp Normalization

Updated: 2026-04-13
Owner: Codex planning / tracker truth
Status: Landed

## What This Slice Does

Normalizes audit metadata timestamps to UTC in the active runtime and
seed/write seams that 7.55n owns.

Affected metadata columns:

- `created_at`
- `updated_at`
- `generated_at`
- `locked_at`

All touched writers now persist these as UTC ISO 8601 strings via a shared
`nowIsoUtc()` helper.

## What This Slice Does NOT Do

- Does not change `businessDate` semantics anywhere. Business date remains the
  separate operational anchor.
- Does not change planning-anchor or operational business-date resolution.
- Does not change service-period or week-start behavior.
- Does not change stale-data thresholds or freshness logic.
- Does not broaden into `builtAt`, `startedAt`, `completedAt`, `lastEventAt`,
  source-vendor timestamps, or other non-7.55n metadata families.
- Does not add a broad DB migration/backfill for ambiguous legacy naive
  timestamps already stored on disk.
- Does not redesign models broadly.

## Design Decisions

### Shared helper over inline conversion

A single `nowIsoUtc()` function in `lib/domain/services/utc_metadata_timestamp.dart`
keeps the pattern discoverable and consistent. The function is deliberately
minimal â€” one line that calls `DateTime.now().toUtc().toIso8601String()`.

### No broad backfill

Existing naive timestamps already stored on disk are left as-is. A broad
migration would risk reinterpreting ambiguous values. Future slices can add
targeted backfills if specific columns need correction.

### builtAt excluded

`ActiveTargetProfile.builtAt` is a separate metadata family that this slice
does not touch. It falls under the non-7.55n metadata exclusion.

### WeeklyPlanSnapshotService adoption

The service already wrote `generatedAt` / `lockedAt` as UTC via
`DateTime.now().toUtc().toIso8601String()`. Adopting the shared helper is a
cosmetic consistency change â€” no semantic difference.

## Touched Writers

| File | Column(s) | Before | After |
|---|---|---|---|
| `sqlite_database.dart` â€” `_backfillLockedTargets` | `created_at` (target_profile_versions) | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_database.dart` â€” `_seedOpenShiftSnapshotsFromReplay` | `updated_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_database.dart` â€” `_seedReservationBookSnapshotsFromReplay` | `updated_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_database.dart` â€” `_seedDemoRestaurant` | `created_at`, `updated_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_database.dart` â€” migration backfill timing config | `created_at`, `updated_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_database.dart` â€” reseed compat version row | `created_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `sqlite_restaurant_scope_repository.dart` â€” `getOrCreateActiveRestaurant` | `created_at`, `updated_at` | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `shift_service.dart` â€” `closeShift` | `created_at` (TargetProfileVersion) | `DateTime.now().toIso8601String()` | `nowIsoUtc()` |
| `weekly_plan_snapshot_service.dart` â€” `_generateAndPersistSnapshot` | `generated_at`, `locked_at` | `DateTime.now().toUtc().toIso8601String()` | `nowIsoUtc()` |

## Untouched Writers (out of scope)

- `builtAt` in `buildActiveTargetProfileFromBaseline` â€” separate metadata family
- `startedAt` / `completedAt` in import runs â€” separate metadata family
- `lastEventAt` on snapshots â€” vendor/source timestamp
- All timestamps in files not owned by 7.55n

## Remaining Gaps

- Legacy naive timestamps already on disk are not retroactively corrected.
- Non-7.55n metadata families (`builtAt`, vendor timestamps) remain mixed.
- Broader import/sync layer metadata normalization is still deferred.

## Files Created

- `lib/domain/services/utc_metadata_timestamp.dart`
- `test/metadata_timestamp_normalization_test.dart`
- `docs/archive/phases/7_55n/phase_7_55n_6_metadata_timestamp_normalization.md`

## Files Modified

- `lib/infrastructure/persistence/sqlite/sqlite_database.dart`
- `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart`
- `lib/data/shift_service.dart`
- `lib/data/weekly_plan_snapshot_service.dart`

## Phase Ownership

- `7.55n.6` owns audit metadata UTC normalization in the touched 7.55n writers
- Business date remains a separate operational concept owned by `7.55n.2`
- Non-7.55n metadata families remain out of scope
