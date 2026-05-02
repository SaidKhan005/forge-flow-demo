# Replay Readiness Matrix

Fixture/replay and state-readiness scenarios the app should satisfy before Phase 8.

## Scenario Matrix

| Scenario | Expected App Behavior | Current Repo Evidence | Evidence Source | Status | Remaining Gap |
| --- | --- | --- | --- | --- | --- |
| Fixture mode | App runs end to end from seeded fixture data without screen-level demo constants | Shift, WTD, Full Week, History, and Learn read paths load from persisted/query-backed state after reseedDemo() | test/current_state_alignment_test.dart group D | Yes | None |
| No data | App resolves to no_data status when no shifts, history, or open state exist | AppDataStatusService.evaluate() returns noData after clearing all tables | test/app_data_status_test.dart group A | Yes | None |
| Partial data | App shows WTD from partial-week closed shifts only | WTD rollup uses only closed shifts; partial-week model-hour math is tested | test/wtd_variance_logic_test.dart partial-week group | Yes | None |
| Stale data | App resolves to stale status when current-state timestamps exceed threshold | AppDataStatusService.evaluate() with injected now detects stale open-snapshot timestamps | test/app_data_status_test.dart group D | Yes | None |
| Failed import | App resolves to failed_import status when latest import run has status = failed | AppDataStatusService.evaluate() returns failedImport with error summary | test/app_data_status_test.dart group C | Yes | None |
| Historical-only cold start | App resolves to historical_only when history exists but no current-week open state | AppDataStatusService.evaluate() returns historicalOnly after clearing open snapshots | test/app_data_status_test.dart group B | Yes | None |
| Historical + partial current week | App shows WTD from closed shifts plus open/projected snapshots | Full-week merge logic combines closed shift_records and open_shift_snapshots | test/current_state_alignment_test.dart group C | Yes | None |
| Intraday live update | Open shift snapshot replacement updates persisted current state and flows through query paths | replaceOpenShiftSnapshot updates persisted state; full-week merge reflects new values | test/app_data_status_test.dart group F | Yes | None |
| Close-shift replacement | Closing a shift replaces the projected slot atomically | ShiftService.closeShift replaces the projected slot and locks target truth | test/shift_service_close_shift_test.dart test 1 | Yes | None |
| Manager override applied | Override writes a replacement cycle, then projects the active target profile and refreshes open/future state | BaselineManagerService.saveSelection routes through TargetCycleService.applyManagerOverrideCycle(...); ActiveTargetProfileNotifier refreshes the projected profile | test/active_target_profile_notifier_test.dart group B; test/target_state_alignment_test.dart group B | Yes | None |
| Manager override cleared | Clearing override restores the cycle-backed recommended profile | BaselineManagerService.saveSelection({}) restores `cycle_recommended` via `restoreRecommendedCycle(...)` | test/active_target_profile_notifier_test.dart group B; test/target_state_alignment_test.dart group B | Yes | None |

## Evidence Summary

- Structural fixture replay: Proven in code and tests.
- Close-shift locking: Proven. Closed shifts lock target truth immutably.
- Override propagation: Proven. Active target profile changes propagate through persisted notifier path.
- No-data / stale / failed / historical-only states: Proven. AppDataStatusService evaluates from persisted state with deterministic thresholds.
- Intraday live updates: Proven. Open-snapshot replacement updates persisted state and flows through query-backed read paths.
- Schedule active-target authority: Proven. ScheduleForecastNotifier uses injected active-target values.
- Runtime read-path independence from demo constants: Proven. StaticShiftDataSource reads BaselineData constants (bridge proof — test/replay_integrity_audit_test.dart group C). Production surfaces route through SQLite, not demo constants — end-to-end SQLite-backed proof (reseedDemo -> query -> correct output) is now verified in groups A, B, E (restored in 7.55n.13 after the snapshot_blended_wage schema gap was fixed).
- Compatibility profile helper: Proven. `buildActiveTargetProfileFromBaseline(...)` still reads `BaselineData`/`MeridianConfig` in pure-test coverage, but the live seeded/bootstrap path now prefers cycle projection and `primeManagerOverride()` no longer rewrites the persisted profile. See `test/replay_integrity_audit_test.dart` group D for the helper proof.

## Runnable Flutter Proof

**Status: Restored (7.55n.13).**

The `snapshot_blended_wage` schema column gap has been fixed (V20
migration). All previously blocked SQLite-backed tests now pass:

- `test/replay_integrity_audit_test.dart`: 22/22 passed (groups A, B, E restored)
- `test/current_state_alignment_test.dart`: 35/35 passed
- `test/mock_replay_scenario_test.dart`: 34/34 passed
- `test/app_data_status_test.dart`: 9/9 passed
- `test/shift_dashboard_notifier_test.dart`: 8/8 passed

Previously: all 28 test files passed when run one file at a time via
`scripts/run_phase8_gate_tests.ps1 -ContinueOnFailure` on Windows
desktop with sqflite_common_ffi. 28/28 PASSED, 0 FAILED. Re-verified
post-7.52c file renames and fixture target-field backfill.

Note: running all test files in a single `flutter test` invocation can
produce SQLite file-locking failures due to the desktop FFI test runner
sharing the database file across isolates. Each file passes
deterministically when run individually.
