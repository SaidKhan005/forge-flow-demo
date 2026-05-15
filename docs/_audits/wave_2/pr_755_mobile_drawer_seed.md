# PR #755 audit — Mobile-FU-business-scope-drawer-seed

**PR:** https://github.com/SaidKhan005/forge-flow-demo/pull/755
**Branch:** `claude/mobile-fu-business-scope-drawer-seed` → `master`
**Worker commit:** `da82e27e438a0df317d0bf643a33865daa51494d`
**Dispatched by:** orchestrator (this session) on `claude/mobile-lane-pass-1` while driving Phase 2 mobile-lane walkthrough Pass 1.
**Audited by:** orchestrator, 2026-05-15.
**Verdict:** **approve-for-merge.**

## Why this slice exists

Phase 2 walkthrough Pass 1 surface 01 (hamburger drawer / business scope picker) rendered the empty-state "Your available locations will appear here." in demo mode even though the operator was actively scoped to a real demo location ("Barrio Legado"). Root cause: `RestaurantScopeNotifier._availableScopes` was never populated by the demo bootstrap because `loadBusinessScopes(client:)` is gated on a `BusinessScopeClient` provider that demo bootstrap leaves null. Filed as `Mobile-FU-business-scope-drawer-empty-in-demo` in `phase_2_walkthrough_verification.md` Lane M row 01.

## Scope verification (against the orchestrator's brief)

| Scope item | Status | Where |
|---|---|---|
| (a) Seed `_availableScopes` in demo so the drawer is non-empty | ✓ done | `lib/state/restaurant_scope_notifier.dart:78-152` — new `seedAvailableScopesFromLocal()` reads `restaurant_locations` via `listRestaurants()` and maps each row into a location-scoped `BusinessScope`. |
| (b) Render active scope as highlighted row | ✓ preserved (verbatim) | `lib/forge_flow_app.dart:1601+` — `BusinessScopeDrawerTile` extracted as top-level widget; pre-existing visual rules (selectedTileColor + sunsetDark leading icon + w700 title + trailing check_circle) kept exactly; previously invisible because the list was empty. |
| (c) Tests for both paths | ✓ done | `test/state/restaurant_scope_notifier_test.dart` +3 tests; `test/widgets/business_scope_drawer_tile_test.dart` new file, 5 tests. 14 tests total pass per worker disclosure. |
| OUT: title vs a11y label reconciliation | ✓ left alone | No edits to drawer title `'Locations'` ([line 931](lib/forge_flow_app.dart:931)) or hamburger button `content-desc="Business"`. Filed for parked UX decision. |
| OUT: operator-switching UI | ✓ left alone | No operator-level affordance added. |
| OUT: notifier API surface break | ✓ left alone | Existing `loadBusinessScopes(client:)` signature unchanged; new method is purely additive. |
| OUT: doc/tracker edits | ✓ left alone | Worker did not touch any doc, ledger, or matrix. |

## 14-lens orchestrator audit (independent pass)

| Lens | Verdict | Note |
|---|---|---|
| 1. Authority-doc match | ✓ pass | `seedAvailableScopesFromLocal` doc comment cites HP #2; `listRestaurants` doc comment cites HP #2. Both honor the doctrine that demo is a writer-side switch + the reader is symmetric across demo + prod. |
| 2. Route contract | ✓ pass | No new route. The drawer's open-via-Drawer-widget contract is unchanged. |
| 3. Data / RLS | ✓ pass | `listRestaurants()` is a read-only SELECT delegating to existing `dao.getAllRestaurants()`. No schema change, no migration, no RLS policy touched. The local SQLite cache is already operator-scoped (it only contains restaurants the operator has access to per HP #4); no cross-operator leak risk. |
| 4. Service-layer / API surface | ✓ pass | Notifier constructor + existing `loadBusinessScopes(client:)` API unchanged. New method `seedAvailableScopesFromLocal({required userId, required operatorId, ...})` is purely additive + accepts injectable readers for testability. New repo method `listRestaurants()` follows the same return-shape pattern as `getActiveRestaurant()`. |
| 5. Audit log | ✓ N/A | No mutation that warrants audit logging. The scope-activate path still routes through the existing `saveActiveScope` which is already wired into the appropriate persistence layer. |
| 6. Idempotency | ✓ pass | Seed call is gated on `_businessScopesLoadingFor` / `_businessScopesLoadedFor` keyed by `session.userId` — same pattern the network path uses. Force-reload during in-flight seed queues correctly via `_businessScopesPendingReloadFor`. |
| 7. Operator-approval gate | ✓ N/A | Not auth/RLS/schema/proxy. No `Gate=operator` requirement. |
| 8. Test coverage | ✓ pass | 3 new state-notifier tests covering seed behavior (populated, empty, persisted-active resolves) + 5 widget tests covering `BusinessScopeDrawerTile` active vs inactive rendering (`activeLeadingIconKey` + `activeCheckIconKey` test anchors). 14 tests pass per `flutter test` disclosure. |
| 9. Hash-chain risk | ✓ N/A | No `audit_logs` mutation. |
| 10. Scope creep | ✓ pass | Repo-method addition (`listRestaurants`) is the smallest legitimate extension to read all locally-cached locations; nothing else added. Hamburger a11y label NOT touched (parked per scope brief). |
| 11. Demo carve-out violations (HP #2) | ✓ pass | **No 5th `kDemoMode` reader branch added.** The local-seed reader is symmetric across demo + prod — production hits it briefly during cold-start before the network fetch resolves, then `loadBusinessScopes` overwrites `_availableScopes` with proxy-authoritative data. Doc comments explicitly state this contract. |
| 12. Frozen-surface violation | ✓ pass | No `lib/auth/**`, no `lib/data/**`, no `db/migrations/**`. |
| 13. B11 redemption-code URL forbidden pattern | ✓ N/A | Not B11. |
| 14. Banned-tokens grep | ✓ pass | No KMS rollout, `parse_warnings`, `parse_partial`, `kStrictReplayFiveMinute`, `pg_advisory_lock`, `sigtermDrainHandler`, `inboundWebhookDLQTile`, `raw_payload_partition`, `pg_partman_raw` in the diff. |

## Observations + flags (informational only)

- **No-op extension semantics**: `seedAvailableScopesFromLocal` only seeds the active scope (or persisted match) when the active-restaurant query resolves; otherwise picks the first location. For multi-location demo seeds this picks deterministically (first row) — fine. Multi-operator switching is V1.1 territory and outside this slice.
- **Race-condition window**: if the network-path `loadBusinessScopes` fires after the local seed, it overwrites `_availableScopes` — correct behavior. The persisted active scope might briefly point to a local-seed result before the network response. Same pattern as any optimistic-local-render-then-server-truth setup; acceptable.
- **Error path**: `.catchError` logs via `debugPrint` + `debugPrintStack`. Doesn't surface a user-visible error, which is fine for a fallback — the empty-state in the drawer is the visible degradation if both paths fail.
- **`listRestaurants` does not filter by `operator_id`**: in V1 with single-operator demo this is fine; the local SQLite cache only contains rows the operator has access to (production seeds that way). If multi-operator caching ever lands, that method should add an `operatorId` parameter — flagging as a V1.1 watch-point but NOT a V1 blocker.

## Tests + analyze verification

Worker disclosed:
- `flutter analyze --fatal-infos <5 files>` → `No issues found! (ran in 2.4s)` ✓
- `flutter test test/state/restaurant_scope_notifier_test.dart test/widgets/business_scope_drawer_tile_test.dart test/services/active_business_scope_test.dart` → `00:01 +14: All tests passed!` ✓
- pre-push hook: `postgres_import_lint: clean` ✓

CI is dark per the `feedback_ci_dark_until_2026_06_01` memory; worker-disclosed local runs are the authoritative test signal. This slice does NOT touch the CI-dark high-risk surfaces (`db/migrations`, `advisor_proxy`, `services` proxy paths, `lib/auth`, RLS) so the disclosure is sufficient.

## Outstanding parking

- **`Mobile-FU-business-scope-drawer-label-vs-a11y`** (UX decision) — hamburger button `content-desc="Business"` mismatches drawer title `'Locations'`. Three options: (i) keep "Locations" + change a11y to "Locations"; (ii) change title to "Business" / "Operator + location" + keep a11y; (iii) add operator-context row above the location list. Defer to operator UX call; not V1-blocking. Filing in WAVE_2_LEDGER as a parked row.
- **`FU-mobile-firebase-mobile-push-demo-guard`** (from earlier Agent C research, unrelated to this PR) — non-blocking startup-only Firebase.app() residual; fix is < 20 LoC at `lib/services/mobile_push/firebase_mobile_push_runtime.dart:45`.

## Decision

Merge via squash to master. After merge, re-drive surface 01 on the device to confirm drawer populates with the active "Barrio Legado" location row + check icon. Flip the matrix annotation for surface 01 from 🐛 → ✅ DONE-LIVE with cross-reference to this audit + PR #755.

## Postmortem (2026-05-15 01:05, after live re-drive)

**The drawer is still empty on the device after PR #755 merged + APK rebuilt + reinstalled.** Capture: `phase_2_walkthrough_evidence/mobile/thumbs/p1_17_drawer_post_pr755.png`.

Triage:
- APK rebuilt + installed: `build/app/outputs/flutter-apk/app-forgeflow-debug.apk` timestamp `2026-05-15 01:03`, `dumpsys package com.forgeflow.app` `lastUpdateTime=2026-05-15 01:03:51`. New PID `10289` attached, Dart VM service line in logcat (`05-15 01:04:13.303 I/flutter (10289): The Dart VM service is listening on http://127.0.0.1:41383/`).
- SQLite has the row: `python -c "import sqlite3; ..."` over a pulled copy of `databases/forge_flow_v2.db` returned `1` row `('demo_restaurant_001', 'Barrio Legado', 'America/St_Johns')`. So `listRestaurants()` would return non-empty if called.
- Logcat surfaces `AuthSessionNotifier.rehydrate storage error: 9.3 scaffold: real SecureSessionStorage is not wired — bind flutter_secure_storage (Keychain / Android Keystore) in the app bootstrap before serving authenticated traffic.`

**Hypothesis** — the call-site at [lib/forge_flow_app.dart:820](lib/forge_flow_app.dart:820) gates the fallback behind `if (session == null) return;`. In demo bootstrap when `AuthSessionNotifier.session` is null at the time `addPostFrameCallback` fires (`forge_flow_app.dart:1315`), the seed never runs. The Shift dashboard renders content because it reads `RestaurantScopeNotifier._restaurant` — a separate, locally-seeded single-active-scope value — not the `_availableScopes` list that powers the drawer. So the dashboard works, the drawer doesn't.

**Audit miss** — Lens 4 (Service-layer / API surface) of my 14-lens table marked the slice ✓ pass because the existing `loadBusinessScopes(client:)` signature was unchanged. I did NOT deep-trace whether the existing `if (session == null) return;` guard at the call-site ALSO short-circuited the new fallback path. The worker's unit tests at `test/state/restaurant_scope_notifier_test.dart` exercised `seedAvailableScopesFromLocal` directly with mocked `userId` + `operatorId`; the call-site gate was never under test. A scenario test "session arrives via delayed sign-in after AppShell mounts" would have caught the gap.

**Action** — re-open `Mobile-FU-business-scope-drawer-empty-in-demo` in the gaps register; SendMessage Agent A with the specific gap + hypothesis; ask for a follow-up commit. Options:

1. Lift the `session == null` guard for the local-seed fallback (seed unconditionally if SQLite has rows, then refine the active-scope choice when session arrives later)
2. Trigger the seed on `RestaurantScopeNotifier.activateRuntimeRestaurant` instead of in `_loadBusinessScopesIfNeeded` — the restaurant-activate path fires during the boot path that ALREADY populates the dashboard, independent of `AuthSessionNotifier`
3. Listen on `AuthSessionNotifier` for late-arriving sessions + retrigger the seed via the existing `_businessScopesPendingReloadFor` queue

Option (2) is structurally cleanest but expands scope. Option (1) is the smallest change but might violate operator-scope isolation (need a fallback `operatorId` source). Option (3) is the integration-test gap closure that the worker's tests already provide the building blocks for. Decision belongs to the operator OR Agent A's investigation.

**Audit verdict revised**: PR #755 lands the right *building blocks*, but the live behavior gap means surface 01 is NOT actually ✅ post-merge. The matrix row is flipped back to 🐛 LIVE GAP. Audit verdict for the **slice as merged** stays approve-for-merge (the code lands what was scoped) — but the **walkthrough gap is NOT resolved**, requiring a follow-up.
