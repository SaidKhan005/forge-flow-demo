# Phase 7.55l.1 - TargetCycle Contract

Updated: 2026-04-11 (7.55l.1a cleanup applied)
Owner: Codex planning / tracker truth
Status: Implemented — code contract only, no persistence yet

## Purpose

Introduce the first-class `TargetCycle` contract so the app has one explicit
runtime model for the locked 60-day standards window.

This is the code-level contract slice. Persistence (`7.55l.2`), projection
(`7.55l.4`), and consumer migration (`7.55l.7`) come later.

## What This Slice Adds

### TargetCycleSource

An enum representing how a cycle was created:

- `recommended` — auto-generated from the 60-day benchmark snapshot
- `managerOverride` — manager accepted or overrode the recommendation (once per cycle)
- `adminReplacement` — admin replaced the cycle before expiry (metadata path, no auth enforcement yet)

### TargetCycle

The locked standards object for the 60-day window:

- `cycleId` — unique identifier
- `restaurantId` — restaurant scope
- `source` — `TargetCycleSource` enum
- `effectiveStart` / `effectiveEnd` — the 60-day active window
- `calibrationWindowStart` / `calibrationWindowEnd` — the 60-day data window used to calibrate
- locked standards: CPLH, SPLH, PPA, FOH wage, BOH wage, OPZ floor/ceiling
- `managerOverrideUsed` — whether the once-per-cycle override has been consumed
- `managerOverrideAt` — timestamp of the override (null if not used)
- `adminReplacedAt` — timestamp of admin replacement (null if not used)
- `createdAt` — when the cycle was created
- `toMap()` / `fromMap()` serialization consistent with repo style

### TargetCycleRepository

Contract-only abstract interface for `7.55l.2`:

- `getActiveCycle(restaurantId)` — returns the current active cycle or null
- `upsertCycle(cycle)` — insert or replace the active cycle
- `deactivateCycle(cycleId)` — mark a cycle as no longer active

### TargetCyclePolicy

Pure rule helper covering the contract-level questions:

- `isActiveForDate(cycle, businessDate)` — is the cycle active for a given business date?
- `canManagerOverride(cycle, businessDate)` — can the manager override this cycle on this date? Requires both: the cycle is active for the date, and the once-per-cycle override has not been used.
- `needsAutoRefresh(cycle, businessDate)` — is the business date past cycle end?
- `daysRemainingInCycle(cycle, businessDate)` — calendar days from businessDate to the cycle's effective end. Returns 0 on or after the effective end.

## Contract Rules

These match the architecture rules in `phase_7_55_target_cycle_weekly_plan_rules.md`:

1. One active cycle per restaurant at any time.
2. Cycle effective window is 60 days.
3. Manager can override once per cycle during the active window.
4. After the manager override is used, only admin can change the target before cycle end.
5. At the 60-day boundary, the app auto-switches to the next recommended cycle.
6. New closed shifts feed the next benchmark snapshot, not the current cycle.
7. Weekly plans auto-lock separately and are not part of this contract slice.
8. No intended UX change.

## What This Slice Does Not Do

- No SQLite schema or DAO (→ `7.55l.2`)
- No auto-refresh implementation (→ `7.55l.2`)
- No `ActiveTargetProfile` projection from cycle (→ `7.55l.4`)
- No consumer migration (→ `7.55l.7`)
- No weekly plan logic (→ `7.55l.6`)
- No UX change

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Gate verdict: `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
