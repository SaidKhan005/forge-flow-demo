# Audit — Location switch blanks Shift: defer DemoModeStateNotifier scope notify out of build

Branch: `claude/fix-demo-mode-scope-notify-during-build` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator column intentionally left blank.

> **Flag for orchestrator:** this touches **app-shell scope wiring**
> (`_AppShellState` demo-mode bind/sync path). Review before merge.

## Defect (operator-reproduced, binding)

Switching the active location on mobile blanked the Shift screen (dropped
to the empty "HISTORICAL ONLY" state) and threw `setState() or
markNeedsBuild() called during build`, stack: `DemoModeStateNotifier.setScope`
→ `_AppShellState._syncDemoModeScope` → `_bindDemoModeNotifier` →
`didChangeDependencies` → `StatefulElement._firstBuild`.

## Root cause (confirmed on fresh master)

`AppShell` `context.watch`es `RestaurantScopeNotifier` for its
business-scope drawer (`lib/forge_flow_app.dart:993`). A location switch
fires that notifier → `_AppShellState.didChangeDependencies`
(`:625-629`) re-runs → `_bindDemoModeNotifier` (`:639-676`) →
`_syncDemoModeScope` → `DemoModeStateNotifier.setScope`
(`lib/state/demo_mode_state_notifier.dart:170-190`). `setScope` runs
synchronously up to its first `await`: on a real scope change it resets
`_snapshot` to a records-empty snapshot and calls `notifyListeners()`
(`:183-188`) *before* `await refresh()`. Because this whole chain runs
inside the build phase, `notifyListeners()` `markNeedsBuild`s the mounted
`DemoModeBanner` (a `context.watch<DemoModeStateNotifier>` dependent,
`lib/widgets/demo_mode_banner.dart:37`, mounted at
`lib/forge_flow_app.dart:1510`) mid-build → framework throw; the
just-cleared empty snapshot also flashed Shift to its empty branch.

## Fix (minimal — app-shell post-frame deferral; notifier untouched)

Chose the prompt's **preferred** option: defer the notifier mutation in
`_AppShellState`, leaving `DemoModeStateNotifier`'s public contract,
`_generation` bump, empty→clear, and coalesced `refresh()` byte-unchanged.

| File | Change |
|---|---|
| `lib/forge_flow_app.dart:714-763` | Split `_syncDemoModeScope` into a thin post-frame scheduler (`_syncDemoModeScope`, `:732-738` — `WidgetsBinding.instance.addPostFrameCallback`, `if (!mounted) return;` guard on both the schedule and the callback) + the unchanged resolve/dedupe/`setScope`/`clear` body moved verbatim into `_applyDemoModeScope` (`:742-763`). Deferral is uniform (listener path too) so call ordering and the `_demoModeBoundScopeKey` dedupe are preserved. |
| `test/forge_flow_app_demo_mode_scope_defer_test.dart` (new, 1 test) | Mounts real `AppShell` with the production-style provider set + `DemoModeStateNotifier` + stub `SyncProxyClient`; flips a no-SQLite `RestaurantScopeNotifier` subclass to a new (operator, location). Asserts `tester.takeException()` is null on both first mount and switch, snapshot scope advanced to `op-2/loc-2` (semantics preserved), stub fetched `op-2:loc-2`, and `DemoModeBanner` still mounted. |

`lib/state/demo_mode_state_notifier.dart` — **not modified** (the
alternative option was not taken; its contract stays identical).

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Evidence | Orchestrator |
|---|---|---|---|---|
| 1 | Slice intent met | PASS | Notifier mutation no longer runs during build; switch throws no exception and snapshot advances to the new scope (`forge_flow_app.dart:732-763`; new test green, and **red on stashed-fix run** — verified pre-fix failure). | |
| 2 | Authority order | PASS | Prompt > CLAUDE.md Demo Mode rules honored: no `kDemoMode` reader branch, no `demo_*` table, scope-resolution logic byte-identical (`_applyDemoModeScope` body copied verbatim, `:742-763`). | |
| 3 | Scope semantics unchanged | PASS | Same `(scope?.operatorId ?? session?.operatorId)` resolution, same empty→`clear()`, same `_demoModeBoundScopeKey` dedupe, same `unawaited(setScope(...))` (`:746-762`, identical to prior `:717-736`). Only the invocation site moved to `addPostFrameCallback`. | |
| 4 | Notifier contract intact | PASS | `lib/state/demo_mode_state_notifier.dart` not in `git diff --stat`; `setScope`/`clear`/`refresh`/`_generation` untouched. | |
| 5 | Metric Honesty / Design Rule 2 | N/A | No metric/provenance surface touched; no copy. The fix removes a *false* blank-state flash (transient empty snapshot now post-frame, consumers reconcile normally). | |
| 6 | No app-logic change (HP #3) | PASS | Pure widget-lifecycle timing change; no formula/decision logic. `7.58`+ boundary respected. | |
| 7 | Scope discipline | PASS | `git diff --stat` = `lib/forge_flow_app.dart` only (+1 new test). `lib/screens/shift_dashboard.dart` & `lib/screens/baseline_tracker.dart` (sibling-owned) untouched; no seed files; notifier untouched. | |
| 8 | Listener path still works | PASS | `_syncDemoModeScope` is still the exact method reference registered/removed as the auth + scope listener (`:653-655,:671-673`) and disposed (`:1114-1118`); now uniformly post-frame, which the prompt explicitly permits ("a uniform post-frame deferral … is acceptable and simplest"). | |
| 9 | Dedupe / no thrash | PASS | `_demoModeBoundScopeKey` check stays inside `_applyDemoModeScope` (`:758-761`); rapid same-scope rebinds still early-return; multiple scheduled callbacks converge (each re-reads live scope, first to differ sets the key, rest no-op). | |
| 10 | mounted / teardown safe | PASS | `if (!mounted) return;` guards both the scheduler entry and the post-frame callback (`:733,:736`) and the apply body (`:743`); dispose still removes listeners + nulls the key (`:1114-1118`). | |
| 11 | Null-safety / analyze | PASS | `dart analyze lib/forge_flow_app.dart lib/state/demo_mode_state_notifier.dart test/forge_flow_app_demo_mode_scope_defer_test.dart` → after the lone `use_super_parameters` info was fixed in the test, **No issues found!** | |
| 12 | Tests prove the seam | PASS | New test fails pre-fix (stash-verified: `+0 -1` at the first `takeException` assertion) and passes post-fix; reproduces the real `didChangeDependencies` re-run path, not a mock. | |
| 13 | No regression in related tests | PASS | `forge_flow_app_business_scope_drawer_test` + `app_resume_refresh_test` + `app_boundary_refresh_test` + `widgets/demo_mode_banner_test` → **+22 All tests passed!** No new vs KNOWN_FAILING_TESTS deltas (none of these were listed failing). | |
| 14 | Contract STOP | PASS | Step 0 hooks installed; branch → implement → self-audit → commit + push → PR → STOP. No merge, no tracker edits, no `--no-verify`. | |

## Local verification (CI dark — honest disclosure)

- `pwsh`/`powershell scripts/install_git_hooks.ps1` — hooks enabled (pre-commit, pre-push).
- `flutter pub get` — `Got dependencies!`
- `dart analyze lib/forge_flow_app.dart lib/state/demo_mode_state_notifier.dart test/forge_flow_app_demo_mode_scope_defer_test.dart` — **No issues found!**
- `flutter test test/forge_flow_app_demo_mode_scope_defer_test.dart` — **+1 All tests passed!**
- Pre-fix verification: `git stash push -- lib/forge_flow_app.dart` then same `flutter test` → **+0 -1 Some tests failed** (`takeException` non-null = the framework throw), then `git stash pop` to restore. Confirms the test guards the exact defect.
- `flutter test forge_flow_app_business_scope_drawer_test.dart app_resume_refresh_test.dart app_boundary_refresh_test.dart widgets/demo_mode_banner_test.dart` — **+22 All tests passed!**

## Residual / follow-ups

None. The brief empty window while `refresh()` is in flight is now
strictly post-frame, so consumers reconcile through the normal notify
cycle instead of being torn down mid-build. No `kDemoMode` branch, no
`demo_*` table, no scope-resolution change introduced.
