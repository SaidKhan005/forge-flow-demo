# PR #854 Audit — none-connected honest-EMPTY + connected Shift never blank

**Auditor:** Orchestrator. **Date:** 2026-05-16. **PR:** #854 (MERGED, squash →
`master` `b7d53df5`), branch `claude/demo-honest-empty-and-always-live-shift`,
+547/−52, 13 files (3 lib + 10 test). **Verdict: APPROVED — operator-signed-off,
merged, device-verified.**

## Operator decisions implemented
1. The "nothing-connected" demo location must be honest-EMPTY (no fabricated
   numbers) — not rich like the connected locations.
2. The demo Shift home must NEVER be blank on a connected location, at any
   wall-clock time.

## Scope check
3 lib files: `lib/dev/demo_vendor_integration_state_fixture.dart` (dev-only),
`lib/infrastructure/persistence/sqlite/sqlite_database.dart` (demo-seed resolver
only), `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` (demo
seed). 10 test files. No trackers, no auth/RLS/proxy/schema, no migrations, no
docs. In-scope.

## Pattern B — orchestrator independent audit

| Change | Worker self-audit | Orchestrator audit (file:line) |
|---|---|---|
| Fix A: `connectedCategoryCount`/`isNoneConnected` on the vendor fixture | generalized off fixture, not hardcoded Harbour | CONFIRMED `demo_vendor_integration_state_fixture.dart` +29: counts `status != disconnected` (so `error`/needs-reauth = a real connection). Harbour=0→none; Downtown=3; North Loop=1; Riverside=3. Correct. |
| Fix A: 5 `continue` guards in per-location seeders | operational/historical rows suppressed for none-connected; loc + demo_mode_state rows kept | CONFIRMED `sqlite_database_seed.dart` +170: guard after `restaurantId` read, before any write, in `_seedAdditionalLocationsFromReplay`, `_seedHistoricalOpenShiftSnapshotsFromReplay`, `_seedForwardReservationEnvelopeFromReplay`, `_seedHistoricalWeeklyPlanSnapshotsFromReplay`, `_seedDemoSampleNotifications`. `restaurant_locations` + vendor/demo_mode_state rows untouched → scope drawer + banners intact; surfaces honest-degrade via existing empty-state UI. No reader change. |
| Fix B: `seedTimeOpenPeriodResolution` wrapper | `resolveDemoOpenPeriod` byte-unchanged; deterministic fallback | CONFIRMED `resolveDemoOpenPeriod`'s file (`mock_integration_replay_seed.dart`) NOT in diff → byte-unchanged. Wrapper returns honest result when a period is live, else most-relevant period (deterministic, period-window-derived). |
| Fix B: 3 swaps in `_openPeriodResolutionForSeed` | demo-seed-only | CONFIRMED `sqlite_database.dart` only 3 hunks (1 import + the `_openPeriodResolutionForSeed` static). Callers: cold-boot demo seed + demo "Demo date" reseed — both operate on `DemoScope.restaurantId` + call `_seedDemoDataFromReplay`. Live vendor-connector path never calls this. Production data path byte-unchanged. |

## Hard constraints
- HP #2: no `demo_*` table; no new `kDemoMode` reader branch (writer/seed-side
  only). ✓
- HP #4: per-`restaurant_id`; no migrations; RLS-ready schema untouched. ✓
- Metric Honesty: Fix A makes none-connected honest-EMPTY by row absence (no
  phantom zeros) — the doctrine's goal. ✓
- No core-formula/recommendation/connector/proxy/auth/RLS change; production
  byte-unchanged. ✓
- Determinism: wrapper period-window-derived; two-reseed byte-identical tests
  pass. ✓ (CI dark — trusted disclosed local run; orchestrator did not
  re-run.)

## Tests (CI dark — disclosed local run)
`flutter analyze` clean on all 13 files. ~190 pass across 13 demo/replay/seed
suites incl. new Fix-A honest-empty + Fix-B Sat-16:00 between-services
regressions. 10 test files updated to expect connected-only operational data
(expectation-aligned). Pre-existing master failures snapshotted (NOT
regressions): `persistence_scope_alignment_test.dart` group L ×8 (`no such
table: target_cycle_dayparts`), `restaurant_scope_notifier_test.dart` boot-time
×2. A `replay_integrity_audit_test.dart` week_records assertion already failing
on master was repaired in-scope (scoped to Downtown), transparently disclosed.

## Device verification — 2026-05-16, clean rebuild of `b7d53df5`
- **Fix B:** Downtown Shift at 4:47 PM Saturday (the previously-blank
  between-services time) renders a full live whole-day card — ● Live, SALES
  $6,772, LABOR % 11.2%, COVERS 157, BLENDED WAGE $7.40, daypart selector,
  primary driver. Never blank.
- **Fix A:** Harbour Shift = "NO DATA — No live or historical data is available
  for this location"; Harbour Variance = "No closed shifts yet." No fabricated
  numbers (previously fake Covers 1166/999). Demo banners still render; Harbour
  still in the scope drawer.
- Hierarchy walk re-confirmed non-destructive (the #829 wipe fix holds).

## Decision
Clean against all hard constraints; operator-signed-off; merged squash to
`master` `b7d53df5`; both fixes device-verified on a clean rebuild. Closed.
