# Audit — Demo location switch now re-scopes the data (was pinned to Downtown; no refresh on switch)

Branch: `claude/fix-qa-location-scope-not-propagated` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line). Orchestrator column intentionally left blank.

> **Flag for orchestrator:** scope-wiring, cross-surface (`_AppShellState`
> scope-flip → `AppRefreshCoordinator` fan-out). Review before merge.

## Defect (operator-reproduced, binding) — two symptoms, one root

- **A.** Swapping the active location only changed the header / location
  name; Shift / Variance / Plan / Benchmark data stayed identical.
- **B.** After switching, pull-to-refresh made the data disappear
  (HISTORICAL ONLY / empty) — the switched location lacked a
  current-week open shift. **SEED side**, owned by sibling worker
  `claude/fix-qa-perloc-current-week-open-shift` — **not this PR**.

## Root cause (confirmed on fresh master c3055425)

Selecting a location already propagates the new `restaurantId` into the
scope `getActiveRestaurantId()` resolves:
`RestaurantScopeNotifier.activateBusinessScope`
(`lib/state/restaurant_scope_notifier.dart:167-178`) →
`_activateRestaurantForScope` (`:261-269`) →
`SqliteRestaurantScopeRepository.activateRuntimeRestaurant` sets
`_runtimeActiveRestaurantId`
(`lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart:69-78`),
so `getActiveRestaurantId()` (`:84-88`) returns the chosen location.

But the data notifiers read scope **once** — in their constructors —
and otherwise only reload on pull-to-refresh:
`ShiftDashboardNotifier` (`lib/state/shift_dashboard_notifier.dart:47-52,96`),
`ShiftServicePeriodNotifier` (`lib/state/shift_service_period_notifier.dart:236-241,269-272`),
`WeekDataNotifier` (`lib/state/week_data_notifier.dart:34-36,70-74`),
`ActiveTargetProfileNotifier` (`lib/state/active_target_profile_notifier.dart:24-28,42-44`).
Nothing called `refresh()` on a scope flip — `AppRefreshCoordinator`
(`lib/state/app_refresh_coordinator.dart`) only ran via the
active-target / `AppRuntimeInvalidationBus` ProxyProvider2 or the
boundary monitor, neither of which fires on a pure business-scope
change. The header updated because it watches `RestaurantScopeNotifier`
directly (`lib/forge_flow_app.dart:993`); the data stayed pinned to the
previously-resolved (Downtown / `DemoScope.restaurantId` cold-start)
location. (Symptom B is then the empty read at the correctly-switched
scope — the sibling SEED PR.)

## Fix (minimal — WIRING half only; no refresh *logic* change)

`_AppShellState` binds a listener to the provided
`RestaurantScopeNotifier` — the **same proven mechanism** the demo-mode
banner already uses (`_demoModeScopeListenedTo`, just-merged #815) — and
on a genuine `activeScope` flip schedules **one post-frame**
`AppRefreshCoordinator.refreshAll()` (the exact path Settings wage
changes already use). `refreshAll()` re-scopes scope + active target +
demand + weights; the active-target → ProxyProvider2 cascade then
re-scopes the current-state surfaces (week, shift, service-period).
**No change to what `refresh()`/`refreshAll()` computes — only WHEN /
at-what-scope they run.**

| File | Change |
|---|---|
| `lib/forge_flow_app.dart:632-634,668-725,733,1238-1239` | New fields `_scopeRefreshListenedTo` / `_lastScopeRefreshKey` / `_scopeRefreshScheduled`; `_bindScopeRefreshNotifier()` (bound from `didChangeDependencies:733`, mirrors `_bindDemoModeNotifier`; seeds the dedupe key with the current scope so the initial bind is **not** a spurious reload); `_handleScopeChangedForRefresh()` (ignores non-location scopes, dedupes by `BusinessScope.stableKey`); `_scheduleScopeDataRefresh()` (coalesced `addPostFrameCallback` + `mounted` guard + `ProviderNotFoundException` no-op for shell-only widget tests); dispose removes the listener. +109 lines, one file. |
| `test/forge_flow_app_scope_switch_data_refresh_test.dart` (new, 1 test) | Mounts real `AppShell` with the production-style provider set **including the verbatim ProxyProvider2 cascade body**; flips a no-SQLite switchable `RestaurantScopeNotifier` subclass. Asserts: no framework exception on mount + switch (#815 guard); scope + target + demand re-scoped and week + shift + service-period re-scoped **without a manual pull**; same-scope re-notify deduped (exactly one reload/switch); a new location triggers exactly one more. |

Design note (honest disclosure): an initial attempt subscribed to
`ActiveBusinessScopeChangeBus` (also published by
`activateBusinessScope`). It was replaced with the
`RestaurantScopeNotifier` listener because (a) `activeScope` is the
authoritative in-process state the AppShell already `context.watch`es,
(b) it is synchronous and deterministic in widget tests, and (c) it
reuses the file's existing, #815-hardened bind/post-frame pattern
verbatim rather than introducing a second, async signal path.

## Pattern B — 14-lens self-audit

| # | Lens | Worker verdict | Evidence | Orchestrator |
|---|---|---|---|---|
| 1 | Slice intent met | PASS | Selecting a location now re-scopes every named data surface without a pull; new test green and **red pre-fix** (verified: with the listener removed the switch leaves all `refreshCount`/`loadCount` at baseline). `forge_flow_app.dart:668-725`. | |
| 2 | Authority order | PASS | Prompt > CLAUDE.md HP #2/#4 > #815. No `kDemoMode` reader branch, no `demo_*` table; per-(operator,location) isolation unchanged; refresh deferral post-frame/mounted per #815 (`:716-724`). | |
| 3 | Scope propagation correct | PASS | Repo override path unchanged (`sqlite_restaurant_scope_repository.dart:69-88`); the fix only adds a *trigger* so notifiers re-read the already-correct scope. `?? DemoScope.restaurantId` remains a cold-start-only default. | |
| 4 | No refresh-logic change | PASS | `refreshAll()` / `refreshCurrentStateSurfaces()` bodies untouched (`app_refresh_coordinator.dart` not in `git diff --stat`); only a new caller. Same path Settings wage changes use. | |
| 5 | Core formulas / RLS / proxy / auth untouched | PASS | `git diff --stat` = `lib/forge_flow_app.dart` only (+ new test). No `LaborModel`/`TargetCycle`/snapshot, no `OperatorScopedRepository`, no RLS policy, no proxy, no auth. **No architectural boundary hit → no FOLLOW-UP NEEDED.** | |
| 6 | No app-logic change (HP #3) | PASS | Pure widget-lifecycle wiring (when refresh fires); no decision/formula logic. `7.58`+ boundary respected. | |
| 7 | Scope discipline / concurrency | PASS | Did NOT touch `sqlite_database*.dart` seed bodies, `mock_integration_replay_seed.dart`, or any notifier/repository internals — those (incl. the SEED half) are sibling-owned. Only AppShell scope-listener wiring, as scoped. | |
| 8 | #815 build-safety preserved | PASS | Refresh is `addPostFrameCallback` + `if (!mounted) return;` (`:716-724`); the listener is a synchronous ChangeNotifier callback that never runs during build (stream/notify boundary), and the mutation is post-frame — mirrors `_syncDemoModeScope`→`_applyDemoModeScope`. Test asserts `tester.takeException()` null on mount + both switches. | |
| 9 | Dedupe / exactly-one reload | PASS | `_handleScopeChangedForRefresh` early-returns on non-location or `stableKey == _lastScopeRefreshKey` (`:700-704`); `_scheduleScopeDataRefresh` coalesces via `_scopeRefreshScheduled` (`:714-715`). Test proves same-scope re-notify = 0 extra reloads, new location = exactly 1. Initial bind seeds the key so cold start is not a spurious reload (`:686-688`). | |
| 10 | mounted / teardown safe | PASS | `mounted` guard on the post-frame callback (`:718`); dispose removes the listener and nulls the ref (`:1238-1239`); `_bindScopeRefreshNotifier` rebinds idempotently via `identical(...)` early-return (`:678`). | |
| 11 | Null-safety / analyze | PASS | `dart analyze lib/forge_flow_app.dart test/forge_flow_app_scope_switch_data_refresh_test.dart` → **No issues found!** (full-repo `info` lints are pre-existing, in untouched test/tool files.) | |
| 12 | Test proves the seam | PASS | Reproduces the real `RestaurantScopeNotifier` flip path against the real `AppShell` + verbatim ProxyProvider2 cascade; asserts every named notifier (scope/target/demand/week/shift/service-period) reloads at the new scope without a pull. Mirrors the #815 harness. | |
| 13 | No PR-introduced regression | PASS | Baseline snapshotted on clean `origin/master` c3055425: `restaurant_scope_notifier_test.dart:296,328` (2) and `shift_dashboard_daypart_toggle_widget_test.dart` (3, batch-pollution only — passes standalone) fail **identically with and without this PR**, in files this PR does not touch. `forge_flow_app_demo_mode_scope_defer_test` + `app_refresh_coordinator_test` + `app_resume_refresh_test` + `app_boundary_refresh_test` + `current_state_propagation_contract_test` → green with this PR. | |
| 14 | Contract STOP | PASS | Step 0 hooks installed; branch → implement → self-audit → commit + push → PR → STOP. No merge, no tracker edits, no `--no-verify`. | |

## Local verification (CI dark — honest disclosure)

- `powershell scripts/install_git_hooks.ps1` — hooks enabled (pre-commit, pre-push).
- `flutter pub get` — `Got dependencies!`
- `dart analyze lib/forge_flow_app.dart test/forge_flow_app_scope_switch_data_refresh_test.dart` — **No issues found!**
- `flutter test test/forge_flow_app_scope_switch_data_refresh_test.dart` — **+1 All tests passed!**
- `flutter test forge_flow_app_demo_mode_scope_defer_test app_refresh_coordinator_test app_resume_refresh_test app_boundary_refresh_test state/restaurant_scope_notifier_test current_state_propagation_contract_test` → **+52 -2**; the 2 (`restaurant_scope_notifier_test.dart:296,328`) **also fail on clean origin/master c3055425** (verified via temp `git worktree` at `origin/master`) — pre-existing seed/test drift from #824/#826, files untouched by this PR.
- `flutter test shift_visual_widget_test shift_freshness_ui_test shift_dashboard_daypart_toggle_widget_test current_state_propagation_contract_test` → **+33 -3**; the 3 (`shift_dashboard_daypart_toggle_widget_test.dart`) are **pre-existing cross-file batch pollution** — the file passes **+8 standalone** on both this branch and clean `origin/master`, and the 4-file batch fails identically `+33 -3` on clean `origin/master`.
- Fix stayed **entirely within demo-safe scope-propagation + refresh-on-switch wiring**. The `OperatorScopedRepository`/RLS/proxy/auth boundary was **not** hit — **no `FOLLOW-UP NEEDED`** on that axis.

## Residual / follow-ups

- **Symptom B is the sibling SEED PR's job**, not this one. This PR proves
  the WIRING (every named notifier reloads at the new scope on switch,
  deduped, post-frame, #815-safe). The end-to-end "the switched
  location shows ITS rows, not Downtown's" assertion is gated on
  `claude/fix-qa-perloc-current-week-open-shift` seeding each location a
  current-week open shift; once both land, a multi-location SQLite
  integration test can assert the rendered rows differ per location.
- No `kDemoMode` branch, no `demo_*` table, no scope/RLS/formula change
  introduced.
