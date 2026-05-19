# Audit — Demo Forge&Flow: render Account tab + demo operator = F&F admin

Branch: `claude/fix-demo-account-ff-admin` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line).

## Root cause (diagnosed, not guessed)

The operator finding presumed a signed-in demo session existed. It did
not. Every Forge & Flow entrypoint (`lib/main_forgeflow.dart:115`,
`lib/main.dart:53`) falls through to
`bootstrapAndRunApp(const ForgeFlowApp())` when
`FORGE_FLOW_USE_FIREBASE_AUTH` is unset. `ForgeFlowApp.requireAuth`
defaults `false` (`lib/forge_flow_app.dart:67`) → no `AuthGate`
mounted, and `bootstrapAndRunApp` binds
`ScaffoldFailingAuthLoginService` (`lib/forge_flow_bootstrap.dart:59`).
So in the standalone demo flavor `AuthSessionNotifier.session` is
**null forever** (confirmed by the existing note at
`lib/state/restaurant_scope_notifier.dart:185-204`). Consequences in
`lib/screens/settings_screen.dart`:

- `:174` `showAccount = session != null` → **false** → `:245` the
  Account tab is dropped (**Finding 1**).
- `_teamActorForSettings` returns null when `session == null`
  (`lib/forge_flow_app.dart:1229`) → `showFFSupport`
  (`settings_screen.dart:201`) and the `_isFFAccount`-gated
  Data-alignment panel (`:440-444`) stay **hidden** (**Finding 2**).

So it was **session-null**, not a `SettingsAccountSection` throw. There
is no pre-existing mobile demo Firebase/credential fixture (exhaustive
search: only `operator_web` / `admin` have demo auth sources). The fix
introduces one, writer-side.

## What changed

| File | Change |
|---|---|
| `lib/services/auth/demo_auth_login_service.dart` (new) | `DemoAuthLoginService implements AuthLoginService`. `demo.operator@forgeflow.test` / `forge-flow-demo` → `AuthLoginSuccess` with roles `['ff_support','roles_version:1']`, `operator_id=demo-operator`, `location_id=demo_restaurant_001`, synthetic unsigned JWT carrying honest `email`/`name`/`is_ff_support`. Every other credential → `AuthLoginFailure('invalid_credentials')`. |
| `lib/main_forgeflow.dart:7-9,118-160` | New `_demoAuthEnabled` (`kDemoMode`/`FORGE_FLOW_DEMO_MODE`) bootstrap branch: mounts `ForgeFlowApp(requireAuth: true)` + `DemoAuthLoginService` + `InMemorySecureSessionStorage` + `InMemoryAuthSessionLedgerWriter`. Returns before the unchanged final production fallthrough line. |
| `lib/screens/settings/settings_data_sections.dart:429-451,474-481,496-520,678-712` | `SettingsAccountSection.allowDemoAccountInfoFallback`; when gateway null + flag true + session present, render `_fallbackAccountInfoForSession` (honest, no network) instead of `SizedBox.shrink()`. |
| `lib/screens/settings_screen.dart:73-87,484-489` | Thread `allowDemoAccountInfoFallback` (default false) into the Account-tab `SettingsAccountSection`. |
| `lib/forge_flow_app.dart:1218-1224` | `_openSettings` passes `allowDemoAccountInfoFallback: widget.accountInfoGateway == null` (exact mirror of the line-above `allowDemoActiveSessionsFallback`). |
| `test/services/auth/demo_auth_login_service_test.dart` (new) | 7 tests: ff_support mint, case-insensitive, DemoScope drift guard, honest token, wrong-pw/unknown fail-closed, refresh. |
| `test/screens/settings_demo_account_ff_admin_test.dart` (new) | 3 widget tests: demo session → Account+Data tabs+Data-alignment; honest Account card not blank; operator-tier session → no Data tab/alignment + blank Account (elevation fixture-scoped). |
| `CLAUDE.md` (Demo Mode), `docs/contracts/demo_mode_contract.md` | Documented the writer-side demo auth source-swap. |

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Slice intent met | PASS | Demo session now non-null with `ff_support` → Account tab (`settings_screen.dart:245`), Data tab (`_shouldShowDataTab` `:608-630`), Data-alignment panel (`:440-444`) all render. Widget test `demo F&F-admin session: Account + Data tabs render…` green. |
| 2 | Authority order | PASS | Prompt > CLAUDE.md Demo Mode (HP #2 writer-side) > `demo_mode_contract.md`. `ff_support` (not `super_admin`) per prompt #2; maps to `admin_auth_gate.dart:50` `kAdminConsoleRoles` + `_isFFAccount` (`settings_screen.dart:581-585`). |
| 3 | HP #2 — writer-side only, no reader branch / no `demo_*` | PASS | The fix is a *bootstrap source-swap* (`main_forgeflow.dart` selects `DemoAuthLoginService` vs `FirebaseAuthLoginService`) — the demo analogue of `MockReplayDataSourceProvider`, mirroring the contract-endorsed `OPERATOR_WEB_DEMO_AUTH`/`ADMIN_DEMO_AUTH` (`demo_mode_contract.md:214-228`). Zero `kDemoMode` reads added to reader code; no `demo_*` table; `settings_screen.dart` / gates read `session` identically demo+prod. `_demoAuthEnabled` is a writer-side gate, not a reader carve-out, so it is documented under Demo Mode "Architecture" (writer bullet), not the reader carve-out list. |
| 4 | Production auth byte-unchanged | PASS | `FORGE_FLOW_USE_FIREBASE_AUTH` block in `main_forgeflow.dart`/`main.dart` untouched; `_demoAuthEnabled` is false in production (no `kDemoMode`), so control flows to the unchanged final `bootstrapAndRunApp(const ForgeFlowApp())`. `DemoAuthLoginService` is referenced only by the demo branch. New `allowDemo*Fallback` flags default false; `forge_flow_app.dart` passes `accountInfoGateway == null` (false when prod proxy gateway wired). Widget test `production posture unchanged…` proves operator-tier session gets no Data tab/alignment + blank Account. |
| 5 | Metric Honesty | PASS | Account fallback uses `_fallbackAccountInfoForSession` (real session-derived email/name/roles); synthetic token carries the *actual* demo identity. No phantom values — `—`/honest-empty paths in `_buildAccountInfoCard` (`settings_data_sections.dart:665-685`) preserved. |
| 6 | HP #11 scope/inherited/effective | PASS | No settings-scope rendering touched; `SettingsAccountSection` change is render-gating only (viewOnly card vs blank). Setup/hierarchy tabs unaffected. |
| 7 | Scope discipline | PASS | Only auth fixture + `main_forgeflow.dart` + minimal `settings_screen.dart`/`settings_data_sections.dart`/`forge_flow_app.dart` + tests + docs. Concurrency-owned files (`mock_integration_replay_seed.dart`, `sqlite_database_seed.dart`, `shift_dashboard.dart`, `shift_service_period_notifier.dart`, Benchmark/Settings-declutter) NOT touched (`git diff --stat`). |
| 8 | No regression to recent UX work | PASS | Diff does not touch shift/daypart/chip-border/closed-state files. Existing `settings_screen_collapse_test.dart` (incl. MO-5b labels, demo-row gating, Demo→Live switch) green unchanged. |
| 9 | Null-safety / degrade | PASS | `DemoAuthLoginService` returns typed results, never throws on bad creds; `allowDemoAccountInfoFallback` guarded by `session != null` + `mounted`; in-memory ledger so demo sign-in does not fail closed (`auth_session_notifier.dart:296-357`). `flutter analyze` on the 7 touched files: **No issues found**. |
| 10 | Tests prove the seam | PASS | 10 new tests (7 service + 3 widget) + nearest existing settings/auth suites green (see below). DemoScope drift guard pins `kDemoOperatorLocationId == DemoScope.restaurantId`. |
| 11 | Backward compat | PASS | New widget params default false → all existing `SettingsScreen`/`SettingsAccountSection` call sites + tests compile/behave unchanged (full-project analyze: no new issues; collapse/active-sessions/mfa suites green). |
| 12 | UX writing | PASS | No new operator copy; reuses `_fallbackAccountInfoForSession` labels. Comments are engineering-facing only. |
| 13 | House rules | PASS | No `db/migrations/*` → drift scanner N/A. Hooks installed (step 0, `scripts/install_git_hooks.ps1`). No tracker/ledger edits. Docs updated (contract + CLAUDE.md). |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no `--no-verify`, no tracker edits. |

## Local verification (CI dark)

- `flutter pub get` — OK.
- `flutter analyze` (7 touched files: `demo_auth_login_service.dart`, `main_forgeflow.dart`, `settings_data_sections.dart`, `settings_screen.dart`, `forge_flow_app.dart`, both new tests) — **No issues found!**
- `flutter analyze lib test` (ripple check) — 71 pre-existing baseline infos/warnings + 4 pre-existing `PackagePostgresPool` errors in `test/.../weekly_plan_snapshot_repository_test.dart` (untouched, unrelated postgres file; treat per CLAUDE.md KNOWN_FAILING posture). **Zero issues in any touched file.**
- `flutter test test/services/auth/demo_auth_login_service_test.dart test/screens/settings_demo_account_ff_admin_test.dart test/screens/settings_screen_collapse_test.dart` — **+24 All tests passed!**
- `flutter test test/settings_active_sessions_section_test.dart test/settings_mfa_section_test.dart test/screens/settings_ux_declutter_test.dart test/screens/settings_pointer_row_test.dart` — **+26 All tests passed!**
- Full demo-flavor app build not run (heavy; `flutter analyze` covers compile of the changed Dart). Noted for the orchestrator's runtime-acceptance call.

## Residual / follow-ups

- The demo flavor now starts at the **login screen** (was: straight to
  dashboard) because `requireAuth: true` is required to mount the
  branded login + its "Use demo operator" one-tap. This matches the
  operator's described demo flow. Flagged for visual sign-off.
- The synthetic demo token is unsigned (`alg: none`) — intentional and
  safe: the demo flavor has no proxy to verify it; it exists only so
  the Account-card fallback decodes the honest identity. Production
  (real Firebase token) is untouched.
