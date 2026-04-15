# Phase 7.55n.1 — Restaurant Timing Config Persistence Seam

Updated: 2026-04-13
Owner: Claude implementation
Status: Complete

## What This Slice Establishes

- One persisted restaurant timing-config seam now exists.
- Business timezone remains authoritative on `RestaurantLocation`.
- The timing config carries the rest of the time boundary contract:
  - `businessDayStartLocalTime`
  - `weekStartDay`
  - `servicePeriodDefinitions`
  - `shiftCloseAuthority`
  - optional `localCloseFallback`
- Runtime services can read the config without touching UI widgets.
- No business-date, week-start, or service-period behavior is rewired yet.

## Design Decisions

### Timezone authority stays on RestaurantLocation — no fallback

`RestaurantLocation.businessTimezone` is already persisted and authoritative.
`RestaurantTimingConfig` composes that timezone at read time rather than
storing a duplicate timezone column. This avoids dual-source drift.

If a timing-config row exists without a matching `RestaurantLocation` row,
the repository returns `null` instead of substituting a demo timezone.
This makes scope mismatches observable rather than silently masking them.

### Separate table, not on RestaurantLocation

`restaurant_timing_configs` is a dedicated table keyed by `restaurant_id`.
This keeps `restaurant_locations` focused on identity/scope and keeps the
timing config record self-contained for future settings UI.

### Service-period definitions stored as canonicalized JSON

`service_period_definitions_json` is canonicalized before write:
definitions are sorted by `sortOrder` ascending, then `id` ascending for
stability. This ensures two logically equivalent configs always persist
identical JSON regardless of caller input order.

Each definition carries: stable `id`, `label`, `shortLabel`, `sortOrder`,
`startLocalTime`, `endLocalTime`, `rollsPastMidnight`, and weekday
`applicableDays` list.

### Demo defaults preserve fixture-era shape

Seeded defaults match the current `WeekDayOrder.daypartsFor` applicability:
- lunch: Mon–Fri (weekdays 1–5)
- dinner: Mon–Sun (weekdays 1–7)
- late_night: Fri–Sat (weekdays 5–6)

Clock ranges are conservative demo defaults, not vendor-authoritative:
- lunch: 11:00–15:00
- dinner: 17:00–23:00
- late_night: 23:00–02:00 (rolls past midnight)

Business-day start: `04:00`, week start: Monday (1), shift-close authority:
`app_local_cutoff_fallback` with local close fallback `04:00`.

### Shift-close authority enum

Two values per the time boundary contract:
- `vendor_finalization` — source system owns close truth
- `app_local_cutoff_fallback` — app uses local-time fallback (demo/offline)

Demo uses `app_local_cutoff_fallback` because no vendor finalization exists.

## What This Slice Does NOT Do

- Does not rewire `BusinessDateAuthorityService` — `7.55n.2` owns that.
- Does not replace `WeekDayOrder` / hardcoded daypart helpers — `7.55n.3`.
- Does not wire `weekStartDay` into weekly snapshot generation — `7.55n.4`.
- Does not model service-period close vs shift finalization — `7.55n.5`.
- Does not normalize metadata timestamps — `7.55n.6`.
- Does not make Shift daypart-live — `10.5`.
- Does not add manager-facing settings UI.

## Files Created

- `lib/domain/models/service_period_definition.dart`
- `lib/domain/models/restaurant_timing_config.dart`
- `lib/domain/repositories/restaurant_timing_config_repository.dart`
- `lib/data/restaurant_timing_config_read_service.dart`
- `lib/infrastructure/persistence/sqlite/dao/restaurant_timing_config_dao.dart`
- `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart`
- `test/restaurant_timing_config_repository_test.dart`

## Files Modified

- `lib/infrastructure/persistence/sqlite/sqlite_database.dart`
  - Added `restaurant_timing_configs` table
  - Added demo timing config seed in `_seedDemoRestaurant`

## Phase Ownership

- `7.55n.1` — this slice: persistence seam only
- `7.55n.2` — BusinessDateResolver
- `7.55n.3` — ServicePeriodDefinitionResolver
- `7.55n.4` — week-start wiring
- `7.55n.5` — service-period close vs shift finalization
- `7.55n.6` — metadata timestamp normalization
- `10.5` — live Shift service-period behavior
