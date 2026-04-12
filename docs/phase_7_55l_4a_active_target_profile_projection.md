# Phase 7.55l.4a - ActiveTargetProfile Projection From TargetCycle

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented — projection sync only, no consumer migration

## Purpose

Make `ActiveTargetProfile` persist as a projection of the current
`TargetCycle` whenever the cycle layer creates or replaces a cycle.

This aligns runtime standards persistence under the cycle architecture
without changing manager UX and without starting full consumer migration.

## What This Slice Adds

### TargetCycleActiveTargetProfileProjector

A pure projector that converts a `TargetCycle` to an `ActiveTargetProfile`:

- Maps standards fields directly: CPLH, SPLH, PPA, wages, OPZ bounds
- Derives `sourceType` from `TargetCycleSource`:
  - `recommended` -> `'cycle_recommended'`
  - `managerOverride` -> `'cycle_manager_override'`
  - `adminReplacement` -> `'cycle_admin_replacement'`
- Computes theoretical labor percentages using the standard formulas:
  - `theoreticalFohLaborPct = fohWage / (targetCPLH * targetPPA) * 100`
  - `theoreticalBohLaborPct = bohWage / targetSPLH * 100`
  - `theoreticalLaborPct = foh + boh`
- Sets `targetProfileId` to `'{restaurantId}_active'`
- Sets `builtAt` to current UTC timestamp

No persistence, no side effects — pure projection only.

### TargetCycleService Profile Sync

After every cycle write path, the service now projects the cycle to
`ActiveTargetProfile` and persists it through the existing
`TargetProfileRepository`:

- initial recommended cycle creation
- auto-refresh cycle creation
- manager override replacement
- admin replacement

This is done via a private `_syncActiveTargetProfile(cycle)` method
called after each `upsertCycle`.

## Transitional Bridge Reality

This slice adds cycle-projected profile writes but does NOT yet remove
all direct active-profile writes elsewhere:

- `BaselineManagerService._persistActiveTargetProfile()` still writes
  the profile on selection changes and `primeManagerOverride()` calls
- `WageStandardContextService.syncWagesToActiveProfile()` still writes
  on wage resolution
- `WageStandardContextService.loadOrBootstrapProfile()` still
  bootstraps on profile-missing paths

These are transitional bridge paths. Consumer migration (7.55l.7) and
bridge retirement (7.55l.8) will consolidate authority under the cycle
layer. Until then, both paths coexist — the cycle layer writes the
profile on cycle events, and the bridge paths write on their own events.

This is documented honestly as transitional state, not as final
architecture.

## What This Slice Does Not Do

- No Benchmark UI/save-flow wiring
- No `BaselineManagerService.saveSelection` integration
- No consumer migration (-> 7.55l.7)
- No bridge-era write removal (-> 7.55l.8)
- No weekly plan logic (-> 7.55l.6)
- No UX change
- No tracker file changes

## Cross-References

- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Override write path: `docs/phase_7_55l_3a_target_cycle_override_write_path.md`
- TargetCycle model: `lib/domain/models/target_cycle.dart`
- ActiveTargetProfile model: `lib/domain/models/active_target_profile.dart`
- Projector: `lib/domain/services/target_cycle_active_target_profile_projector.dart`
- TargetCycleService: `lib/data/target_cycle_service.dart`
