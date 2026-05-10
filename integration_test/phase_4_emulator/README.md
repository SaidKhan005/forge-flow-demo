# Phase 4 — Emulator click-path integration tests

Pressure-preview Phase 4 (`pressure.preview.v1` sprint) is the operator-
facing UX angle: when the SQLite seed driven by `MockReplayDataSourceProvider`
shapes the same canonical facts Phase 1 vendor corpora describe, do the
mobile screens render without breaking?

This folder is the demo-mode walkthrough. It runs against a connected
Android emulator (or iOS simulator) using the `flutter integration_test`
driver. CI is billing-blocked at the time of authoring; this is
operator-driven, anytime.

## Prerequisites

- Flutter SDK on PATH (`flutter doctor` clean).
- A connected Android emulator OR iOS simulator. Verify with
  `flutter devices`.
- The demo flavor is `forgeflow` (per
  `android/app/build.gradle.kts` `productFlavors`).
- `--dart-define=kDemoMode=true` flag — the suite refuses to run
  against a non-demo binary (see `_harness.dart` `kDemoMode` guard).
  This is the writer-side switch from CLAUDE.md → Demo Mode.

## Run

```bash
flutter pub get
flutter test integration_test/phase_4_emulator/click_path_runner.dart \
  --flavor forgeflow \
  --dart-define=kDemoMode=true
```

To run a single scenario:

```bash
flutter test integration_test/phase_4_emulator/scenario_03_weekly_plan_review.dart \
  --flavor forgeflow \
  --dart-define=kDemoMode=true
```

To run every scenario file in the folder:

```bash
flutter test integration_test/phase_4_emulator/ \
  --flavor forgeflow \
  --dart-define=kDemoMode=true
```

## What to look for

Each scenario emits one `testWidgets(...)` line. The Flutter test
runner prints `+0 -0` style progress; on success you'll see
`All tests passed!`. On failure the assertion `reason:` strings name
the surface that broke (e.g. `"Plan tab (ScheduleBuilder) did not
mount when the bottom-nav index 2 was selected"`).

`RenderFlex` overflow exceptions are captured via a global
`FlutterError.onError` tap (`_harness.dart` → `FlutterErrorTap`) and
reported at scenario close. Any layout overflow on a real device size
is a fail.

## Scenarios

| # | File | Path |
|---|---|---|
| 1 | `scenario_01_dashboard_load.dart` | Cold boot -> AppShell -> Shift dashboard renders. |
| 2 | `scenario_02_settings_traversal.dart` | Dashboard -> Settings -> Account / Setup / Data tabs traverse. Asserts the two `kDemoMode` carve-out sections render. |
| 3 | `scenario_03_weekly_plan_review.dart` | Dashboard -> Plan tab -> Benchmark tab -> back to Shift. |
| 4 | `scenario_04_variance_review.dart` | Dashboard -> Variance tab renders demo facts (substituted from prompt's hierarchy-scope scenario). |
| 5 | `scenario_05_shift_detail.dart` | Whole-day dashboard sticky-section headers mount. |

## SCENARIO GAP markers

Each scenario file documents any deviation from the original prompt
framing in a `// SCENARIO GAP:` block at the top:

- **Scenario 1**: the prompt's "tap 'Use demo operator' -> login -> dashboard"
  flow is gated to `FORGE_FLOW_USE_FIREBASE_AUTH=true` (offline emulator
  can't reach Firebase Auth, which violates the "no network" rule). The
  default demo boot path skips AuthGate and lands on AppShell directly.
  The "Use demo operator" affordance is covered as a widget-level
  `find.byKey(login_demo_operator_button)` assertion in
  `test/widget_test.dart`.
- **Scenario 2**: the prompt named 10 sub-sections; mobile asserts the
  surfaces that DO exist post-W3.A (Account, Active sessions, Setup,
  Data + the two demo carve-outs). Team / Permissions / MFA-recovery /
  FF Support primary surfaces moved to Operator Web per W3.A.
- **Scenario 3**: "switch week -> review locked snapshot" lives in
  Operator Web week-detail; mobile Benchmark surface is BaselineTracker,
  which is what we assert.
- **Scenario 4**: the hierarchy-scoped UX trio
  (Selected scope / Inherited from / Effective value) is rendered
  exclusively in `lib/operator_web/screens/` and `lib/admin/screens/`
  per HP #11 + W3.A — zero matches in `lib/screens/`. Substituted with
  the Variance tab render against demo facts.
- **Scenario 5**: there is no separate "shift detail" screen on mobile
  — ShiftDashboard IS the whole-day authoritative view per CLAUDE.md
  Architecture Guardrails. We assert the three sticky-section headers
  (`SHIFT OUTPUTS` / `SHIFT INPUTS` / `FOH PRODUCTIVITY`) or a
  recognized empty state.

## Adding a new scenario

1. Copy any `scenario_NN_*.dart` file as a template.
2. Update the `SCENARIO GAP` block (or remove it if the scenario maps
   1:1 onto an existing mobile path).
3. Use the helpers in `_harness.dart`:
   - `bootstrapPhase4Binding()` at the top of `main()`.
   - `await launchDemoApp(tester)` then `await expectAppShellMounted(tester)`
     to bring the app to a stable starting state.
   - `tapBottomNavTab(tester, index)` to switch tabs.
   - `FlutterErrorTap.install()` + `tap.overflowErrors` to catch
     RenderFlex / layout exceptions accumulated during the scenario.
4. Append the new scenario import + `main()` call to
   `click_path_runner.dart`.
5. Add a row to the table above.

## Architectural constraints honored

Per CLAUDE.md → Demo Mode:

- HP #2: `kDemoMode` is a writer-side switch. The integration test
  boots through `lib/main_forgeflow.dart` `main()` with
  `--dart-define=kDemoMode=true`; the SQLite seed
  (`_seedDemoDataFromReplay`) writes through the SAME tables and
  reader path production uses.
- No new reader-side branching on `kDemoMode` lands in this folder.
- No new SQLite or Postgres tables named `demo_*`.
- No network / proxy / Postgres dependency at runtime — the demo seed
  is fully local SQLite.
- Demo-flavor builds only (the harness fails fast on a
  non-`kDemoMode=true` binary).

## Findings

Per-run findings are written into the consolidated pressure-preview
findings doc at:

`docs/_execution/2026-05-08_pressure_preview_findings.md` -> Section 8
"Emulator E2E Notes (Phase 4 — user-driven)".

The operator captures: which screens broke under realistic vendor
data, where labels lied, where loading states never resolved, where
copy/UX needs tightening.
