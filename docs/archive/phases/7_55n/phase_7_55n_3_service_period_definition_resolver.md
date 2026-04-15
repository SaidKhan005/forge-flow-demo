# Phase 7.55n.3 â€” ServicePeriodDefinitionResolver

Updated: 2026-04-13
Owner: Claude implementation
Status: Complete

## What This Slice Establishes

- One shared app-owned service-period definition resolver now exists.
- Hardcoded availability / label / ordering helpers are reduced to a shared
  resolver seam backed by explicit `ServicePeriodDefinition` inputs.
- Current demo service-period behavior is preserved:
  - Monâ€“Thu = lunch + dinner
  - Fri = lunch + dinner + late_night
  - Sat = dinner + late_night
  - Sun = dinner
- `morning` is supported at the definition level even if not surfaced live
  yet â€” a morning definition with `sortOrder: 0` sorts before all demo
  definitions and appears in weekday applicability when configured.
- No week-start, close/finalization, or live Shift behavior is rewired yet.

## Design Decisions

### Pure resolver, no runtime dependencies

`ServicePeriodDefinitionResolver` is a pure domain service with no database,
clock, or singleton dependencies. It takes explicit `ServicePeriodDefinition`
lists and returns deterministic results.

All methods are static and work from explicit inputs.

### Demo definitions as compatibility bridge

The resolver carries a `demoDefinitions` constant matching the current
fixture-era `WeekDayOrder.daypartsFor` shape. This bridge is used by sync
callers that do not yet have access to the persisted timing config.

Later slices will wire callers to the persisted `RestaurantTimingConfig`
service-period definitions.

### WeekDayOrder reduced to thin bridge

`WeekDayOrder` is retained as a thin bridge for callers not modified in
this slice (e.g. `VarianceWeekProjectionReadService`). It now delegates to:

- `CanonicalDayOrder.labels` for day ordering
- `ServicePeriodDefinitionResolver.idsForDayLabel` with demo definitions
  for daypart availability

### Hardcoded helpers removed from modified files

- `schedule_builder.dart`: removed `_daypartLabel`, `_knownDaypartOrder`,
  and `_daypartSortKey` â€” replaced with resolver calls
- `baseline_manager_service.dart`: removed local `daypartOrder` const â€”
  replaced with `sortIndex` calls
- `baseline_manager_screen.dart`: removed hardcoded
  `['lunch', 'dinner', 'late_night']` order lists â€” replaced with
  `ordered(demoDefinitions)` and `sortIndex` calls

### Resolver API

- `ordered(defs)` â€” canonical ordering by sortOrder then id
- `applicableForWeekday(defs, isoWeekday)` â€” weekday filtering
- `idsForDayLabel(defs, dayLabel)` â€” day label to applicable IDs
- `labelForId(defs, id)` â€” label lookup (raw id fallback)
- `shortLabelForId(defs, id)` â€” short label lookup (raw id fallback)
- `sortKey(defs, id)` â€” string sort key for deterministic ordering;
  known definitions sort by zero-padded `sortOrder` then `id`,
  so tied `sortOrder` values break deterministically on `id` and
  multi-digit `sortOrder` values compare numerically
- `sortIds(defs, ids)` â€” sort arbitrary IDs by definition order
  (deterministic for tied `sortOrder` via `id` tie-break)
- `sortIndex(defs, id)` â€” numeric sort index (99 for unknown)

## What This Slice Does NOT Do

- Does not change business-date behavior; `7.55n.2` owns that seam.
- Does not wire week-start behavior yet; `7.55n.4` owns that.
- Does not model service-period close vs shift finalization; `7.55n.5`.
- Does not normalize metadata timestamps; `7.55n.6`.
- Does not make Shift daypart-live; `10.5`.
- Does not change current schedule cover-weight math.
- Does not add manager-facing settings UI.
- Does not add vendor transport or broad runtime rewiring.
- Does not touch `VarianceWeekProjectionReadService` or `variance_report.dart`.

## Files Created

- `lib/domain/services/service_period_definition_resolver.dart`
- `test/service_period_definition_resolver_test.dart`
- `docs/archive/phases/7_55n/phase_7_55n_3_service_period_definition_resolver.md`

## Files Modified

- `lib/data/legacy_fixture_data.dart`
  - `WeekDayOrder` reduced to thin bridge delegating to resolver
  - Added imports for `CanonicalDayOrder` and resolver
- `lib/screens/schedule_builder.dart`
  - Removed `_daypartLabel`, `_knownDaypartOrder`, `_daypartSortKey`
  - `_resolveDaypartWeights` and `adjustedDayViews` now use resolver
- `lib/data/baseline_manager_service.dart`
  - `_sortCandidates` uses `sortIndex` instead of local const
- `lib/screens/baseline_manager_screen.dart`
  - Daypart grouping order and candidate sort use resolver

## Phase Ownership

- `7.55n.1` â€” persistence seam (complete)
- `7.55n.2` â€” BusinessDateResolver (complete)
- `7.55n.3` â€” this slice: ServicePeriodDefinitionResolver
- `7.55n.4` â€” week-start wiring
- `7.55n.5` â€” service-period close vs shift finalization
- `7.55n.6` â€” metadata timestamp normalization
- `10.5` â€” live Shift service-period behavior
