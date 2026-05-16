# Audit — Demo data Slice E (pt1): vendor integration demo state — operator-web + DemoModeStateGateway fixture

**Branch:** `claude/demo-slice-e-vendor-state-fixture`
**Base:** `master` @ `e5fe02de` (includes Slice A merge #788/#790 — 4-location hierarchy live)
**Scope:** Slice E **part 1 only** (non-seed half). Part 2 (the
`sqlite_database_seed.dart` mobile-fold seed hook) is **deferred** —
that file is owned by the in-flight Slice B worker; see §"Deferred".
**Authority:** prompt → `docs/_audits/per_daypart_v1/full_demo_data_spec.md`
§1.5 (line 70), §2f/§2g (lines 167-175), Slice E (lines 238-239),
Gap G6 (line 188) → `CLAUDE.md` HP #2 + `docs/contracts/demo_mode_contract.md`.

## What changed

| File | Change |
|---|---|
| `lib/dev/demo_vendor_integration_state_fixture.dart` | **NEW.** Canonical deterministic per-(location, category) demo state; `DemoModeRecord` builder; `VendorConnectionsBundle` builder; `DemoVendorIntegrationDemoModeStateGateway implements DemoModeStateGateway` (the HP #2 writer swap). |
| `lib/operator_web/services/demo_vendor_connections_fixtures.dart` | **NEW.** Builds the seeded `InMemoryVendorConnectionsGateway` seed map for the 4 operator-web demo locations, sourced from the same canonical fixture. |
| `lib/operator_web/services/operator_web_vendor_connections_resolver.dart` | `demoFallback()` now returns the **seeded** gateway instead of an empty one (+1 import). |
| `lib/operator_web/router/operator_web_router.dart` | `_vendorConnectionsGateway` getter now falls back to `demoFallback()` when `resolve()` is null (demo-only arm; +doc). |
| `test/dev/demo_vendor_integration_state_fixture_test.dart` | **NEW.** 12 tests — fixture states, determinism, drift guards, `DemoModeStateNotifier` Test 1, gateway flip semantics, production-path-unchanged. |
| `test/operator_web/services/operator_web_vendor_connections_demo_fixture_test.dart` | **NEW.** 3 tests — Test 2 (operator-web ↔ fixture consistency), mixed-state coverage. |

## Acceptance proof

- **(a) mixed per-(O,L,category) states render** — `demo_vendor_integration_state_fixture.dart:130-243` (state table): Downtown POS/Labor `connected`+`is_demo=true`, Reservation `error`+`is_demo=true` (§1.5 L70, §2f); North Loop POS connected/Labor+Res disconnected; Riverside all `connected`+`is_demo=false` (already flipped, §2f); Harbour all disconnected (clean demo, §2f). Pinned: `test/dev/...:28-76` + `DemoModeStateNotifier` snapshot `:118-151`.
- **(b) hasDemoCategories mixed across locations** — Downtown/NorthLoop/Harbour TRUE, Riverside FALSE. Pinned `test/dev/...:142-149` (§2g requires ≥1 of each).
- **(c) HP #2 writer-side-only** — no `kDemoMode` reader branch (`grep kDemoMode` on the 4 lib files = 0 hits); no `demo_*` table (fixture is in-memory data into the **existing** `DemoModeStateGateway` abstract surface, `demo_mode_state.dart:40-59`); readers (`DemoModeStateNotifier`, banner, Demo→Live switch) untouched. The demo build is a writer swap: `DemoVendorIntegrationDemoModeStateGateway` (`...fixture.dart:436-499`) implements the production abstract gateway. Production-path-unchanged test: `test/dev/...:160-186` proves the notifier surfaces exactly what the proxy returns with no demo branch.
- **(d) production unchanged** — live operator-web sources mix in `OperatorWebVendorConnectionsGatewayProvider` so `resolve()` is non-null and the `?? demoFallback()` arm never executes (router doc-comment + `vendor_connections_screen_mount_test.dart` live-source test still green). Mobile production wires the real `HttpSyncProxyClient`; the demo gateway is only reachable via the deferred part-2 seed hook. `flutter test` of 5 pre-existing related suites = **27/27 green** (no regression).
- **(e) deferred part 2** — `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` (mobile-fold seed hook) intentionally NOT touched; owned by in-flight Slice B (driver variance). Until part 2 wires the demo build to resolve `DemoVendorIntegrationDemoModeStateGateway` / a demo proxy, the fixture is proven by the acceptance tests, not yet live in the running mobile demo build.

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Slice intent met | PASS | Fixture renders mixed per-(O,L,C) state on both surfaces; Gap G6 closed for the non-seed half. `...fixture.dart`, both test files green. |
| 2 | Authority order respected | PASS | Spec §2f/§2g states implemented verbatim; HP #2 writer-side honored; backward-compat `DemoScope.restaurantId` ids referenced not changed. |
| 3 | No scope creep | PASS | Only the 2 new fixtures + resolver 1-line + router 1-getter. No shift/benchmark/seed/auth files. Banned-file list (concurrency) untouched — verified `git diff --stat`. |
| 4 | HP #2 demo contract | PASS | No `demo_*` table; no `kDemoMode` reader branch; fixture data into existing `DemoModeStateGateway`; matches contract "Acceptable patterns" (`lib/dev/` demo writer + `lib/operator_web/services/demo_*` gateway fixture). |
| 5 | HP #4 per-operator isolation | PASS | Records key on logical location; `operatorId` threaded onto every `DemoModeRecord` (`...fixture.dart:289-305`); `vendorConnectionsSeed` keys `operatorId/locationId`. Test `:42` asserts operatorId carried. |
| 6 | Determinism / no RNG | PASS | Static `const` state table; flip timestamps from fixed `_flipEpoch` (`...fixture.dart:246`); zero `DateTime.now()`/`Random`. Test `:78-92` + `:153-159` assert byte-identical reads. |
| 7 | Production behavior unchanged | PASS | `?? demoFallback()` arm demo-only (live `resolve()` non-null); notifier no-branch test `:160-186`; 27/27 pre-existing tests green. |
| 8 | Tests prove the seam | PASS | 15 new tests: notifier snapshot (Test 1), operator-web consistency (Test 2), prod-path (Test 3), determinism, drift guards, flip one-way/idempotence. |
| 9 | dart analyze clean | PASS | `dart analyze` on all 4 lib + 2 test files → "No issues found!". |
| 10 | No banned bypass | PASS | No `--no-verify`; canonical hooks installed (step 0); no tracker edits. |
| 11 | Layering | PASS-with-note | `operator_web/services/demo_*` imports `lib/dev/` canonical fixture. This is the blessed demo-fallback path (contract "Acceptable patterns"), not a canonical Layer-3 service; single-source-of-truth chosen over a duplicated 4×3 table (drift hazard). No CI lint forbids it (checked `tool/*.dart`). Documented in both file headers. |
| 12 | UX writing standard | PASS | Reservation error copy is plain-English remediation ("Reauthorize OpenTable — the saved access token expired. Reconnect from this card…"), no jargon. |
| 13 | Backward compat | PASS | `DemoScope` ids + `kDemoTeamLocationsFixture` ids referenced via literals + drift-guard tests (`:94-111`); no id renames; existing `demoFallback` test (`isA<InMemoryVendorConnectionsGateway>`) still passes. |
| 14 | Concurrency safety | PASS | `sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`, shift/benchmark/auth/settings files NOT touched. Only new files + resolver/router (not in any in-flight worker's scope). |

**Considered tradeoff (lens 7/11):** the router `?? demoFallback()` makes
`widget.gateway` non-null in demo, so `VendorConnectionsScreen` wires
`onConnectFlowStarted` (previously null in demo). This only fires on an
explicit operator "Connect" click in the demo build and is demo-only;
it does not affect rendering or production. Accepted as the minimal
on-contract wiring (matches the resolver's own documented "host shell
maps null to demo mode" intent).

## Local verification (CI dark — disclosed)

- `flutter pub get` → Got dependencies.
- `dart analyze lib/dev/demo_vendor_integration_state_fixture.dart lib/operator_web/services/demo_vendor_connections_fixtures.dart lib/operator_web/services/operator_web_vendor_connections_resolver.dart lib/operator_web/router/operator_web_router.dart` → **No issues found!**
- `dart analyze` (2 new test files) → **No issues found!**
- `flutter test test/dev/demo_vendor_integration_state_fixture_test.dart test/operator_web/services/operator_web_vendor_connections_demo_fixture_test.dart` → **15/15 passed.**
- `flutter test test/widgets/demo_mode_banner_test.dart test/operator_web/screens/vendor_connections_screen_mount_test.dart test/widgets/settings_demo_live_switch_test.dart test/widgets/settings_integrations_section_test.dart test/integration/demo_mode_state_test.dart` → **27/27 passed** (no regression; baseline pre-PR: these suites green on `e5fe02de`).

## Deferred (part 2)

`sqlite_database_seed.dart` mobile-fold seed hook — wires the running
mobile demo build to resolve `DemoVendorIntegrationDemoModeStateGateway`
(or a demo `SyncProxyClient.fetchDemoModeStates` shim) so
`DemoModeStateNotifier`/`DemoModeBanner` render this fixture live.
Owned by in-flight Slice B; dispatch part 2 after Slice B merges.
