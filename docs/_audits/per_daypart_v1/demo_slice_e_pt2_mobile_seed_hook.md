# Audit — Demo data Slice E pt2: mobile-fold demo_mode_state seed hook (consistent with pt1)

**Branch:** `claude/demo-slice-e-pt2-mobile-seed-hook`
**Base:** `master` @ `ff37202b` (#807 + #803 + pt1 #800 all merged)
**Scope:** Slice E **part 2 only** — the mobile-fold `demo_mode_state`
seed hook deferred by pt1 (#800). pt1 built the canonical fixture +
operator-web wiring; pt2 wires the **mobile** notifier's demo source so
Settings → Integrations + `DemoModeBanner` render the same per-(operator,
location, category) state, consistent with pt1.
**Authority:** prompt → `docs/_audits/per_daypart_v1/full_demo_data_spec.md`
§1.5 (line 70), §2f/§2g (lines 167-175), Slice E (lines 238-239), Gap
G6 (line 188) → `CLAUDE.md` HP #2 (writer-side; no `demo_*` table; no
`kDemoMode` reader branch), HP #4 isolation → `docs/contracts/demo_mode_contract.md`.

## Architecture finding (why the hook is a source-swap, not a table write)

The mobile fold (`SettingsIntegrationsSection`) and `DemoModeBanner`
read **only** `DemoModeStateNotifier.snapshot`
(`lib/screens/settings/settings_integrations_section.dart:134`,
`lib/widgets/demo_mode_banner.dart:37`). The notifier is fed
**exclusively** by an injected `SyncProxyClient.fetchDemoModeStates`
(`lib/state/demo_mode_state_notifier.dart:215`). There is **no SQLite
`demo_mode_state` table** (`demo_mode_state` is Postgres-only, migration
`202605040000`) and **no demo/local `SyncProxyClient`**. The demo
flavor (`main_forgeflow.dart:134`) bootstraps with **no
`syncProxyClient`**, so `notifier.bindClient(null)`
(`forge_flow_app.dart:641`) → notifier never refreshes → the fold +
banner rendered nothing.

Per the prompt's **Required #3** ("if the mobile fold reads an in-memory
gateway rather than a SQLite table in the demo build, then the 'hook' is
wiring the same pt1 fixture into the mobile notifier's demo source — do
that instead of inventing a table") and pt1's own header
(`lib/dev/demo_vendor_integration_state_fixture.dart:16-20,34-41` — "the
demo build is a WRITER swap … the demo build resolves
[DemoVendorIntegrationDemoModeStateGateway]"; "the mobile-fold seed hook
… is part 2, deferred"), pt2 implements the hook as a **writer-side
source swap** — the `DemoModeStateNotifier` analogue of
`MockReplayDataSourceProvider` / the contract-endorsed
`DemoAuthLoginService` bootstrap source-swap (CLAUDE.md → Demo Mode).

**Deliberate footprint note (disclosed for orchestrator audit):** the
prompt's Files section named only `sqlite_database_seed.dart` + tests,
but a SQLite-part-of seed function has no seam to reach the notifier
without (a) the demo source class and (b) the one-line notifier-bind
fallback. The extra touches are minimal, conflict-free vs the parallel
Slice F (which edits *different new functions* of
`sqlite_database_seed.dart` — override/notification rows; this hunk is
localized to the end of `_seedDemoDataFromReplay` + a new self-contained
function region) and explicitly authorized by Required #3 + pt1's
design. `_seedWeeklyPlanSnapshotFromReplay` (#803), the per-location
loop (#807), and `_buildDemoSeedCycle` are **untouched**.

## What changed

| File | Change |
|---|---|
| `lib/dev/demo_vendor_integration_sync_proxy_client.dart` | **NEW.** `DemoVendorIntegrationModeStateSyncProxyClient implements SyncProxyClient` — `fetchDemoModeStates` delegates to pt1's `DemoVendorIntegrationStateFixture`; all other proxy methods `noSuchMethod`→`UnsupportedError` (mirrors pt1's test `_FixtureSyncProxyClient`). `DemoVendorIntegrationDemoModeSource` — process-global demo-only holder (`armForDemoSeed`/`maybeClient`/`materializeAndValidate`/`resetForTest`). No `sqlite_database.dart` import (location ids passed in) → no library cycle. |
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | **+1 new self-contained private fn** `_seedDemoVendorIntegrationModeStateSource()` + **single call site** appended at the end of `_seedDemoDataFromReplay` (the existing both-paths seam, mirroring `_seedAdditionalLocationsFromReplay`) + `_kDemoModeWriterSwitch` const (same env pair as `_demoAuthEnabled`). |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | **+1 import** of the new dev file (parts can't import; consistent with the existing `../../../dev/...` imports). |
| `lib/forge_flow_app.dart` | `_resolveSyncProxyClient()` → `Provider.of<SyncProxyClient?> ?? DemoVendorIntegrationDemoModeSource.maybeClient()` (+1 import, +doc). Only consumer is the demo notifier bind (`:641`). |
| `test/dev/demo_slice_e_pt2_mobile_seed_hook_test.dart` | **NEW.** 8 tests — production-path-unchanged (unarmed→null→silent), 4×3 render, byte-consistency with pt1, determinism across two reseeds, HP #4 isolation, operational-sync-leakage fails loudly. |

## Pattern B — 14-lens self-audit (worker)

| # | Lens | Verdict | Evidence (file:line) |
|---|---|---|---|
| 1 | Slice intent met | PASS | Mobile fold + banner now have a source: `demo_slice_e_pt2..._test.dart` "4 locations × 3 categories … hasDemoCategories true for ≥1, false for ≥1" green; `forge_flow_app.dart:680-700` binds it to `DemoModeStateNotifier`. |
| 2 | Authority order honored | PASS | Required #3 + pt1 header design implemented as the writer-swap; `full_demo_data_spec.md` §2f/§2g mix preserved verbatim via pt1 fixture delegation (`demo_vendor_integration_sync_proxy_client.dart:78-83`). |
| 3 | HP #2 — writer-side, no `demo_*` table, no `kDemoMode` reader branch | PASS | No SQLite table created (none exists; none added). The only flag use is the **writer-side** `_kDemoModeWriterSwitch` *inside the seeder* (`sqlite_database_seed.dart` `_seedDemoVendorIntegrationModeStateSource`), HP #2-endorsed. `forge_flow_app.dart:697-700` is an **unconditional `??`**, not a `kDemoMode` branch; readers (`DemoModeStateNotifier`, banner, fold) unchanged. |
| 4 | HP #4 — per-(operator,location) isolation | PASS | `materializeAndValidate` asserts every row `locationId==location && operatorId==kDemoOperatorOperatorId`; test "HP #4 — no cross-location / cross-operator leakage" green; pt1 fixture keys on location only + threads operator. |
| 5 | Consistent with pt1 (#800) | PASS | `fetchDemoModeStates` delegates to `DemoVendorIntegrationStateFixture.demoModeRecords` (the SAME source operator-web uses); test "byte-consistent with pt1" asserts category/isDemo/flippedToLiveAt/flippedByConnectionId equality for all 4 locations. |
| 6 | Determinism (no RNG / no `DateTime.now()`) | PASS | Pure delegation to the static pt1 fixture (fixed `_flipEpoch`); test "deterministic across two reseeds (no RNG)" green; `armForDemoSeed` is idempotent. |
| 7 | Production path unchanged | PASS | Seed hook returns early when `_kDemoModeWriterSwitch` false (prod) → source never armed → `maybeClient()` null → `??` short-circuits on the real `HttpSyncProxyClient`. Test "source not armed → maybeClient() is null" + "unarmed → silent" green. |
| 8 | #803/#807/`_buildDemoSeedCycle` untouched | PASS | `git diff` shows only an appended call after `_seedAdditionalLocationsFromReplay(...)` + a new fn/const region before `_deterministicHash`; no edits inside `_seedWeeklyPlanSnapshotFromReplay`, the per-location loop, or `_buildDemoSeedCycle`. |
| 9 | Concurrency-safe vs Slice F | PASS | Slice F edits *different new functions* of the same file (override/notification rows). This hunk is localized; orchestrator rebases at merge per prompt. No shared function edited. |
| 10 | No operational-sync leakage | PASS | Demo client implements only `fetchDemoModeStates`; everything else throws `UnsupportedError`. `MobileOperationalSyncHost` still gets the raw bootstrap client (`forge_flow_bootstrap.dart:123` unchanged). Test "operational sync leakage fails loudly" green. |
| 11 | Layering (Service-Layer Split) | PASS | Demo source lives in `lib/dev/` (= "demo and dev-only"); no `package:postgres`; no reader-repository fork. |
| 12 | Tests prove the seam | PASS | New suite 8/8; pt1 suite 12/12; `settings_integrations_section`/`demo_mode_banner`/`settings_demo_live_switch` widget tests green; `per_daypart_v1_demo_seed_per_period_cycle_test` 3/3 (no seed regression). |
| 13 | `dart analyze` clean | PASS | `dart analyze` on all 5 touched files → "No issues found!". |
| 14 | Docs/hygiene | PASS | This audit doc; no tracker edits (per contract); `Links updated: no`. |

## Verification (CI dark — exact local commands + results)

```
flutter pub get                                  → Got dependencies!
dart analyze <5 touched files>                   → No issues found!
flutter test test/dev/demo_slice_e_pt2_mobile_seed_hook_test.dart \
             test/dev/demo_vendor_integration_state_fixture_test.dart \
             test/widgets/settings_integrations_section_test.dart \
             test/widgets/demo_mode_banner_test.dart \
             test/widgets/settings_demo_live_switch_test.dart
                                                 → All tests passed! (+31)
flutter test test/per_daypart_v1_demo_seed_per_period_cycle_test.dart
                                                 → All tests passed! (3/3, no seed regression)
```

## Deferred / out of scope

- The master Demo→Live switch (`SettingsDemoLiveSwitch`) reads
  `context.read<SyncProxyClient?>()` (the *Provider* value, not
  `_resolveSyncProxyClient`), so it stays disabled in demo exactly as
  before — pt2 deliberately does not enable it (out of scope; the demo
  client implements no `DemoModeMasterSwitchClient`). `settings_demo_live_switch_test`
  remains green.
