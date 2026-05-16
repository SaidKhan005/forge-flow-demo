# Audit — Fix: Settings data-action `_refreshAfterWrite` crashes on unmounted State

Branch: `claude/fix-settings-refresh-unmounted-context` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator independent-audit column intentionally left blank.

## Defect (console-captured, emulator-5554, 2026-05-16, binding)

After a Settings data action (Mock-Replay reseed / date-advance / data reset) the app threw repeatedly:

```
Unhandled Exception: This widget has been unmounted, so the State no longer has a context
(and should be considered defunct).
#2 _SettingsScreenState._refreshAfterWrite (lib/screens/settings_screen.dart:165:10)
#3 SettingsMockReplaySection.build.<anonymous closure> (lib/screens/settings/settings_data_sections.dart:241/265)
   SettingsDataManagementSection.build.<anonymous closure> (…:405)
```

## Symptom verification on fresh tree (pre-change)

Confirmed real on the worktree's `origin/master`-equivalent tree (`20c15c70`) before any edit:

- `_SettingsScreenState._refreshAfterWrite` was guarded by `if (!context.mounted) return;` (pre-change `settings_screen.dart:165`). `State.context` is a getter that **throws** `"…unmounted, so the State no longer has a context … defunct"` when the State is defunct — the `context` sub-expression is evaluated *before* `.mounted`, so the guard line itself is the throw site (matches frame `#2 …:165:10`). Reproduced deterministically in test #3 below (`() => state.context` → `FlutterError` containing `"defunct"`).
- `_refreshAppState` (pre-change `:138`) had the identical `if (!context.mounted) return;` antipattern — same latent bug, exercised by `_handlePullToRefresh`.
- The awaiting closures in `settings_data_sections.dart` (`SettingsMockReplaySection` reseed / advance; `SettingsDataManagementSection` clear / reset-cycle) `await` a long write, then `await onAfterWrite()` (= `_refreshAfterWrite`) **with no mounted guard between the write and the callback** — so a screen unmounted during the awaited write crashed on resume. Symptom real.

## Root cause

`State.context` throws on a defunct `State`; `State.mounted` (a plain `bool` field) does not. Guarding an async State method with `context.mounted` is therefore self-defeating — the guard is the crash. Fix: use the non-throwing `State.mounted` in the State methods, and add a `BuildContext.mounted` (the safe `Element.mounted`) short-circuit in the StatelessWidget section closures so the post-write path is a clean no-op when the section unmounted mid-write.

## What changed (2 files, lifecycle guards only — no behaviour/logic change)

| File | Change |
|---|---|
| `lib/screens/settings_screen.dart:142` | `_refreshAppState`: `if (!context.mounted) return;` → `if (!mounted) return;` (+ doc comment). Sibling of the crashing method, same antipattern. |
| `lib/screens/settings_screen.dart:177` | `_refreshAfterWrite`: `if (!context.mounted) return;` → `if (!mounted) return;` (+ doc comment). **The captured crash line.** Context is touched only *before* the awaits (`context.read<AppRefreshCoordinator>()`); post-await work is delegated to `_loadStatus`/`_loadMockDate`, which already re-check `State.mounted` before their own `setState` (`:127`, `:132`) — so a single top guard is sufficient and correct here. |
| `lib/screens/settings/settings_data_sections.dart:245` | `SettingsMockReplaySection` reseed closure: `if (!context.mounted) return;` after `await ShiftService.instance.reseedDemo()`, before `await onAfterWrite()`. |
| `lib/screens/settings/settings_data_sections.dart:272` | Same guard after `await advanceMockReplayDay()`. |
| `lib/screens/settings/settings_data_sections.dart:353` | `SettingsDataManagementSection` clear closure: same guard after `await clearAllData()`. |
| `lib/screens/settings/settings_data_sections.dart:419` | Reset-target-cycle closure: same guard after `await resetForAdminTest()`. |
| `test/screens/settings_refresh_unmounted_context_test.dart` (new, 3 tests) | Faithful two-layer reproduction (StatelessWidget section closure → parent State method) of the exact crash sequence. |

The pre-existing `ScaffoldMessenger` snackbars stay guarded by their original `if (context.mounted)` blocks (`BuildContext.mounted`, already safe). No other files touched.

## Why a reproduction harness (not the literal closure) in the test

`ShiftService.instance` is a non-injectable `final` singleton (`shift_service.dart:75`) owned by sibling worker **W6** (out of scope to add a seam), and its real `reseedDemo` also hits a separate, out-of-scope seed PK-collision defect — so the literal closure cannot be driven deterministically here. The new test reproduces the exact two-layer lifecycle shape (StatelessWidget section closure that awaits a long write then calls back into a parent `State` method) and locks the guard contract the fix depends on. This is disclosed honestly in the test header.

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Orchestrator verdict |
|---|---|---|---|
| 1 | Slice intent met | PASS — Crash line `_refreshAfterWrite` now guarded by non-throwing `State.mounted` (`settings_screen.dart:177`); sibling `_refreshAppState` likewise (`:142`); 4 awaiting closures short-circuit on `BuildContext.mounted` after the write (`settings_data_sections.dart:245,272,353,419`). New test asserts `takeException()==null` on unmount AND refresh still runs when mounted. | |
| 2 | Authority order | PASS — Prompt > CLAUDE.md. Pure lifecycle defensive fix; no Tier-2 contract touched. Metric Honesty / Design Rule 2 unaffected (no metric/read path changed). | |
| 3 | No behaviour change when mounted | PASS — Guards only short-circuit the *unmounted* path. Mounted path: `_refreshAfterWrite` still calls `context.read<AppRefreshCoordinator>().refreshAfterWrite()` + `_loadStatus()` + `_loadMockDate()` unchanged (`:177-186`); closures still `await onAfterWrite()` + snackbar unchanged. Test #2 proves the mounted refresh still runs. | |
| 4 | Real errors not swallowed | PASS — Guards are placed *after* the awaited write call (`reseedDemo`/`advanceMockReplayDay`/`clearAllData`/`resetForAdminTest`), so if the write itself throws (e.g. the separate reseed PK collision) it surfaces exactly as before — only unmounted-State *access* is made safe. The pre-existing `try/catch (_)` around `context.read<AppRefreshCoordinator>()` is unchanged (it only swallows the test-only ProviderNotFound, as before). | |
| 5 | No `kDemoMode` branch / no `demo_*` table | PASS — `git diff` introduces no `kDemoMode`, no `demo_*` table, no reader fork. Carve-out #3 const untouched. | |
| 6 | Correct guard primitive | PASS — State methods use `State.mounted` (non-throwing field); StatelessWidget closures use `BuildContext.mounted` (safe `Element.mounted`) per current Flutter `use_build_context_synchronously` guidance. Test #3 proves `State.context` throws "defunct" while `State.mounted` is `false` without throwing. | |
| 7 | Post-await context use covered | PASS — `_refreshAfterWrite` touches `context` only *before* its awaits; post-await it calls `_loadStatus`/`_loadMockDate`, each already `if (mounted)`-guarded before `setState` (`:127`,`:132`). `_handlePullToRefresh`'s post-await `setState` already guarded `:159`. The other post-frame `Navigator.of(context)` at `:579` is already `if (!mounted) return;`-guarded (pre-existing, untouched, correct). No remaining unguarded post-await State.context use in the touched State. | |
| 8 | Scope discipline | PASS — `git diff --stat`: exactly `lib/screens/settings_screen.dart` (+16/−2) and `lib/screens/settings/settings_data_sections.dart` (+14/−0) + 1 new test. Seeders (`lib/infrastructure/persistence/sqlite/**`), `baseline_manager_service.dart`, demo seed files, `forge_flow_app.dart` NOT touched. | |
| 9 | Concurrency boundary (W6) | PASS — Did not touch ShiftService / seeders / Riverside per-location data / reseed idempotency. ShiftService treated as read-only opaque singleton; test discloses the non-injectable seam rather than adding one. | |
| 10 | No new widget / no UX copy change | PASS — No widgets added, no strings changed; snackbars byte-identical. | |
| 11 | Idempotent / safe no-op | PASS — Unmounted path returns before any side effect; `State.mounted` and `BuildContext.mounted` are idempotent reads. No new async race introduced. | |
| 12 | Tests prove the seam | PASS — `test/screens/settings_refresh_unmounted_context_test.dart` 3/3 green: (1) unmount-mid-write → no exception + refresh skipped; (2) stays mounted → refresh runs; (3) root-cause: `State.context` throws "defunct", `State.mounted` safe. Regression would fail test 1. | |
| 13 | House rules | PASS — No `db/migrations/*` → drift scanner N/A. Git hooks installed at step 0 (pre-commit/pre-push enabled). No tracker/ledger edits. `dart analyze` clean on all 3 touched/added files. CI dark — results disclosed below honestly. | |
| 14 | Contract STOP | PASS — branch → implement → self-audit → commit + push → open PR → STOP. No merge, no tracker advance, no `--no-verify`. | |

## Local verification (CI dark — honest results)

- `flutter pub get` — **Got dependencies!** (53 transitive packages have newer incompatible versions; pre-existing, unrelated).
- `dart analyze lib/screens/settings_screen.dart lib/screens/settings/settings_data_sections.dart` — **No issues found!**
- `dart analyze test/screens/settings_refresh_unmounted_context_test.dart` — **No issues found!**
- `flutter test test/screens/settings_refresh_unmounted_context_test.dart` — **+3 All tests passed!**
- `flutter test settings_screen_collapse_test.dart settings_ux_declutter_test.dart settings_demo_account_ff_admin_test.dart settings_mfa_section_test.dart settings_active_sessions_section_test.dart` — **+39 All tests passed!** (no Settings widget regressions; no pre-existing failures observed in this set, so no KNOWN_FAILING_TESTS snapshot needed for it).

## Residual / follow-ups

None blocking from this fix. The separate seed PK-collision defect (real `reseedDemo` failing on the emulator) and the Riverside planning-anchor errors are explicitly **owned by sibling worker W6** and out of this PR's scope — this PR only makes the unmounted-State access safe; if the awaited write itself throws, that surfaces unchanged for W6's fix.
