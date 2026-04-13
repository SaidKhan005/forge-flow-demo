# Phase 7.55l.6a - WeeklyPlanSnapshot Contract

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented — contract only, no persistence yet

## Purpose

Introduce a first-class `WeeklyPlanSnapshot` contract so the app has one
explicit runtime model for the locked week in force.

This is the missing piece between `SchedulePlan` (resolved live from current
inputs) and downstream consumers (Variance, History, Learn) that need a
stable comparison truth for the operating week.

## What This Slice Adds

### WeeklyPlanSnapshot Model

One locked snapshot per restaurant per business week.

Fields:

- `snapshotId` — unique identifier
- `restaurantId` — restaurant scope
- app-owned week identity:
  - `weekKey` — fully derived getter, always `{weekStartDate}_{weekEndDate}`;
    never stored independently, cannot drift from the week span
  - `weekStartDate` — first business day of the week
  - `weekEndDate` — last business day of the week
- `targetCycleId` — links to the `TargetCycle` that was active when generated
- locked weekly values:
  - `forecastCovers`
  - `forecastSales`
  - `requiredFohHours`
  - `requiredBohHours`
  - `theoreticalFohLaborDollars`
  - `theoreticalBohLaborDollars`
  - `theoreticalLaborPct`
  - `targetBlendedWage`
  - `coversSource`
  - `salesSource`
- locked day rows (one per business day in the week):
  - `day` — day name
  - `businessDate` — ISO date
  - `forecastCovers`
  - `forecastSales`
  - `requiredFohHours`
  - `requiredBohHours`
- metadata:
  - `generatedAt` — ISO timestamp when the snapshot was created
  - `lockedAt` — ISO timestamp when the snapshot was locked

Week identity is app-owned and derived from the actual week span, not
from an implicit Monday-only ISO week assumption. The week start day
defaults to Monday but is designed to support restaurant-configurable
start day later.

### Week-Key Invariant (7.55l.6a1)

`weekKey` is a derived getter (`{weekStartDate}_{weekEndDate}`), not a
stored field. It is impossible to construct a `WeeklyPlanSnapshot` with
an inconsistent week key vs week span.

- `toMap()` emits the derived `weekKey`
- `fromMap()` validates a stored `week_key` against the derived value;
  inconsistent data throws `ArgumentError`
- if `week_key` is absent from the map, the model derives it silently

### WeeklyPlanSnapshotRepository Contract

Minimum abstract interface for later persistence work:

- `getSnapshotForBusinessDate(restaurantId, businessDate)` — read the
  snapshot in force for a business date
- `getSnapshotForWeekKey(restaurantId, weekKey)` — read a snapshot by
  week key
- `upsertSnapshot(snapshot)` — insert or replace a snapshot

No SQLite implementation in this slice. That belongs to `7.55l.6b+`.

### WeeklyPlanSnapshotPolicy

Pure rule helper covering contract-level questions:

- `weekStartForDate(businessDate, {weekStartDay})` — derive the business-
  week start date; configurable start day, Monday default
- `weekEndForDate(businessDate, {weekStartDay})` — derive the business-
  week end date
- `weekKeyFromSpan(weekStart, weekEnd)` — deterministic week key from
  the week span
- `weekKeyForDate(businessDate, {weekStartDay})` — deterministic week key
  for a business date
- `isActiveForDate(snapshot, businessDate)` — whether the snapshot covers
  the given business date
- `shouldGenerate(businessDate, existingSnapshot, {weekStartDay})` — whether
  the app should generate a snapshot (true when none exists for the week)
- `snapshotRemainsValidDespiteCycleRefresh(snapshot, businessDate)` — the
  locked weekly plan stays valid even when the target cycle refreshes midweek

No persistence logic. No publish state machine. No admin replacement logic.

## Contract Rules

### Rule 1 — One locked snapshot per restaurant per week

The app auto-generates one `WeeklyPlanSnapshot` for each business week.
Once generated, it is the comparison truth for that week.

### Rule 2 — Auto-generate at week start

At the start of each business week, the app generates the snapshot from:

- the current active `TargetCycle` (locked standards)
- the current rolling `DemandForecastContext` (rolling demand)
- the current smoothed day-allocation weights

No manual trigger, no draft/publish workflow.

### Rule 3 — Missing snapshot recovery

If the snapshot is missing unexpectedly for the current week:

- regenerate from the current cycle + current rolling demand
- do not expose a broken state to the manager

### Rule 4 — Midweek cycle refresh does not rewrite the locked week

If the 60-day target cycle refreshes during a week, the already locked
weekly snapshot stays in force. The new cycle affects the next generated
week, not the current one.

### Rule 5 — No draft/publish workflow

There is no draft state, no publish action, no manager approval step.
The snapshot auto-generates and auto-locks.

### Rule 6 — No manager forecast adjustments

No manager override of demand in this architecture cut. The snapshot
reflects the system-computed rolling demand.

### Rule 7 — No intended UX change

The weekly plan snapshot is an internal runtime contract. Manager-facing
screens (Benchmark, Schedule, History, Learn) are not changed by this
slice.

## Daypart Handling

Daypart snapshot semantics are intentionally left out of this contract.
The model does not carry daypart-level rows in this slice. If daypart
allocation needs to be locked per week later, the model can be extended
without breaking the existing weekly/daily contract.

## What This Slice Does Not Do

- No SQLite schema or repository implementation
- No consumer migration (Schedule, Shift, Variance, History, Audit, Learn)
- No SchedulePlanReadService wiring into snapshot persistence
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No manager UX changes
- No draft/publish workflow
- No tracker file changes

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- WeeklyPlanSnapshot model: `lib/domain/models/weekly_plan_snapshot.dart`
- WeeklyPlanSnapshotRepository: `lib/domain/repositories/weekly_plan_snapshot_repository.dart`
- WeeklyPlanSnapshotPolicy: `lib/domain/services/weekly_plan_snapshot_policy.dart`
- SchedulePlan (live-resolved source): `lib/domain/models/schedule_plan.dart`
- TargetCycle: `lib/domain/models/target_cycle.dart`
- DemandForecastContext: `lib/domain/models/demand_forecast_context.dart`
