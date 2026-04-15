# Phase 7.55l.8d - Learn Active-Profile-Without-Cycle Recovery

Updated: 2026-04-12
Owner: Codex planning / tracker truth
Status: Implemented

## Purpose

Remove the last production-shaped Learn compatibility bridge by replacing
the "profile exists but cycle is missing" fallback path with explicit
cycle recovery.

Before this slice, when an active profile existed but no active cycle was
found, `LearnBenchmarkContextService` silently fell back to
`BaselineSelectionAnalyticsService.resolve(...)` for selection analytics.
That kept bridge-era benchmark analytics alive in a production-shaped path.

## What This Slice Changes

### Profile-Without-Cycle Recovery

When an active profile exists but no active cycle is found, the service
now treats this as a recoverable app-state inconsistency:

1. Resolves the current benchmark anchor date using the same precedence
   as other benchmark manager logic:
   - Mock replay business date (first choice)
   - Latest closed business date (fallback)
2. Calls `TargetCycleService.getOrCreateActiveCycle(restaurantId, anchorDate)`
   to recover or create the active cycle
3. Re-reads the active profile after recovery (since cycle creation also
   projects and persists a fresh `ActiveTargetProfile`)
4. Continues on the canonical cycle/summary path

If no anchor date is available (no mock replay date and no closed shifts),
the service throws an explicit `StateError` instead of silently falling
back to bridge analytics.

### Post-Recovery Authority

After cycle recovery:
- The active profile is re-read to reflect the freshly projected values
- If the post-recovery profile re-read returns null, the service throws
  an explicit `StateError` instead of silently proceeding with stale
  pre-recovery profile values (7.55l.8d1 tightening)
- The cycle/summary path proceeds as normal (including 8c1 summary
  backfill if the newly created cycle lacks a persisted summary)
- The returned `LearnBenchmarkContext` reflects the recovered canonical
  authority, not stale pre-recovery values

### Test Injection Seams

Two new per-repo test overrides added for recovery-path testing:
- `testGetAnchorDate`: controls what anchor date is available for recovery
- `testRecoverCycle`: controls what `getOrCreateActiveCycle` returns

These enable testing the recovery logic without SQLite, alongside the
existing per-repo overrides from 8c1.

## What This Slice Does Not Do

- No manager UX redesign
- No Learn screen layout changes
- No History pattern analysis changes
- No Schedule / Shift / Variance / History behavior changes
- No SQLite schema changes
- No target math or formula changes
- No tracker file changes

## Remaining Bridge

`BaselineData` bridge is now limited to:

- Explicit bridge-only mode (widget tests)
- Genuine no-profile bootstrap (first launch before any cycle or profile)

The profile-without-cycle state is no longer a bridge fallback — it is
an explicit recovery path that repairs the cycle gap and then uses
canonical persisted authority.

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Compatibility bridge scope: `docs/phases/phase_8_gate/compatibility_bridge_scope.md`
- Prior slice: `docs/archive/phases/7_55l/phase_7_55l_8c_benchmark_selection_summary_persistence.md`
- LearnBenchmarkContextService: `lib/data/learn_benchmark_context_service.dart`
- TargetCycleService: `lib/data/target_cycle_service.dart`
