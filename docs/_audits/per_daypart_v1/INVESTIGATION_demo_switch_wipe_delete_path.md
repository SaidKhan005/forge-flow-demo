# INVESTIGATION — demo location-switch wipe: the actual delete path

Read-only code investigation. Master = `e8601d5b` (includes #827/#828/#829).
Question: what code path produces the device-observed `684 → 171 → 0`
`open_shift_snapshots` signature on a demo scope switch, and why did
#829 (swapping `crossTenantWipe`) not change device behavior?

## TL;DR — definitive conclusion

The operative delete is **`defaultCrossTenantWipe` (single-keep
`deleteForOtherRestaurants` / `wipeForOtherScopes`) invoked through
`MobileOperationalSyncHost._handleBusinessScopeChanged →
_wipeOtherTenantsThenSync → widget.crossTenantWipe(scope.locationId)`**
(`lib/services/sync/mobile_operational_sync_runtime.dart:489-504,
477-487, 190-215`; DAO `lib/infrastructure/persistence/sqlite/dao/
open_shift_snapshot_dao.dart:102-108` `DELETE ... WHERE restaurant_id
!= ?`). This is the ONLY runtime path that yields the exact
"keep ONLY the newly-active `restaurant_id`, delete every other
`restaurant_id`" single-keep signature on a drawer switch with no
proxy data.

`PostgresShiftRecordToMobileSync.sync(...)` is **NOT** the deleter
(it only per-row upserts and writes nothing when the proxy returns
zero rows), and it never even runs in the demo flavor (the demo build
passes a `null` `syncClient` to the host, so `_runner == null` and
`_syncForCurrentSession` returns at
`mobile_operational_sync_runtime.dart:515` before any sync). Reseed /
`clearAllData` are not on the switch/refresh path. Pull-to-refresh
(`lib/screens/shift_dashboard.dart:108-117`) only calls
`notifier.refresh()` (read-only); it deletes nothing. The `→ 0` is
just the same single-keep wipe firing again on each subsequent switch
with nothing (no proxy) to re-materialize the wiped locations.

**Why #829 had ZERO device effect:** #829 is provably correct *and*
correctly wired in source on `e8601d5b` — the demo branch
(`lib/main_forgeflow.dart:151`) passes
`demoScopePreservingCrossTenantWipe` into
`bootstrapAndRunApp(crossTenantWipe:)`, which threads it to the single
`MobileOperationalSyncHost` (`lib/forge_flow_bootstrap.dart:130-137`,
`crossTenantWipe ?? defaultCrossTenantWipe`). Static analysis shows
the demo host *should* receive the preserving wipe (keep-set =
`{newLoc} ∪ DemoScope.locations` = all 4 → deletes nothing for demo
scopes). Since the device behavior is byte-identical before AND after
#829, and the source wiring is correct, the only explanation
consistent with all evidence is that **the tested APK did not execute
the `e8601d5b` `main_forgeflow.dart` / runtime code** — i.e. a stale
or incremental Flutter/Gradle build that reused a cached Dart kernel
from a pre-#829 (no-`crossTenantWipe`) `main_forgeflow.dart`, where the
demo branch's `bootstrapAndRunApp` passed no wipe and the host fell
back to the constructor default `defaultCrossTenantWipe`
(`mobile_operational_sync_runtime.dart:324`). #829's unit test
(`test/mobile_operational_sync_demo_scope_preserving_wipe_test.dart`)
passing is consistent with this: it calls
`demoScopePreservingCrossTenantWipe` / `defaultCrossTenantWipe` as
bare functions and **never mounts the host, never runs
`main_forgeflow.dart`, never exercises the bootstrap→host wiring or
the `ActiveBusinessScopeChangeBus` trigger** — so it proves the
function is correct in isolation but proves nothing about runtime
reachability.

## Ranked candidate delete paths

### #1 (OPERATIVE) — host cross-tenant wipe, single-keep
- Trigger (a): drawer tap → `lib/forge_flow_app.dart:1087`
  `_selectBusinessScope` → `lib/state/restaurant_scope_notifier.dart:167`
  `activateBusinessScope` → `:177`
  `ActiveBusinessScopeChangeBus.instance.publish(scope)`.
- `lib/services/scope/business_scope_repository.dart:23-38` — process
  singleton broadcast stream. Sole subscriber:
  `mobile_operational_sync_runtime.dart:365-366`
  (`_handleBusinessScopeChanged`).
- `mobile_operational_sync_runtime.dart:489-504`
  `_handleBusinessScopeChanged`: `scope.isLocationScope` true,
  `session != null` (demo "Use demo operator" sign-in →
  `lib/services/auth/demo_auth_login_service.dart:123-126`,
  `locationId = kDemoOperatorLocationId = demo_restaurant_001`),
  `key != _lastBusinessScopeKey` (first switch: `_lastBusinessScopeKey`
  null) → `_wipeOtherTenantsThenSync(session.copyWith(locationId:
  scope.locationId), 'business_scope_changed')`.
- `:477-487` `_wipeOtherTenantsThenSync` → `await
  widget.crossTenantWipe(session.locationId)` where
  `session.locationId == scope.locationId` (the NEW location, e.g.
  `demo_restaurant_riverside`).
- `widget.crossTenantWipe`:
  - **pre-#829 build (no `crossTenantWipe` arg in `main_forgeflow.dart`
    demo branch): constructor default `defaultCrossTenantWipe`**
    (`:324`, `:190-215`) → `SqliteOpenShiftSnapshotRepository
    .wipeForOtherScopes(keep)` (`sqlite_open_shift_snapshot_repository
    .dart:72-75`) → `OpenShiftSnapshotDao.deleteForOtherRestaurants`
    (`open_shift_snapshot_dao.dart:102-108`) →
    `DELETE FROM open_shift_snapshots WHERE restaurant_id != 'demo_
    restaurant_riverside'`. **Exactly the device 684 → 171 single-keep
    signature**, replicated across all 8 repos / 9 tables.
  - on-`e8601d5b` build:
    `demoScopePreservingCrossTenantWipe`
    (`mobile_operational_sync_runtime.dart:253-270`) — keep-set
    `{riverside} ∪ DemoScope.locations` (`sqlite_database.dart:104-130`,
    all 4 ids) → `deleteForRestaurantsNotIn` deletes 0 demo rows. This
    is the FIX; it would change device behavior IF executed.
- Scope semantics: `WHERE restaurant_id != keep` (single-keep,
  unconditional purge of every other tenant). With no demo proxy sync
  to re-seed, the 3 non-active demo locations are destroyed → Shift
  "HISTORICAL ONLY". Repeated switches drive every table to 0.
- Trigger (b) pull-to-refresh: does NOT reach this path. It calls only
  `ShiftDashboardNotifier.refresh()` / `ShiftServicePeriodNotifier
  .refresh()` (`shift_dashboard.dart:100-117`) — read-only reloads. The
  `→ 0` is subsequent *switches*, not the refresh itself.

### #2 (NOT operative) — `PostgresShiftRecordToMobileSync.sync`
`lib/services/sync/postgres_shift_record_to_mobile_sync.dart:485-764`.
- No table-wide delete of the 8 wipe tables. `shift_records` /
  `open_shift_snapshots` are written via per-row
  `replaceShiftForSlot` / `replaceOpenShiftSnapshot` (`:589`, `:625`)
  — each a scoped `txn.delete(... WHERE restaurant_id=? AND week_id=?
  AND day_label=? AND daypart=?)` then `insert` of the SAME row
  (`open_shift_snapshot_dao.dart:51-66`). Zero rows from the proxy ⇒
  zero writes ⇒ **no purge** (the loop simply ends on
  `nextCursor == null`; an empty page deletes nothing).
- Only replace-ALL calls are `wageRoleRowRepository.replaceAll`
  (`:709`) and `dataAccuracyServicePeriodSettingsCacheRepository
  .replaceAll` (`:733`) — both `restaurantId`-scoped, and neither is
  one of the 8 wipe tables driving the 684 signature.
- In the demo flavor this method never executes: demo
  `bootstrapAndRunApp` passes no `syncProxyClient`
  (`main_forgeflow.dart:135-152`), so the host's `syncClient` is null,
  `_ensureRunner` leaves `_runner == null`
  (`mobile_operational_sync_runtime.dart:413-420`), and
  `_syncForCurrentSession` returns at `:515`. The demo
  `DemoVendorIntegrationModeStateSyncProxyClient`
  (`lib/dev/demo_vendor_integration_sync_proxy_client.dart`) is wired
  ONLY into `DemoModeStateNotifier` via
  `forge_flow_app.dart:799-806 _resolveSyncProxyClient`, never into the
  sync host (its `noSuchMethod` throws for any non-`fetchDemoModeStates`
  call). Sync is not the deleter.

### #3 (NOT on switch path) — reseed / clearAllData (table-wide, unconditional)
- `sqlite_database.dart:644-755` `reseedMockReplayForBusinessDate`:
  unconditional `db.delete('shift_records')` (`:650`),
  `db.delete('open_shift_snapshots')` (`:657`), etc. (NO
  `restaurant_id` filter — wipes all 4), then regenerates ALL 4 via
  `_seedDemoDataFromReplay` + `_seedAdditionalLocationsFromReplay`
  (`sqlite_database_seed.dart:1676-1768, 1524-1674`). Net result of a
  full reseed is 4 locations repopulated (≈684), NOT single-keep —
  does not match the device signature.
- `sqlite_database.dart:759-778` `clearAllData`: unconditional
  table-wide delete, no reseed. Would yield 0 for ALL locations
  immediately (not 684→171).
- `sqlite_database_seed.dart:1688-1692` (`_seedDemoDataFromReplay`):
  `db.delete('shift_records' WHERE restaurant_id = DemoScope
  .restaurantId)` — Downtown-only, then re-inserts. Not single-keep.
- Callers: `lib/screens/settings/settings_data_sections.dart:240,350`
  (Settings "Data reset"/"Demo date"), `lib/services/shift_service
  .dart:1239-1277` (advance). **None reachable from a drawer location
  switch or pull-to-refresh.** Verified: the only
  `ActiveBusinessScopeChangeBus.changes` subscriber is the sync host
  (no reseed), and `RestaurantScopeNotifier`/`ShiftDashboardNotifier`/
  `AppRefreshCoordinator`/`CurrentStateBoundaryMonitor` perform no
  deletes (refresh/notify only — `app_refresh_coordinator.dart:83-127`,
  `current_state_boundary_monitor.dart` whole file).

### #4 (NOT a deleter) — #828 scope-refresh wiring
`forge_flow_app.dart` `_handleScopeChangedForRefresh` /
`_scheduleScopeDataRefresh` (added by #828) only calls
`AppRefreshCoordinator.refreshAll()` → notifier `.refresh()` /
`.load()`. No delete. Confirmed via `git show 5c3fc74c`.

## Why #829 is correct-but-(apparently)-not-reached — evidence

1. `git show e8601d5b -- lib/services/sync/mobile_operational_sync_
   runtime.dart` is **purely additive** (+55, only the new
   `demoScopePreservingCrossTenantWipe`). It does NOT alter
   `_handleBusinessScopeChanged` / `_handleAuthChanged` /
   `_wipeOtherTenantsThenSync`, which already existed pre-#829 and
   already routed through `widget.crossTenantWipe`.
2. `git show e8601d5b~1:lib/main_forgeflow.dart` has **no
   `crossTenantWipe` argument anywhere** — the pre-#829 demo branch's
   `bootstrapAndRunApp` (then line 134) passed no wipe, so the host
   used the constructor default `defaultCrossTenantWipe` (single-keep).
   #829 added `main_forgeflow.dart:151
   crossTenantWipe: demoScopePreservingCrossTenantWipe`.
3. On `e8601d5b` there is exactly ONE `MobileOperationalSyncHost(...)`
   construction (`forge_flow_bootstrap.dart:130`); it receives
   `crossTenantWipe ?? defaultCrossTenantWipe`, and the demo branch
   passes the preserving wipe. Static wiring is correct.
4. `DemoScope.locations` (`sqlite_database.dart:104-130`) contains all
   four ids (`demo_restaurant_001`, `_north_loop`, `_riverside`,
   `_harbour`); the demo seed populates all four (device cold boot =
   684 confirms #827 seed ran ⇒ the DB file was freshly created with
   #827+ code). So the preserving keep-set genuinely covers all four.
5. #829's regression test mounts no widget, runs no
   `main_forgeflow.dart`, and never publishes to
   `ActiveBusinessScopeChangeBus`; it calls the two wipe functions
   directly. Green ≠ runtime-wired.

Given (1)-(5), the source on `e8601d5b` would preserve all 4 demo
locations at runtime. The device showing the identical pre-#829
single-keep `684→171→0` means the host that handled the scope-change
event used `defaultCrossTenantWipe`, i.e. the running binary did not
contain #829's `main_forgeflow.dart` (and likely not #828/#829's
runtime). Most probable: an incremental `flutter build apk` that
reused a cached kernel/AOT artifact compiled from a pre-#829
`main_forgeflow.dart`, OR the build/run targeted a branch/worktree
without #829. The bug is real, the fix is correct, the fix path is
correctly wired in source — the gap is build/deploy provenance, not a
second hidden delete path.

## Runtime instrumentation that would prove it definitively

If a clean rebuild still reproduces, add (do NOT commit) these
`debugPrint`s and reproduce once:

1. `lib/forge_flow_bootstrap.dart` ~line 131-135, inside the
   `MobileOperationalSyncHost(...)` argument list, log the identity of
   the wipe actually passed:
   `debugPrint('[WIPE-WIRE] crossTenantWipe=${(crossTenantWipe ??
   defaultCrossTenantWipe) == demoScopePreservingCrossTenantWipe
   ? "DEMO-PRESERVING" : "DEFAULT-SINGLE-KEEP"}');`
2. `lib/services/sync/mobile_operational_sync_runtime.dart:480`
   (`_wipeOtherTenantsThenSync`, before `await
   widget.crossTenantWipe(...)`):
   `debugPrint('[WIPE-FIRE] reason=$reason keep=${session.locationId}
   fn=${widget.crossTenantWipe == demoScopePreservingCrossTenantWipe
   ? "DEMO-PRESERVING" : "DEFAULT"}');`
3. `lib/infrastructure/persistence/sqlite/dao/open_shift_snapshot_dao
   .dart:103` and `:124` (both delete methods): log
   `await`-result row count, e.g.
   `final n = await _db.delete(...); debugPrint('[WIPE-DAO]
   open_shift_snapshots single-keep deleted=$n keep=$keepRestaurantId');`
   (and the analogous `deleteForRestaurantsNotIn`).
4. `lib/state/restaurant_scope_notifier.dart:177`
   (before `ActiveBusinessScopeChangeBus.instance.publish(scope)`):
   `debugPrint('[SCOPE-PUB] ${scope.scopeType}:${scope.scopeId}');`

`[WIPE-FIRE]` printing `fn=DEFAULT` on a demo build is the proof the
running binary lacks #829's `main_forgeflow.dart` wiring (build
provenance). `[WIPE-DAO] ... single-keep deleted=513` confirms the
single-keep DAO is the deleter. If `[WIPE-FIRE]` never prints but rows
still vanish, an unaccounted path exists (none found in code).
