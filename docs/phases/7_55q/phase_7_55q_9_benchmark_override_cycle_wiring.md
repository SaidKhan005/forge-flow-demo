# Phase 7.55q.9 - Benchmark Override Cycle Wiring + Admin Reset

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed

## Goal

Close the divergence the earlier debug surfaced: the Baseline Manager
"Done" button writes only to `active_target_profiles` via the legacy
bridge path and never touches `target_cycles`. As a result:

- `target_cycles.target_cplh` drifts from `active_target_profiles.target_cplh`
  (Benchmark graph reads the cycle when no override is active; cards /
  Shift / Schedule / Variance / Learn read the profile — they disagree).
- The **once-per-60-day manager override rule is not enforced** —
  `managerOverrideUsed` stays `false` forever; managers can silently
  re-save daily.

Fix: route Done through `TargetCycleService.applyManagerOverrideCycle`
(which already enforces `canManagerOverride` + writes cycle + projects
profile via the `TargetCycleActiveTargetProfileProjector`). Add a
Settings affordance so the once-per-cycle lock can be cleared for
manual validation.

## Scope

- In: `BaselineManagerService.saveSelection` non-empty path now routes
  through `TargetCycleService.applyManagerOverrideCycle`; new
  `BaselineManagerService.resetForAdminTest()` orchestrator;
  `_done()` in `baseline_manager_screen.dart` catches
  `ManagerOverrideDeniedException` and surfaces a SnackBar (no
  Navigator pop on denial); new "Reset Target Cycle (Admin)" tile
  in `settings_screen.dart` under DATA MANAGEMENT; focused tests;
  this phase doc.
- Out: bootstrap-time `BaselineData` priming still exists as a
  compatibility bridge for graph/helper paths, but it no longer
  re-authors the persisted active profile.
- Out: tracker markdown updates.
- Out: any commit.

## Runtime seam

Before (drift):

```
Baseline Manager DONE
   └── BaselineManagerService.saveSelection(keys)
         ├── _baselineRepo.replaceSelectedRecordKeys     [persist keys]
         └── primeManagerOverride
               ├── BaselineData.applyManagerOverride     [in-memory bridge]
               └── _persistActiveTargetProfile
                     └── upserts active_target_profiles row
                           ↑ profile fresh; cycle untouched
                           ↑ once-per-cycle rule never enforced
```

After (`7.55q.9`):

```
Baseline Manager DONE
   ├── try BaselineManagerService.saveSelection(keys)
   │     ├── _baselineRepo.replaceSelectedRecordKeys     [persist keys]
   │     └── if non-empty:
   │           ├── businessDate = BusinessDateAuthorityService.resolvePlanningAnchorDate
   │           ├── TargetCycleService.applyManagerOverrideCycle(restaurantId, businessDate)
   │           │     ├── getOrCreateActiveCycle               [load / create]
   │           │     ├── canManagerOverride(current, businessDate)
   │           │     │     └── throws ManagerOverrideDeniedException if used
   │           │     └── _writeReplacementCycle
   │           │           ├── primeBaselineContextForDate    [in-memory bridge]
   │           │           ├── build explicit profile from
   │           │           │    selected cohort or recommended selection
   │           │           │    + resolved wages
   │           │           ├── upsert target_cycles           [cycle row]
   │           │           ├── _syncActiveTargetProfile       [projector → profile row]
   │           │           └── _persistSelectionSummary
   │           │                 ↑ cycle + profile in lockstep
   │           │                 ↑ managerOverrideUsed: true
   │           └── fire onActiveTargetChanged                 [UI refresh]
   └── catch ManagerOverrideDeniedException → SnackBar; do NOT pop
```

Settings → Reset Target Cycle (Admin):

```
SettingsScreen tile tap → confirm dialog → confirmed
   └── BaselineManagerService.resetForAdminTest()
         ├── replaceSelectedRecordKeys(restaurantId, {})       [clear keys]
         ├── BaselineData.clearManagerOverride / clearHistoricalContext
         ├── SqliteTargetCycleRepository.deactivateAllForRestaurant
         ├── TargetCycleService.getOrCreateActiveCycle         [fresh recommended cycle]
         │     └── _createRecommendedCycle → _syncActiveTargetProfile
         └── fire onActiveTargetChanged
               ↑ managerOverrideUsed: false → next override allowed
```

## Files touched

| File | Change |
|---|---|
| `lib/data/baseline_manager_service.dart` | Added imports for `target_cycle_service.dart` + `sqlite_target_cycle_repository.dart`. Rewrote `saveSelection` so non-empty selection routes through `TargetCycleService.applyManagerOverrideCycle` and empty selection restores recommended authority through `TargetCycleService.restoreRecommendedCycle` (firing `onActiveTargetChanged` after, since the cycle path doesn't fire it itself). Added `resetForAdminTest()` orchestrator that clears keys + bridge + active cycle, then calls `getOrCreateActiveCycle` to rebuild from recommendation. Later follow-up: `primeManagerOverride()` remains a BaselineData bridge only and no longer rewrites the persisted profile. |
| `lib/screens/baseline_manager_screen.dart` | Added import for `target_cycle_service.dart` (for `ManagerOverrideDeniedException`). `_done()` wraps `saveSelection` in `try / on ManagerOverrideDeniedException catch`; on denial, shows SnackBar with "Manager override already used for this 60-day cycle. Use Settings → Reset Target Cycle (Admin) to test again." and does NOT pop the screen. Success path unchanged. |
| `lib/screens/settings_screen.dart` | Added import for `baseline_manager_service.dart`. Added new `_SettingsTile` "Reset Target Cycle (Admin)" under DATA MANAGEMENT (after Clear All Data) with a confirm dialog; on confirm calls `BaselineManagerService.instance.resetForAdminTest()`, then `_refreshAfterWrite()`, then a SnackBar. |
| `test/target_state_alignment_test.dart` | Group B "sourceType becomes manager_override" updated to expect `cycle_manager_override` (the projector's mapping), with a comment naming the 7.55q.9 routing change. Group G now expects the seeded initial profile to already be `cycle_recommended`, matching the current cycle-backed bootstrap path. New group H proves: cycle and profile carry the same targetCPLH after Done; second Done in same cycle throws `ManagerOverrideDeniedException`; `resetForAdminTest` rebuilds a fresh cycle with `managerOverrideUsed: false` and lets the manager override again; direct `applyManagerOverrideCycle` after a Done also throws. |
| `test/baseline_manager_screen_test.dart` | New group T proves the Done denial UX: first Done lands cleanly via the existing helper; second Done in the same cycle surfaces a SnackBar with the "already used" copy + a pointer to the admin reset, and the screen does NOT pop. |
| `test/settings_screen_widget_test.dart` | New group "Settings 7.55q.9 admin reset tile" proves the tile renders with the admin description, opens a confirm dialog with the right copy + Cancel / Reset actions, and Cancel exits without action. The reset behaviour itself is covered service-side in `target_state_alignment_test.dart` group H. |
| `docs/phases/7_55q/phase_7_55q_9_benchmark_override_cycle_wiring.md` | **New** — this doc. |

## Files intentionally untouched

| File | Why |
|---|---|
| `lib/data/target_cycle_service.dart` | All the machinery this slice consumes (`applyManagerOverrideCycle`, `_writeReplacementCycle`, `getOrCreateActiveCycle`, `_syncActiveTargetProfile`, `ManagerOverrideDeniedException`) already exists from `7.55l.3a`. No change needed. |
| `lib/domain/services/target_cycle_active_target_profile_projector.dart` | Already produces the canonical projection; nothing to change. |
| `lib/data/wage_standard_context_service.dart` | Cycle-aware bootstrap/repair landed later; this q.9 slice itself did not need to change it. |
| `lib/data/legacy_fixture_data.dart` | `BaselineData` bridge stays as the in-memory cohort/context source for remaining compatibility helpers and graph hydration, but it is no longer used to author the canonical cycle-backed profile row. |
| `MeridianConfig` defaults / `StaticShiftDataSource` | Out of scope; load-bearing for tests. |
| Tracker markdown files | Per scope, no tracker updates. |

## Honest degradation

- **No active cycle yet** (fresh DB / clearAllData): `applyManagerOverrideCycle`'s
  internal `getOrCreateActiveCycle` creates a recommended cycle on the
  fly, so the first override always lands cleanly.
- **No business-date anchor**: `saveSelection` and `resetForAdminTest`
  throw a clear `StateError` ("cannot resolve planning anchor date").
  The Baseline Manager's existing error-free expectation around Done
  is preserved for the normal path.
- **Empty selection (clear)**: restores recommended-cycle authority
  through `restoreRecommendedCycle(...)`, preserving the once-per-cycle
  usage flag instead of mutating the profile directly.

## What this slice does NOT do

- Does not change product behaviour outside the Done / Settings tile
  paths.
- Does not weaken any assertion. The two updated tests in
  `target_state_alignment_test.dart` move from the legacy bridge
  source label (`'manager_override'`) to the canonical projector
  label (`'cycle_manager_override'`) — a tightening, not a loosening.
- Does not commit or update tracker markdown files.

## Remaining gaps

- **Bootstrap-time bridge priming still exists.** `primeManagerOverride()`
  still hydrates `BaselineData` for remaining graph/helper seams at app
  startup. It no longer re-authors the persisted profile, but the bridge
  itself is not fully retired.
- **Legacy helper/doc cleanup.** Compatibility helpers like
  `buildActiveTargetProfileFromBaseline(...)` still exist for pure-test
  coverage, and some older phase/gate docs need to be read as historical
  context rather than live authority.
