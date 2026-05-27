# Mobile Pressure Suite Baseline — 2026-05-27

Comprehensive baseline of `integration_test/mobile_pressure/` covering
all 8 lanes (A through H). Supersedes the partial A+B baseline merged
in PR #1439 earlier the same day.

## Environment

- Host: Windows; `flutter` at `/c/src/flutter/bin/flutter`.
- Device: `emulator-5554` (Android emulator).
- Flavor: `forgeflow`.
- Mandatory dart-define: `kDemoMode=true` (per CLAUDE.md mobile-pressure
  rules; omitting it throws `StateError` at startup).
- Worktree: `.claude/worktrees/mobile-fix-baseline/`, branch
  `claude/mobile-pressure-nav-fix-and-cth`.
- Master baseline: `4de40f16`.
- Command form (canonical per CLAUDE.md):

  ```
  flutter test integration_test/mobile_pressure/lane_X_runner.dart \
    --device-id emulator-5554 \
    --flavor forgeflow \
    --dart-define=kDemoMode=true \
    --timeout 120s
  ```

## Result summary — all 8 lanes

| Lane | Tests | Pass | Fail | Skip | Verdict | Log |
|------|-------|------|------|------|---------|-----|
| A    | 8     | 8    | 0    | 0    | Clean (Auth-01 + Shell-01 fixed; see "Fix landed alongside this baseline") | `pressure_output/lane_a_run_2026_05_27_fixed.log` |
| B    | 8     | 8    | 0    | 0    | Clean | `pressure_output/lane_b_run_2026_05_27.log` |
| C    | 7     | 7    | 0    | 0    | Clean (one non-fatal hit-test warning on bench_04, did not fail) | `pressure_output/lane_c_run_2026_05_27.log` |
| D    | 9     | 9    | 0    | 0    | Clean | `pressure_output/lane_d_run_2026_05_27.log` |
| E    | 5     | 5    | 0    | 0    | Clean | `pressure_output/lane_e_run_2026_05_27.log` |
| F    | 5     | 5    | 0    | 0    | Clean | `pressure_output/lane_f_run_2026_05_27.log` |
| G    | 5     | 5    | 0    | 0    | Clean | `pressure_output/lane_g_run_2026_05_27.log` |
| H    | 5     | 5    | 0    | 0    | Clean | `pressure_output/lane_h_run_2026_05_27.log` |
| **Total** | **52** | **52** | **0** | **0** | **100% pass** | — |

Log files retained under `pressure_output/` (gitignored per repo policy
PR #1432); quoted excerpts inline below for any non-trivial signal.

## Fix landed alongside this baseline

The earlier A+B baseline (PR #1439) captured a real product-test
divergence: Auth-01 expected 4 bottom-nav items but the product had
5 since `abc4da72` ("Add mobile advisor chat screen — Slice D2 mobile").

This PR updates Auth-01 and Shell-01 to match the current 5-tab
bottom nav (Shift, Variance, Plan, Benchmark, **Advisor**). Auth-01
now asserts `equals(5)` with a reason string naming all five tabs.
Shell-01 adds the missing tab-4 assertion (`AdvisorMobileChatScreen`)
so future advisor regressions are caught at the shell level rather
than only at the count check.

Verified on emulator: 8/8 pass on Lane A after the fix.

## Lane-by-lane scenarios

### Lane A (auth + shell + regression) — 8 pass

- Auth-01: cold boot shows login screen, demo tap mounts AppShell on Shift tab
- Auth-02: login form has all required keys; LoginScreen absent after demo login
- Shell-01: **all 5** bottom-nav tabs mount their expected screen widget
- Shell-02: settings entry and exit via app-bar icon
- Shell-03: notifications entry via app-bar icon and back navigation
- Shell-04: 15 rapid tab switches do not crash or freeze
- Reg-01: CrashReporter freeze regression — bottom-nav taps responsive in demo mode
- Reg-02: DemoModeBanner persists across all tab switches and settings entry/exit

### Lane B (shift + variance content) — 8 pass

- shift-01..03 — section headers / period selector / dashboard valid state
- variance-01..05 — three tabs, This Week, History, Learn, data integrity

### Lane C (plan + benchmark + drill-ins) — 7 pass

- Plan tab: ScheduleBuilder mounts; day-row expand/collapse OK
- Benchmark tab: BaselineTracker mounts; manager CTA pushes BaselineManagerScreen
- BaselineManagerScreen: sub-components mount; interactive elements respond; CANCEL pops back cleanly

**Non-fatal warning** on bench_04: a `tap()` on a `GestureDetector` for `cal_2026-03-28`
derived an offset (299.4, 75.9) that did not hit-test the target — Flutter logged
"the widget is actually off-screen, or another widget is obscuring it". Test still
passed. Either the calendar cell is partially obscured by the date-grid header at
the row boundary, or the test would benefit from `warnIfMissed: false` plus an
explicit `ensureVisible` scroll-into-view step before the tap. Worth a small
follow-up; not blocking.

### Lane D (settings tabs) — 9 pass

- scenario 01..08 — Account / Setup-Authority / Data / Integrations / Settings-tabs / Demo-Live switch / MFA / SettingsPointerRow taps
- regression 03 — no setState-after-dispose crash when navigating away during refresh

### Lane E (data correctness) — 5 pass

- data-01..05 — ShiftDashboard MetricPills / VarianceReport tabs / ScheduleBuilder day rows / BaselineTracker CPLH range / Active Sessions (3 demo rows)

### Lane F (forms + inputs) — 5 pass

- form-01..05 — role editor (display name + permission toggles), Demo/Live switch tap, SettingsPointerRow taps, Covers numeric input

### Lane G (deep navigation) — 5 pass

- deep-01..05 — Settings 3-cycle open/visit/close, Benchmark drill→CANCEL, Variance sub-tabs round-trip, Notifications scroll+close, rapid tab switches during async loads

### Lane H (edge cases) — 5 pass

- edge-01..05 — 150-char display name, 5 rapid Settings cycles, 3 rapid pull-to-refresh, Settings tap during tab transition, Plan tab re-entry after Settings interruption

## Findings worth fixing now

- **Already fixed in this PR:** Auth-01 + Shell-01 nav-count drift.
- **Small follow-up:** Lane C bench_04 hit-test warning (non-fatal). Either pass
  `warnIfMissed: false` or pre-scroll the calendar cell into view before the tap.
- **Not blocking, but noticed:** `flutter pub get` warns 64 packages have newer
  versions incompatible with current constraints. Out of scope for this baseline;
  flag for a separate "deps audit" slice.

## Reproduction

To re-run any lane:

```
cd <worktree>
flutter test integration_test/mobile_pressure/lane_X_runner.dart \
  --device-id <your-emulator> \
  --flavor forgeflow \
  --dart-define=kDemoMode=true \
  --timeout 120s
```

Run lanes one at a time; never parallel (CLAUDE.md mobile-pressure rule).
If a lane times out on first run (APK install race), re-run once before
diagnosing.
