# Phase 7.55l.2a - TargetCycle Persistence + Recommended Auto-Refresh Spine

Updated: 2026-04-11 (7.55l.2b+2c correctness cleanup applied)
Owner: Codex planning / tracker truth
Status: Implemented — persistence spine only, no UX change

## Purpose

Add the first persistence-backed TargetCycle runtime spine so the app can:

- store target cycles in SQLite
- load the active cycle for a restaurant
- auto-create a recommended cycle when none exists
- auto-refresh to a new recommended cycle at the 60-day boundary

This is the safe first half of `7.55l.2`. Manager override write-path changes,
ActiveTargetProfile projection, and consumer migration are deferred to later
slices.

## What This Slice Adds

### SQLite Persistence

A `target_cycles` table with all fields from the `TargetCycle` model plus a
`deactivated_at` column so old cycles are retained as historical rows rather
than deleted.

Schema version bumped from 14 to 15.

### TargetCycleDao

Low-level database operations:

- `getActiveCycle(restaurantId)` — returns the active (non-deactivated) cycle,
  ordered by `created_at DESC` with `LIMIT 1` for deterministic reads
- `upsertCycle(cycle)` — insert or replace a cycle row
- `deactivateCycle(cycleId)` — sets `deactivated_at` timestamp on a single cycle
- `deactivateAllForRestaurant(restaurantId)` — sets `deactivated_at` on all
  active cycles for a restaurant (used before writing a new cycle)

### SqliteTargetCycleRepository

Implements the `TargetCycleRepository` contract from `7.55l.1`.

Follows the same singleton + lazy-DAO pattern as `SqliteTargetProfileRepository`.

Also exposes `deactivateAllForRestaurant(restaurantId)` as a concrete-only
method (not on the abstract contract) for service-level enforcement.

### TargetCycleService

Narrow runtime seam with one main entry point:

`getOrCreateActiveCycle(restaurantId, businessDate)`:

1. Load the active cycle from the repository.
2. If no cycle exists, create a recommended cycle.
3. If the business date is past the active cycle end, create a new recommended
   cycle (auto-refresh). All existing active cycles are deactivated first.
4. Otherwise return the existing active cycle unchanged.

### Recommended Cycle Bridge

Since `ActiveTargetProfile` is not yet projected from `TargetCycle` (`7.55l.4`),
recommended cycle creation bridges from the current app truth:

- Before building, the service calls
  `BaselineManagerService.primeBaselineContextForDate(restaurantId, businessDate)`
  to re-prime in-memory `BaselineData` for the requested business date's 60-day
  window. This loads closed shifts from `[businessDate - 59, businessDate]`,
  applies them as historical context, and re-applies manager override state.
- Standards (CPLH, SPLH, PPA, OPZ) are then rebuilt via
  `SqliteDatabase.buildActiveTargetProfileFromBaseline()` — reading from the
  freshly primed `BaselineData`, not from whatever stale state was previously
  in memory.
- Wages are resolved fresh via `WageStandardContextService.resolve()`
- This ensures the recommended cycle always reflects the correct benchmark
  context for the requested business date, not leftover in-memory state from a
  prior load or screen interaction.

This is a transitional bridge until `7.55l.4`.

### One-Active-Cycle Enforcement

One active cycle per restaurant is enforced through:

- **Write path**: `_createRecommendedCycle` calls `deactivateAllForRestaurant`
  before upserting the new cycle, so any pre-existing active rows are deactivated
- **Read path**: `getActiveCycle` uses `ORDER BY created_at DESC LIMIT 1` so
  reads are deterministic even if multiple active rows somehow exist

This is a service/repository-level enforcement, not a schema constraint.

### Date Window Semantics

- Effective window: `[businessDate, businessDate + 59]` — 60 calendar days inclusive
- Calibration window: `[businessDate - 59, businessDate]` — the preceding 60-day
  snapshot that calibrated the recommendation
- Auto-refresh: triggered when `businessDate > effectiveEnd` (uses `TargetCyclePolicy.needsAutoRefresh`)
- Date math uses `DateTime.utc()` to avoid DST issues

## What This Slice Does Not Do

- No Benchmark / Manager Override UX change
- No manager override write-path enforcement
- No `ActiveTargetProfile` projection from cycle (→ `7.55l.4`)
- No consumer migration (→ `7.55l.7`)
- No weekly plan logic (→ `7.55l.6`)
- No tracker file changes

## Contract Rules Honored

From `phase_7_55_target_cycle_weekly_plan_rules.md`:

1. One active cycle per restaurant — enforced via bulk deactivation before write
   and deterministic ordered reads
2. Old cycles preserved as historical rows (deactivated, not deleted)
3. Auto-refresh at 60-day boundary
4. Recommended cycle rebuilt fresh from the requested business date's 60-day
   benchmark context + resolved wages each time (not from stale in-memory state)
5. Standards lock at cycle creation and do not drift

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Contract doc: `docs/archive/phases/7_55l/phase_7_55l_1_target_cycle_contract.md`
- TargetCycle model: `lib/domain/models/target_cycle.dart`
- TargetCyclePolicy: `lib/domain/services/target_cycle_policy.dart`
