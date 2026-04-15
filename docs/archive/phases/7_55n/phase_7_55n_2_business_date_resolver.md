# Phase 7.55n.2 â€” BusinessDateResolver

Updated: 2026-04-13
Owner: Claude implementation
Status: Complete

## What This Slice Establishes

- One shared app-owned business-date resolver now exists.
- It resolves from restaurant timing config, not device-local clock truth.
- It expects a restaurant-local timestamp as input.
- Planning-anchor date and operational current-date remain separate seams.
- No week-start, service-period, or close/finalization behavior is rewired yet.

## Design Decisions

### Pure resolver, no runtime dependencies

`BusinessDateResolver` is a pure domain service with no database, clock, or
singleton dependencies. It takes a restaurant-local timestamp and a
business-day start time, and returns an ISO business date string.

Resolution rule:
- if local time is before `businessDayStartLocalTime` â†’ previous calendar date
- if local time is at or after `businessDayStartLocalTime` â†’ same calendar date

### Expects restaurant-local timestamps

This slice does not add a timezone conversion library. The resolver expects
callers to provide timestamps already expressed in restaurant-local time.
This is honest and explicit â€” it does not imply full timezone-conversion
support has landed.

Later slices or adapter integration can perform timezone conversion before
calling this resolver.

### Runtime seam on BusinessDateAuthorityService

`BusinessDateAuthorityService.resolveBusinessDate()` composes:
- active restaurant timing config (from `RestaurantTimingConfigReadService`)
- provided restaurant-local timestamp
- shared `BusinessDateResolver`

Returns `null` when timing config is unavailable.

A static `resolveBusinessDateFromConfig()` variant accepts an explicit
config for callers that already have one.

### Planning-anchor is untouched

`resolvePlanningAnchorDate()` behavior is unchanged. Planning anchor and
operational business-date resolution are separate concerns that remain
separate seams.

## What This Slice Does NOT Do

- Does not rewire adapter ingestion or live bucketing callers yet.
- Does not replace `WeekDayOrder` / hardcoded daypart helpers â€” `7.55n.3`.
- Does not wire `weekStartDay` into weekly snapshot generation â€” `7.55n.4`.
- Does not model service-period close vs shift finalization â€” `7.55n.5`.
- Does not normalize metadata timestamps â€” `7.55n.6`.
- Does not make Shift daypart-live â€” `10.5`.
- Does not add a timezone library or broad timestamp-normalization work.

## Files Created

- `lib/domain/services/business_date_resolver.dart`
- `test/business_date_resolver_test.dart`
- `docs/archive/phases/7_55n/phase_7_55n_2_business_date_resolver.md`

## Files Modified

- `lib/data/business_date_authority_service.dart`
  - Added `resolveBusinessDate()` runtime seam
  - Added static `resolveBusinessDateFromConfig()` helper
- `test/business_date_authority_service_test.dart`
  - Added tests for the new business-date resolution seam

## Phase Ownership

- `7.55n.1` â€” persistence seam (complete)
- `7.55n.2` â€” this slice: BusinessDateResolver
- `7.55n.3` â€” ServicePeriodDefinitionResolver
- `7.55n.4` â€” week-start wiring
- `7.55n.5` â€” service-period close vs shift finalization
- `7.55n.6` â€” metadata timestamp normalization
- `10.5` â€” live Shift service-period behavior
