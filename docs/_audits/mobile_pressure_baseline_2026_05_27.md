# Mobile Pressure Suite Baseline — 2026-05-27

First captured baseline run of `integration_test/mobile_pressure/` on
emulator. Scope of this baseline is **lanes A and B only**; lanes C-H
are explicit follow-up work (see "Follow-up" below).

## Environment

- Host: Windows; `flutter` at `/c/src/flutter/bin/flutter`.
- Device: `emulator-5554` (Android emulator).
- Flavor: `forgeflow`.
- Mandatory dart-define: `kDemoMode=true` (per CLAUDE.md mobile-pressure
  rules; omitting it throws `StateError` at startup).
- Worktree: `.claude/worktrees/lane-c-self/`, branch
  `claude/mobile-pressure-baseline-v1`.
- Command form (canonical per CLAUDE.md):

  ```
  flutter test integration_test/mobile_pressure/lane_X_runner.dart \
    --device-id emulator-5554 \
    --flavor forgeflow \
    --dart-define=kDemoMode=true \
    --timeout 120s
  ```

## Result summary

| Lane | Tests | Pass | Fail | Skip | Verdict | Log |
|------|-------|------|------|------|---------|-----|
| A    | 8     | 7    | 1    | 0    | 1 real product drift | `pressure_output/lane_a_run_2026_05_27.log` |
| B    | 8     | 8    | 0    | 0    | Clean | `pressure_output/lane_b_run_2026_05_27.log` |
| **Total** | **16** | **15** | **1** | **0** | **93.75% pass** | — |

## Lane A — 7 pass / 1 fail

Pass:
- Auth-02: login form has all required keys; LoginScreen absent after demo login
- Shell-01: all 4 bottom-nav tabs mount their expected screen widget
- Shell-02: settings entry and exit via app-bar icon
- Shell-03: notifications entry via app-bar icon and back navigation
- Shell-04: 15 rapid tab switches do not crash or freeze
- Reg-01: CrashReporter freeze regression — bottom-nav taps responsive in demo mode
- Reg-02: DemoModeBanner persists across all tab switches and settings entry/exit

Fail:
- **Auth-01: cold boot shows login screen, demo tap mounts AppShell on Shift tab**
  - Error: `Expected: <4>  Actual: <5>` — "Expected 4 bottom nav items (Shift, Variance, Plan, Benchmark)."
  - Location: `integration_test/mobile_pressure/auth/scenario_auth_01_demo_login.dart:74`
  - Root cause: real product drift. The mobile bottom-nav grew from 4 tabs to 5 since the test was written; the assertion was not updated. (Shell-01 passes because it counts "all 4 expected" against a hardcoded list rather than reading actual count.)
  - Fix: update Auth-01 assertion (and Shell-01 if it should pick up the 5th tab) to match the current 5-tab nav, or document the 5th tab as intended and pin the new expected count.

## Lane B — 8 pass / 0 fail

All clean:
- shift-01 — section headers or empty state render; no overflow; no stuck spinner
- shift-02 — period selector pills are tappable; scroll works; no crash
- shift-03 — dashboard is in a valid state; no ErrorWidget; no stuck spinner
- variance-01 — three tabs mount and each renders content; no overflow
- variance-02 — This Week tab renders metric content and survives scroll + taps
- variance-03 — History tab mounts and renders content; scroll works; no overflow
- variance-04 — Learn tab mounts and content area is non-empty; no overflow
- variance-05 — This Week tab data integrity: numbers present, no NaN/null text, no error

## Follow-up — lanes C through H

Out of scope for this baseline. Each follow-up should be its own
agent-led slice using the same canonical command form, one lane per
run, logging to `pressure_output/lane_X_run_<date>.log`. Suggested
order matches `integration_test/mobile_pressure/`: C (plan), D (deep_nav),
E (forms), F (data_correctness), G (settings + benchmark), H (edge_cases).

## Findings worth fixing now

- **Real:** Auth-01 vs Shell-01 bottom-nav count inconsistency. Pick one
  expected value and pin both tests to it.
- **Not blocking, but noticed:** `flutter pub get` warns 64 packages
  have newer versions incompatible with current constraints. Out of
  scope for this baseline; flag for a separate "deps audit" slice.
