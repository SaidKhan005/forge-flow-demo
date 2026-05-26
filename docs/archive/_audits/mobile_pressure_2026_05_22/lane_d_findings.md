# Lane D Findings — Settings + Demo Live Switch + Role Editor

Scope: SettingsScreen (Account tab: account section, active sessions, MFA section;
Setup/Authority tab: wage authority, timing authority, covers setup, integrations;
Data tab: sync status, data freshness, data reset, demo date, advisor corpus, advisor model),
SettingsDemoLiveSwitch, SettingsRoleEditor, all pointer rows and dialogs.

Status: **CLOSED — 9 / 9 passed**  
Run: 2026-05-22 · Device: emulator-5554 · Build time: ~40 s

---

## Test results

| # | Test name | Result | Time |
|---|-----------|--------|------|
| 1 | Scenario 01 — Account tab renders all sections without crash | ✅ | 10 s |
| 2 | Scenario 02 — Setup/Authority tab renders wage, timing, and covers without crash | ✅ | 13 s |
| 3 | Scenario 03 — Data tab renders sync, freshness, and demo carve-out sections | ✅ | 16 s |
| 4 | Scenario 04 — Integrations tab renders category rows and demo switch | ✅ | 18 s |
| 5 | Scenario 05 — Settings tabs reachable and role editor dialog mounts without crash | ✅ | 22 s |
| 6 | Scenario 06 — Demo/Live switch renders in Integrations tab without crash | ✅ | 25 s |
| 7 | Scenario 07 — MFA section renders on Account tab without crash | ✅ | 27 s |
| 8 | Scenario 08 — all SettingsPointerRow widgets tappable without crash | ✅ | 31 s |
| 9 | Regression 03 — no setState-after-dispose crash when navigating away during refresh | ✅ | 39 s |

---

## Findings

### Test infra fixes applied to get Lane D green

| # | Fix | Root cause |
|---|-----|------------|
| 1 | Added scroll (`tester.drag` 4000 dp down) + `skipOffstage: false` before all section-header assertions in settings-01/02/03 | `_settingsSection()` uses `SliverMainAxisGroup`; sections entirely below viewport are not built by Flutter's lazy renderer — default `find.text()` with `skipOffstage: true` misses them |
| 2 | Added `import 'package:flutter/material.dart'` to `scenario_settings_01_account_tab.dart` | `CustomScrollView` is a Material widget; file only had `flutter_test` import — Gradle compile failure |

### Production fixes that enabled reg-03 to pass

The `setState-after-dispose` regression test (reg-03) exercises the same dispose-race pattern fixed in Lane B. The same 6 notifiers patched for Lane B cover the regression path exercised here.

No new production bugs found in Settings scope.
