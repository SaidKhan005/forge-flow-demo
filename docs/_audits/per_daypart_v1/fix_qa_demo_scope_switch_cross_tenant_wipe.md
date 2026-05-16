# Audit — Fix: demo location switch no longer cross-tenant-wipes the operator's other 3 demo locations (HISTORICAL ONLY)

- **Branch:** `claude/fix-qa-demo-scope-switch-cross-tenant-wipe`
- **Base:** `origin/master` @ `5c3fc74c` (includes #827 per-loc cold-boot open shift + #828 scope-refresh wiring)
- **Slice class:** P0 QA — service-seam-adjacent (demo bootstrap source-swap). Orchestrator review before merge.
- **Change shape:** purely additive — 19 files, **+336 / -0**. No migrations.

## The exact wipe chain (verified on master before the fix)

1. Demo location switch → `RestaurantScopeNotifier.activateBusinessScope` publishes to `ActiveBusinessScopeChangeBus.instance.changes` (`lib/state/restaurant_scope_notifier.dart:177`).
2. `_MobileOperationalSyncHostState` subscribes to that bus (`mobile_operational_sync_runtime.dart:310-311`).
3. `_handleBusinessScopeChanged` (`:434`) → session non-null in proper demo build → `_wipeOtherTenantsThenSync` (`:422`).
4. `_wipeOtherTenantsThenSync` → `widget.crossTenantWipe(session.locationId)` (`:425`).
5. `crossTenantWipe` defaulted to `defaultCrossTenantWipe` (`:190-215`) → 8 repos' `wipeForOtherScopes(keep)` → e.g. `OpenShiftSnapshotDao.deleteForOtherRestaurants` = `DELETE … WHERE restaurant_id != keep`.
6. In demo there is NO operational proxy sync to re-materialize the wiped tenant (the demo `SyncProxyClient` only serves `demo_mode_state`), AND the 4 `DemoScope.locations` are ONE demo operator's tenancy → the 3 non-active demo locations are permanently destroyed.

## Pre/post evidence

| | `open_shift_snapshots` |
|---|---|
| Clean cold boot (device, all 4 demo locations) | **684** rows (operator-reproduced) |
| Switch Downtown→Riverside, NO pull-refresh, **pre-fix** | **171** rows — only `demo_restaurant_riverside` survives; `_001` / `_north_loop` / `_harbour` wiped (513 deleted) → Shift renders `HISTORICAL ONLY` |
| Switch Downtown→Riverside, **post-fix** (this PR) | all 4 demo locations retain their rows; a genuinely-foreign `restaurant_id` is still purged |

Test `test/mobile_operational_sync_demo_scope_preserving_wipe_test.dart` reproduces & guards this: cold boot seeds all 4 demo locations (asserts `open_shift_snapshots` ⊇ all 4 demo ids — the 684 surface); after `demoScopePreservingCrossTenantWipe('demo_restaurant_riverside')` all 4 survive across all 9 affected tables and the foreign row is gone; then `defaultCrossTenantWipe('demo_restaurant_riverside')` (unchanged) on the preserved data still nukes the 3 non-keep demo scopes (only Riverside remains) — proving production behavior is byte-unchanged and the difference is purely the injected strategy.

## Local commands (CI dark — disclosed honestly)

- `flutter pub get` → `Got dependencies!`
- `dart analyze` on all 19 touched lib files + the new test → **`No issues found!`** (two batched runs)
- `flutter test test/mobile_operational_sync_demo_scope_preserving_wipe_test.dart` → **`All tests passed!`** (+1)
- `flutter test test/services/sync/mobile_operational_sync_runtime_test.dart test/per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart` → **`All tests passed!`** (+11) — no regression on the existing wipe-wiring test or the #827 per-loc seed regression
- No `db/migrations/*.sql` touched → migration drift/cutoff lints N/A.

## Production-untouched grep evidence

`demoScopePreservingCrossTenantWipe` is passed to `bootstrapAndRunApp` at exactly ONE call site: `lib/main_forgeflow.dart:151`, inside the `_demoAuthEnabled` demo branch (the same block that swaps `DemoAuthLoginService` / `InMemorySecureSessionStorage`). Every other `bootstrapAndRunApp(` call site — `lib/main.dart:32,53`, `lib/main_barrio.dart:31,45`, `lib/main_forgeflow.dart:96` (Firebase prod branch), `lib/main_forgeflow.dart:155` (prod fallthrough) — passes NO `crossTenantWipe`, so `bootstrap`'s `crossTenantWipe ?? defaultCrossTenantWipe` resolves to `defaultCrossTenantWipe`, **byte-unchanged**. `git diff` confirms 0 deletions: `defaultCrossTenantWipe`, the `MobileOperationalSyncHost` scope-change trigger, `_wipeOtherTenantsThenSync`, `_handleBusinessScopeChanged`, the runner, and every single-keep `wipeForOtherScopes` / `deleteForOtherRestaurants` body are untouched. `restaurant_scope_notifier.dart` and seed/#827/#828 code untouched.

## Pattern B — 14-lens self-audit

| # | Lens | Worker (file:line, finding) | Orchestrator |
|---|------|------------------------------|--------------|
| 1 | Scope discipline | Only owned files touched: `forge_flow_bootstrap.dart` (param thread `:48`,`:134`), `main_forgeflow.dart` (demo-branch arg `:151`, import `:19`), `mobile_operational_sync_runtime.dart` (sibling `:217-275` only), 8 DAOs + 8 repos (new siblings only), new test. No seed / `restaurant_scope_notifier` / #827/#828 edits. `git diff --stat`: +336/-0. | |
| 2 | Production wipe byte-unchanged | `defaultCrossTenantWipe` (`mobile_operational_sync_runtime.dart:190-215`) and all single-keep `deleteForOtherRestaurants`/`wipeForOtherScopes` DAO/repo bodies unchanged (0 deletions in diff; new methods are pure additions below the originals). | |
| 3 | Host trigger untouched | `_handleBusinessScopeChanged:434-449`, `_wipeOtherTenantsThenSync:422-432`, runner unchanged — verified diff has no hunks in `:190-449`. | |
| 4 | HP #2 (no `kDemoMode` reader fork / no `demo_*` table) | Fix is a bootstrap-injected strategy object (`CrossTenantWipe` typedef, `:38`) passed only at `main_forgeflow.dart:151`. No reader/DAO branches on `kDemoMode`; no new tables. Mirrors endorsed `DemoAuthLoginService` source-swap. | |
| 5 | HP #4 per-(operator,location) isolation | Foreign (non-DemoScope) `restaurant_id` still purged: `deleteForRestaurantsNotIn` keeps only `{keep} ∪ DemoScope.locations`; test asserts `foreignId` deleted by BOTH wipes. Demo locations are one operator's own tenancy, so preserving them is not a cross-tenant leak. | |
| 6 | Correctness of keep-set SQL | `deleteForRestaurantsNotIn` builds `restaurant_id NOT IN (?,?,…)` with `whereArgs: keep.toList()`; empty-set guard returns 0 (avoids invalid `NOT IN ()` that would delete all). Verified per DAO (e.g. `open_shift_snapshot_dao.dart:121-131`). | |
| 7 | target_profile two-table parity | `target_profile_dao.deleteForRestaurantsNotIn` (`:64-79`) deletes `active_target_profiles` + `target_profile_versions` (sum returned), mirroring its single-keep `wipeForOtherScopes`. | |
| 8 | Composition parity with default | `demoScopePreservingCrossTenantWipe` (`:251-275`) calls the SAME 8 repos as `defaultCrossTenantWipe`, in the same order, via `wipeForScopesNotIn`. No repo dropped/added. | |
| 9 | Bootstrap default preservation | `forge_flow_bootstrap.dart:134` passes `crossTenantWipe ?? defaultCrossTenantWipe` → unset (all prod paths) is exactly the prior constructor default. Constructor still `this.crossTenantWipe = defaultCrossTenantWipe` (`:269`, unchanged). | |
| 10 | Demo-branch-only wiring | `main_forgeflow.dart:151` arg sits inside `_demoAuthEnabled` block (`:118-153`); Firebase branch (`:95-116`) and fallthrough (`:155`) pass nothing. Grep evidence above. | |
| 11 | Analyzer cleanliness | `dart analyze` on all 19 lib files + test: `No issues found!`. Doc-comment `[DemoScope.locations]`/`[defaultCrossTenantWipe]` in scope; out-of-scope symbol downgraded to backticks (`:227`). | |
| 12 | Test fidelity to defect | Single cold boot (real demo seed, 4 locations) → asserts the 684 surface (`open_shift_snapshots` ⊇ 4 demo ids) → demo wipe keeps all 4 + purges foreign across 9 tables → default wipe on preserved data still leaves only Riverside. Sequential single-DB design avoids the known cross-cold-boot repo-DAO-cache artifact. | |
| 13 | Regression safety | Existing `mobile_operational_sync_runtime_test.dart` (wipe-wiring stub) + `per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart` (#827) pass unchanged (+11). | |
| 14 | Contract/authority alignment | CLAUDE.md Demo Mode "bootstrap source-swap" doctrine + HP #2/#4; prompt guardrail "MUST NOT change production wipe / host trigger" honored (0 deletions). No core formula / integration / proxy / auth / RLS change. | |

## STOP

PR opened. No merge, no tracker edits, no `--no-verify`. Orchestrator audits before merge (service-seam-adjacent).
