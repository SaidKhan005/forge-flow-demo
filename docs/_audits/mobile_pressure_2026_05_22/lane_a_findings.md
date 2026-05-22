# Lane A Findings — Shell / Cold-start / Nav / Notifications

Scope: AppShell, bottom-nav (all 4 tabs), app-bar icons, login screen demo button,
demo mode banner, notifications screen, push route intent handling, force-update modal,
baseline integration_test/phase_4_emulator/ re-run.

Status: **CLOSED — 8 / 8 passed**  
Run: 2026-05-22 · Device: emulator-5554 · Build time: ~35 s

---

## Test results

| # | Test name | Result | Time |
|---|-----------|--------|------|
| 1 | Auth-01: cold boot shows login screen, demo tap mounts AppShell on Shift tab | ✅ | 8 s |
| 2 | Auth-02: login form has all required keys; LoginScreen absent after demo login | ✅ | 10 s |
| 3 | Shell-01: all 4 bottom-nav tabs mount their expected screen widget | ✅ | 13 s |
| 4 | Shell-02: settings entry and exit via app-bar icon | ✅ | 16 s |
| 5 | Shell-03: notifications entry via app-bar icon and back navigation | ✅ | 18 s |
| 6 | Shell-04: 15 rapid tab switches do not crash or freeze | ✅ | 21 s |
| 7 | Reg-01: CrashReporter freeze regression — bottom-nav taps responsive in demo mode | ✅ | 23 s |
| 8 | Reg-02: DemoModeBanner persists across all tab switches and settings entry/exit | ✅ | 27 s |

---

## Findings

| # | Surface | Interaction | Expected | Actual | Severity | Notes |
|---|---------|-------------|----------|--------|----------|-------|
| 1 | `SettingsScreen` / `NotificationsScreen` back navigation | `tester.pageBack()` | Back to AppShell | Flutter `pageBack()` looks for `BackButton` widget — both screens use `Icons.close` as leading icon instead | **Test infra fixed** | Added `navigateBack()` helper to `_harness.dart`; replaces `pageBack()` in shell-02, shell-03, reg-02 |
| 2 | `DemoModeBanner` while Settings is open | `find.byType(DemoModeBanner)` | Finds banner | Banner is in offstage route when Settings is pushed; default `skipOffstage: true` misses it | **Test infra fixed** | Changed to `skipOffstage: false` in reg-02 |

No production bugs found in Lane A scope.
