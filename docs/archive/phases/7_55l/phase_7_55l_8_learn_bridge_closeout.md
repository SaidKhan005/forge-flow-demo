# Phase 7.55l.8 - Learn Bridge Closeout

Updated: 2026-04-12
Owner: Codex planning / tracker truth
Status: Complete

## Purpose

Close the Learn bridge-retirement lane by documenting the actual runtime
truth after `7.55l.8a` through `7.55l.8d1`, removing stale planning/gate
claims, and tightening code comments to match post-8d reality.

## What Is True Now

### Learn production runtime no longer depends on bridge-era BaselineData

`LearnTeachingAnalyzer` does not read `BaselineData`. It accepts an
injected `LearnBenchmarkContext` resolved by `LearnBenchmarkContextService`.

The canonical Learn authority chain is:

```text
ActiveTargetProfile (persisted)
  -> source label + target CPLH / SPLH / PPA
TargetCycle (persisted, active or recovered)
  -> cycle identity for summary lookup
BenchmarkSelectionSummary (persisted, tied to the active cycle)
  -> selected shift count + range quality label + range quality message
```

### Recovery paths are repair paths, not steady-state truth

| Recovery path | When it fires | What it does |
|---|---|---|
| Missing cycle (8d) | Active profile exists but no active cycle | Resolves anchor date, calls `getOrCreateActiveCycle`, re-reads profile |
| Missing summary (8c1) | Active cycle exists but no persisted summary | Computes compatibility analytics, materializes + persists a summary |
| Post-recovery profile enforcement (8d1) | Cycle recovery succeeds but post-recovery profile re-read is null | Throws explicit `StateError` |
| No anchor date (8d) | No mock replay date and no closed shifts | Throws explicit `StateError` |

Each recovery fires once and persists the result. Subsequent reads use
the canonical persisted path.

### Remaining Learn bridge use is intentionally narrow

| Bridge surface | When it fires | Why it exists |
|---|---|---|
| Explicit bridge-only mode | `enableBridgeOnly()` called (widget tests) | Widget tests run without SQLite |
| Genuine no-profile bootstrap | First launch before any cycle or profile | No persisted authority exists yet |

These are the only paths where `LearnBenchmarkContextService.resolve()`
returns `BaselineData`-sourced values. Both are intentional and documented.

### BaselineSelectionAnalyticsService role is narrowed

After `7.55l.8c` persisted `BenchmarkSelectionSummary` at cycle-build time,
the analytics service is no longer the steady-state resolution path for
Learn. Its current role:

- Override-driven analytics (manager_override / cycle_manager_override)
  from persisted selected-key state
- Compatibility recovery input for the one-time summary backfill (8c1)
  when a cycle exists but its summary is missing
- Explicit bridge-only mode for widget tests

## What This Slice Changed

### Documentation

- Created this closeout doc
- Updated `compatibility_bridge_scope.md`: removed stale
  `LearnTeachingAnalyzer` bridge classification, added honest description
  of the remaining `LearnBenchmarkContextService` narrow bridge surfaces
- Updated `phase_7_55j_gate_integration_readiness_pressure_test.md`: marked
  the Learn bridge retirement red blocker as closed, updated yellow bridge
  table to reflect the narrowed Learn bridge scope
- Updated `phase_7_55j_1_codebase_feature_inventory.md`: updated Learn
  section to reflect current truth

### Code comments

- Updated `BaselineSelectionAnalyticsService` header comments to reflect
  post-8d reality: default/system path is now compatibility recovery input,
  not the steady-state Learn resolution path
- No runtime behavior changes

## What This Slice Does Not Do

- No manager UX redesign
- No Learn screen layout changes
- No runtime behavior changes
- No Schedule / Shift / Variance / History behavior changes
- No SQLite schema changes
- No target math or formula changes
- No tracker file changes

## Completion Summary

The Learn bridge-retirement lane (`7.55l.8a` through `7.55l.8`) is now
complete:

| Slice | What it retired |
|---|---|
| `7.55l.8a` / `8a1` | Source label + target metrics off production `BaselineData`; `LearnTeachingAnalyzer` no longer reads `BaselineData` |
| `7.55l.8b` / `8b1` | Selection analytics off production `BaselineData`; source-aware resolution |
| `7.55l.8c` / `8c1` | Persisted `BenchmarkSelectionSummary` at cycle-build time; one-time backfill for missing summaries |
| `7.55l.8d` / `8d1` | Profile-without-cycle recovery; post-recovery profile enforcement |
| `7.55l.8` | Stale doc cleanup; code comment tightening; honest closeout |

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Compatibility bridge scope: `docs/phases/phase_8_gate/compatibility_bridge_scope.md`
- Prior slices:
  - `docs/archive/phases/7_55l/phase_7_55l_8a_learn_source_target_migration.md`
  - `docs/archive/phases/7_55l/phase_7_55l_8b_learn_selection_analytics_migration.md`
  - `docs/archive/phases/7_55l/phase_7_55l_8c_benchmark_selection_summary_persistence.md`
  - `docs/archive/phases/7_55l/phase_7_55l_8d_learn_profile_cycle_recovery.md`
- LearnBenchmarkContextService: `lib/data/learn_benchmark_context_service.dart`
- BaselineSelectionAnalyticsService: `lib/data/baseline_selection_analytics_service.dart`
- LearnTeachingAnalyzer: `lib/services/learn_teaching_analyzer.dart`
