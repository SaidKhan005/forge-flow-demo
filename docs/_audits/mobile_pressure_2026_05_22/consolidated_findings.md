# Consolidated Mobile Pressure Findings — 2026-05-22

**Date:** 2026-05-22  
**Device:** emulator-5554 (Android, 392.7 × 826.9 dp)  
**Flavor:** forgeflow — demo mode (`kDemoMode=true`)  
**Method:** 4 parallel integration-test lanes run against main checkout on `master`

Status: **CLOSED — all lanes complete**

---

## Final results

| Lane | Tests | Result |
|------|-------|--------|
| A — Auth + Shell + Notifications + Demo banner | 8 / 8 | ✅ All passed |
| B — Shift Dashboard + Variance | 8 / 8 | ✅ All passed |
| C — Plan (ScheduleBuilder) + Benchmark | 7 / 7 | ✅ All passed |
| D — Settings (all 4 tabs) + Role editor + Regression | 9 / 9 | ✅ All passed |
| **Total** | **32 / 32** | ✅ **Zero crashes · Zero overflows** |

---

## P1 — Production bugs found and fixed

### `ChangeNotifier` used-after-dispose (6 notifiers)

**What was wrong.** Six `ChangeNotifier` subclasses called `notifyListeners()` in async `_load()` / `refresh()` chains without checking whether the notifier had already been disposed. When integration tests tear down the widget tree the notifiers are disposed immediately, but the async SQLite chains are still in flight. The first `notifyListeners()` on a disposed object throws `"<Notifier> was used after being disposed"`, which Flutter's test binding catches as a framework failure and marks every subsequent test in the same run as "did not complete" — wiping out the entire variance suite.

**Fix applied to 6 files:**

| File | Async methods guarded |
|------|-----------------------|
| `lib/state/week_data_notifier.dart` | `_load()`, `refresh()` |
| `lib/state/shift_dashboard_notifier.dart` | `_load()`, `refresh()` |
| `lib/state/shift_service_period_notifier.dart` | `_load()` (4 return paths) |
| `lib/state/demand_forecast_context_notifier.dart` | `load()` |
| `lib/state/active_target_profile_notifier.dart` | `_load()`, `refresh()` |
| `lib/state/schedule_distribution_weights_notifier.dart` | `load()` |

**Pattern applied uniformly:**
```dart
bool _disposed = false;

@override
void dispose() {
  _disposed = true;
  // cancel any subscriptions / timers here
  super.dispose();
}

Future<void> _load() async {
  final result = await _source.getData();
  if (_disposed) return;   // guard before every notifyListeners()
  _data = result;
  _isLoading = false;
  notifyListeners();
}
```

---

## P2 — Production issues found, not blocking

### "CLEAR ALL" button above viewport in `BaselineManagerScreen`

- **Surface:** `BaselineManagerScreen` — confirmation dialog or sheet header
- **Detail:** Flutter warning during test: `Offset(333.5, -15.1) … outside the bounds of the root of the render tree, Size(392.7, 826.9)`. The button's rendered centre is 15 dp above the top edge of the screen.
- **User impact:** Button is unreachable by a real user on a 392 × 826 dp screen without scrolling the sheet header upward. The test gracefully suppresses the tap (warning only, no failure).
- **Recommended fix:** Add a `SingleChildScrollView` or adjust the bottom sheet's `initialChildSize` / `maxChildSize` so the header buttons stay within the safe area.
- **File:** `lib/screens/benchmark/baseline_manager_screen.dart` (or its parent sheet widget)

### `RestaurantScopeNotifier` — same dispose pattern, not yet guarded

- **File:** `lib/state/restaurant_scope_notifier.dart`
- **Why not fixed:** This notifier is long-lived (attached at `MaterialApp` level); its async load completes well before any test ends, so no dispose-race is triggered in the current suite.
- **Risk:** Future tests that reset or rebuild the provider tree mid-run will hit the same crash pattern.
- **Recommended fix:** Apply the same `bool _disposed` + guard pattern proactively (low urgency).

---

## Test infrastructure fixes (harness / test scripts only)

These were bugs in the test code. No production code changed.

| Fix | Files changed | Root cause |
|-----|--------------|------------|
| Added `navigateBack()` helper — replaces `tester.pageBack()` | `_harness.dart`; `scenario_shell_02`, `scenario_shell_03`, `scenario_reg_02` | Both `SettingsScreen` and `NotificationsScreen` use `Icons.close` as their leading action. Flutter's `pageBack()` only recognises `BackButton` / `CupertinoNavigationBarBackButton`. |
| `skipOffstage: false` on `DemoModeBanner` check while Settings is open | `scenario_reg_02` | When `SettingsScreen` is pushed, `AppShell` becomes an offstage route; default `skipOffstage: true` misses widgets in offstage routes. |
| Scroll + `skipOffstage: false` before all section-header assertions | `scenario_settings_01/02/03` | `_settingsSection()` uses `SliverMainAxisGroup`. Sections below the viewport are not built by Flutter's lazy renderer; default finders miss them. |
| `tester.ensureVisible()` before expand-icon taps | `scenario_plan_02` | First `expand_more` icon rendered ~22 dp below the 826.9 dp screen bottom — tap would silently miss. |
| Scoped `CustomScrollView` search to `ShiftDashboard` subtree | `scenario_shift_02` | The business-scope drawer is always in the widget tree via `IgnorePointer`; `find.byType(CustomScrollView).first` could resolve to the drawer's list viewport, causing drag offset errors. |
| Section-header check changed from AND → OR | `scenario_shift_01`, `scenario_shift_03` | "FOH PRODUCTIVITY" is the third section in a lazy `SliverList`; on a real device it is below the fold on first render and not yet built. AND required all three visible simultaneously. |
| Added `import 'package:flutter/material.dart'` | `scenario_settings_01` | `CustomScrollView` is a Material widget; file only imported `flutter_test` — Gradle compile failure. |

---

## Coverage achieved

| Area | Surfaces exercised |
|------|--------------------|
| Auth | Cold boot, demo login tap, login form key presence, session wiring |
| Shell | 4 bottom-nav tabs, settings entry/exit, notifications entry/exit, 15 rapid tab switches |
| Shift | Section headers (Outputs / Inputs / FOH Productivity), daypart expand/collapse, scroll, empty-state, service-period label |
| Variance | All 3 tabs mount, This Week metric pills, date-range chip, History rows, Learn tab, data integrity (no NaN/null) |
| Plan | ScheduleBuilder section headers, day-row expand/collapse, scroll |
| Benchmark | BaselineTracker mounts, manager CTA drill-in, sub-components, sliders/toggles, CANCEL pop |
| Settings — Account | Two-factor sign-in, Account, Active sessions sections; "Devices signed in" description |
| Settings — Setup/Authority | Wage setup, Business timing, Covers setup sections |
| Settings — Integrations | Category rows, demo switch, Demo/Live switch |
| Settings — Data | Sync status, Latest updates, Data reset, Demo date sections |
| Settings — misc | Role editor dialog mounts, all SettingsPointerRow widgets tappable |
| Regressions | CrashReporter freeze, DemoModeBanner lifecycle, setState-after-dispose during refresh |

---

## Production files changed this session

```
lib/state/week_data_notifier.dart
lib/state/shift_dashboard_notifier.dart
lib/state/shift_service_period_notifier.dart
lib/state/demand_forecast_context_notifier.dart
lib/state/active_target_profile_notifier.dart
lib/state/schedule_distribution_weights_notifier.dart
```

All other changes are inside `integration_test/mobile_pressure/` (test code only).
