# Phase 7.55p.4c — Replay Integrity / Mock-to-Live Transition Audit

Status: Landed

## Goal

One explicit answer to the mock-to-live question: what is already
query-backed and integration-friendly, what is still mock/demo/bridge
owned, and whether the repo can honestly claim simple-swap live
readiness.

## Scope

- In: seam-by-seam audit classifying every current runtime surface as
  query-backed, allowed bridge, or real blocker; focused tests proving
  bridge-ownership claims (pure tests) and documenting SQLite-backed
  read-path assertions pending schema fix; honest update of Phase 8
  gate readiness docs
- Out: building Phase 8 adapters; removing the replay/demo path;
  redesigning Shift/Variance/History/Learn business logic; notifications;
  OPZ; extraction work

## Audit Questions

1. Which runtime surfaces already read persisted/query-backed state
   after replay reseed?
2. Which seams are still demo/mock/bridge owned?
3. Is the repo truly ready for "simple swaps"?
4. Where does replay integrity or mock-to-live transition risk remain?

## Seam Classification

### Query-backed and integration-friendly

These surfaces route through SQLite repositories after reseed (confirmed
by code inspection). Phase 8 replaces transport only — no read-path
changes needed.

Note: the SQLite-backed test evidence cited below previously passed but
is currently blocked by the `snapshot_blended_wage` schema column gap.
The code paths have not changed — only the test runner cannot exercise
them until the schema is fixed.

| Surface | Read Path | Prior Evidence (currently blocked) |
|---|---|---|
| Shift current-state | `ShiftDashboardNotifier` -> `ShiftService.getShiftDashboard()` -> `SqliteOpenShiftSnapshotRepository` + `SqliteShiftRecordRepository` | test/current_state_alignment_test.dart group B |
| Variance WTD | `WeekDataNotifier` -> `LiveShiftDataSource` -> `ShiftService.getLiveWeekToDate()` -> locked `WeeklyPlanSnapshot` + `TargetCycle` + `ShiftRecord` via SQLite | test/current_state_alignment_test.dart groups E, H |
| Variance Full Week | `ShiftService.getFullWeekShifts()` -> `SqliteShiftRecordRepository` + `SqliteOpenShiftSnapshotRepository` -> merged via `CurrentWeekState` | test/current_state_alignment_test.dart groups C, F, I |
| History week list | `ShiftService.getWeekHistory()` -> `SqliteWeekRecordRepository` | test/current_state_alignment_test.dart group D |
| History patterns | `ShiftService.getHistoryPatternRecords()` -> `SqliteShiftRecordRepository` | test/current_state_alignment_test.dart group D |
| Active target profile (runtime) | `ActiveTargetProfileNotifier` -> `SqliteTargetProfileRepository` | test/active_target_profile_notifier_test.dart |
| Target cycle | `SqliteTargetCycleRepository` | test/mock_replay_scenario_test.dart group E |
| Weekly plan snapshot | `WeeklyPlanSnapshotService` -> `SqliteWeeklyPlanSnapshotRepository` | test/mock_replay_scenario_test.dart groups E, F |
| Demand forecast context | `DemandForecastContextNotifier` -> `DemandForecastContextService` -> closed shifts via SQLite | test/mock_replay_scenario_test.dart group F |
| App data status | `AppDataStatusService.evaluate()` -> `SqliteOpenShiftSnapshotRepository` + `SqliteShiftRecordRepository` + `SqliteImportTrackingRepository` | test/app_data_status_test.dart groups A-F |
| Schedule distribution weights | `ScheduleDistributionWeightsNotifier` -> closed shifts via SQLite | (notifier loads from repository) |
| Refresh / invalidation bus | `AppRuntimeInvalidationBus` -> `ProxyProvider2` -> `AppRefreshCoordinator.refreshCurrentStateSurfaces()` | test/app_runtime_invalidation_bus_test.dart |
| Learn (Repeatable Wins) | Evidence-backed from closed truth via `LearnTeachingAnalyzer` with injected `LearnBenchmarkContext` | (resolved from persisted cycle/profile/summary) |

### Allowed replay/demo bridge

These seams exist intentionally for the mock/replay/demo path. They are
the transport layer that Phase 8 replaces, or are test-only fallbacks.

| Seam | What It Does | Why It's Allowed | Retirement |
|---|---|---|---|
| `MockIntegrationReplaySeed` | Generates fixture shift/week/snapshot data and writes to SQLite through the same canonical tables | This IS the mock transport layer. Phase 8 replaces it with vendor adapter output writing to the same tables. | Phase 8 transport replacement |
| `StaticShiftDataSource` | Non-SQLite fixture source for widget tests that cannot use sqflite I/O | Not wired into app runtime — `ForgeFlowScope` provides `LiveShiftDataSource`. Widget-test-only. | Retire when widget tests migrate to repository-backed test harnesses |
| `LearnBenchmarkContextService` narrow fallback | Two bridge paths: explicit bridge-only mode for widget tests, no-profile bootstrap for first launch | Production path is fully persisted. Bridge surfaces are intentional and limited. | Bridge-only mode retires with widget test migration. No-profile bootstrap retires when app guarantees cycle/profile before Learn loads. |
| `ScheduleBuilder` initial-load fallback | Reads `BaselineData.derivedTarget*` during single-frame before profile loads | Immediately replaced by persisted values from `ActiveTargetProfileNotifier`. Not visible to users. | Replace with loading state. Non-blocking. |
| `ScheduleDay` / `DaypartForecast` | Legacy fixture data classes in `legacy_fixture_data.dart` | No longer consumed by visible Schedule surface (`ScheduleForecastNotifier` uses injected target values). | Remove entirely. Non-blocking. |

### Real blocker / follow-up debt

These seams prevent an honest "simple-swap ready" claim.

| Seam | What It Does | Why It Blocks | Follow-up |
|---|---|---|---|
| `SqliteDatabase.buildActiveTargetProfileFromBaseline()` | Reads `BaselineData` + `MeridianConfig` in-memory constants to build the initial persisted `ActiveTargetProfile` | Phase 8 vendor data must provide the source values (target CPLH/SPLH/PPA, wages, OPZ bounds). Until then, initial profile seeding depends on hardcoded constants. Runtime reads are already query-backed — only the seeding write is bridge-owned. | Replace with a profile builder that reads from persisted baseline-build state or from vendor adapter output |
| `BaselineData` / `MeridianConfig` source constants | Hardcoded in-memory constants that mock vendor-provided standard values | These are the actual source values (target metrics, wages, OPZ bounds) that would come from vendor calibration data. The app uses them during seeding and in bridge fallbacks. | Phase 8 vendor adapters replace these constants with real calibration data |
| `clearAllData()` bridge cleanup | Calls `BaselineData.clearHistoricalContext()` and `BaselineData.clearManagerOverride()` after wiping SQLite | Reaches into the compatibility bridge during data wipe. Needed while bridge exists. | Retire when `BaselineData` bridge is fully removed |
| Fixed 14-shift operating pattern | `MockIntegrationReplaySeed.weekSlots` hardcodes Mon-Sun shift pattern with exactly 14 slots | Real restaurants have variable patterns. This is baked into replay seeding, tests, UI copy ("14 shifts"), and some runtime calculations. | Already documented as cross-cutting debt in tracker guardrails. Phase 8/10 scope. |

## Is the repo simple-swap ready?

**No.** But the gap is narrow and well-classified.

### Transport replacement: ready

The internal path (SQLite -> repositories -> services -> notifiers -> UI)
is already canonical. Phase 8 replaces `MockIntegrationReplaySeed` with
real vendor adapters that write to the same SQLite tables. The runtime
invalidation bus (`7.55p.4b`) already supports write-completion signaling
from any writer, including future connectors.

### Runtime read-path: architecturally query-backed, verification blocked

Code inspection shows every production surface routes through
SQLite-backed query consumers after reseed. `LiveShiftDataSource`
delegates to `ShiftService` -> SQLite. `StaticShiftDataSource` exists
for widget tests only and is not wired into `ForgeFlowScope`.

However, the end-to-end SQLite-backed proof (reseedDemo -> query read
-> correct output) is currently blocked by the `snapshot_blended_wage`
schema column gap. The architecture direction is established; the
executable verification is pending. See audit blocker below.

### Remaining bridge/bootstrap debt

- `buildActiveTargetProfileFromBaseline()` reads from `BaselineData` /
  `MeridianConfig` constants during initial profile seeding. After
  seeding, the profile lives in SQLite and runtime reads don't touch
  the bridge. This is a write-time bootstrap dependency, not a
  read-time one.
- `BaselineData` and `MeridianConfig` remain the source of initial
  target/standard constants until vendor adapters provide real
  calibration data.
- Fixed 14-shift pattern is cross-cutting debt.

### Bottom line

The repo is **transport-replacement ready**. The runtime read-path is
**architecturally query-backed** but end-to-end SQLite proof is
**blocked** by the `snapshot_blended_wage` schema gap. It is NOT
**source-value ready** — the initial calibration values still come from
hardcoded constants instead of vendor data.

What is proven today:
- Bridge-ownership: `StaticShiftDataSource` reads `BaselineData`
  constants; `buildActiveTargetProfileFromBaseline` reads `BaselineData`/
  `MeridianConfig`. (test/replay_integrity_audit_test.dart groups C, D)
- Architecture direction: code inspection confirms production surfaces
  route through SQLite repositories, not demo constants.

What is not yet proven:
- End-to-end: reseedDemo -> SQLite query -> correct production read
  output. Blocked by schema gap. Tests are written and skipped in
  test/replay_integrity_audit_test.dart groups A, B, E.

## Audit Blocker Found

### `snapshot_blended_wage` schema column gap

`ShiftRecord.toMap()` includes `snapshot_blended_wage` but the
`shift_records` CREATE TABLE statement in `sqlite_database.dart` does
not have that column. This blocks all SQLite-backed tests that call
`reseedDemo()`, including `test/current_state_alignment_test.dart`,
`test/mock_replay_scenario_test.dart`, and the SQLite-dependent groups
in `test/replay_integrity_audit_test.dart`. The pure bridge-proof tests
(groups C and D) pass because they do not need SQLite reseed.

This is a pre-existing gap from uncommitted work in `shift_record.dart`
and `sqlite_database.dart`. Not caused by this audit. Must be fixed
before SQLite-backed tests can run again.

## Remaining Gaps

- `snapshot_blended_wage` schema column gap (see above)
- `7.55p.4d` — notifications (deferred)
- `7.55p.5` — Benchmark OPZ and graph honesty audit (deferred)
- `7.55o` — file extraction / engineering hygiene (deferred)
- `10.5` — live Shift service-period behavior (deferred)
- Fixed 14-shift debt — tracked in guardrails (cross-cutting)
