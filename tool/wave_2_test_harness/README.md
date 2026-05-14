# Wave 2 testing-prep — single-command harness runner

Single entry point that runs every Wave 2 integration test harness
end-to-end. Lets the operator verify the wave with one invocation.

## Purpose

Wave 2 shipped four integration test harnesses, each with its own
entry point, env-gating, and demo-mode posture. Running them by
hand requires four separate commands plus per-harness env review.
This runner collapses that into a single invocation, captures
per-harness pass / skip / fail, and prints a summary table.

It does NOT change harness behavior. Each harness still owns its
own env-gated-skip rules and demo-mode posture. The runner is pure
orchestration.

## Run

```powershell
pwsh tool/wave_2_test_harness/run_all.ps1
```

Expected outcome on a dev machine without Mailosaur or Firebase
Test Lab env: the Phase 4 emulator + in-app notifications harnesses
run; the other two skip with a clear message; exit 0 unless a
required harness reports FAIL.

### Optional parameters

| Flag | Effect |
|---|---|
| `-FlutterCommand <name>` | Override the Flutter binary (default `flutter`). |
| `-DartCommand <name>` | Override the Dart binary (default `dart`). |
| `-OutputDir <path>` | Override where per-harness logs / reports land (default `test/wave_2_test_harness/<utc-ts>`). |
| `-SkipPhase4` | Force-skip the Phase 4 emulator harness. |
| `-SkipInAppNotifications` | Force-skip the in-app notifications harness. |
| `-SkipEmailSoak` | Force-skip the email soak harness regardless of env. |
| `-SkipFirebaseTestLab` | Force-skip the Firebase Test Lab harness regardless of env. |

## The four harnesses

### 1. Phase 4 emulator click-path (REQUIRED, always runs)

- Path: `integration_test/phase_4_emulator/`
- README: `integration_test/phase_4_emulator/README.md`
- Command the runner invokes: `flutter test integration_test/phase_4_emulator/ --flavor forgeflow --dart-define=kDemoMode=true`
- Prereqs: Flutter SDK on PATH, a connected Android emulator OR iOS simulator (verify with `flutter devices`).
- HP #2 demo parity: the harness boots `main_forgeflow.main()` with `--dart-define=kDemoMode=true`; the SQLite seed writes the SAME tables production reads from. No reader-side `kDemoMode` branch.

### 2. In-app notifications (Patrol) (REQUIRED, always runs)

- Path: `integration_test/in_app_notifications/`
- README: `integration_test/in_app_notifications/README.md`
- Command the runner invokes: `flutter test integration_test/in_app_notifications/ --flavor forgeflow --dart-define=kDemoMode=true`
- Prereqs: Flutter SDK on PATH, a connected emulator / device. The in-tree run uses stock `WidgetTester`; a host-side Patrol-native run (lockscreen-shade gestures, push delivery) requires `patrol_cli` installed separately.
- Per-path soak orchestrator (not part of this runner): `tool/in_app_notification_soak/in_app_notification_soak_orchestrator.dart`.

### 3. Email soak — Mailosaur + SendGrid webhook (OPTIONAL)

- Path: `tool/email_soak/email_soak_orchestrator.dart`
- Command the runner invokes: `dart run tool/email_soak/email_soak_orchestrator.dart --output=<output-dir>/email_soak.jsonl`
- Skipped when `MAILOSAUR_API_KEY` is unset on the host (the harness itself ALSO performs this check; the runner short-circuits before invoking dart).
- Required env to run for real:
  - `MAILOSAUR_API_KEY` — Mailosaur REST bearer token.
  - `MAILOSAUR_SERVER_ID` — Mailosaur server identifier.
  - Optional: `PROXY_URL` (must contain `preview.` / `staging.` / `localhost` / `127.0.0.1`), `PROXY_ADMIN_TOKEN`, `EMAIL_SOAK_PROBE_TOKEN`. See the orchestrator file header for the full list.

### 4. Firebase Test Lab — push round-trip (OPTIONAL)

- Path: `tool/firebase_test_lab/firebase_test_lab_orchestrator.dart`
- README: `tool/firebase_test_lab/README.md`
- Command the runner invokes: `dart run tool/firebase_test_lab/firebase_test_lab_orchestrator.dart --output-dir=<output-dir> --run-id=wave2-prep-<utc-ts>`
- Skipped when `FIREBASE_TEST_LAB_PROJECT_ID` is unset (the runner short-circuits; the harness itself ALSO checks and would skip both lanes if invoked anyway).
- To run for real, follow the build steps in `tool/firebase_test_lab/README.md` first (Android APK + test APK, iOS IPA + XCTest .zip) and pass the artifact paths as additional flags through the orchestrator.

## How to read the summary table

```
============================================================
Wave 2 Test Harness Summary
============================================================
[PASS] Phase 4 emulator click-path        (required) exit 0
[PASS] In-app notifications (Patrol)      (required) exit 0
[SKIP] Email soak (Mailosaur+SendGrid)    (optional) SKIPPED -- MAILOSAUR_API_KEY not set
[SKIP] Firebase Test Lab (push)           (optional) SKIPPED -- FIREBASE_TEST_LAB_PROJECT_ID not set
------------------------------------------------------------
Result: 2/2 required harnesses passed; 2 skipped.
Output  : test/wave_2_test_harness/<utc-ts>
============================================================
```

Rules:

- `[PASS]` means the harness exited 0.
- `[SKIP]` means the runner did NOT invoke the harness — env not set, or the operator passed `-Skip*`. The harness was not run at all.
- `[FAIL]` means the harness ran and exited non-zero. The runner records the exit code and log path. Surface in the PR body.
- Exit code: 0 if all REQUIRED harnesses passed; 1 if any required harness reported FAIL. Skipped harnesses never fail the runner.

## Running an individual harness

If you want to bypass the runner and invoke a single harness directly:

- Phase 4 emulator: see `integration_test/phase_4_emulator/README.md`.
- In-app notifications: see `integration_test/in_app_notifications/README.md`.
- Email soak: see the file header of `tool/email_soak/email_soak_orchestrator.dart`.
- Firebase Test Lab: see `tool/firebase_test_lab/README.md`.

## Demo-mode parity (HP #2)

The Phase 4 emulator + in-app notifications harnesses are invoked
with `--dart-define=kDemoMode=true`. They drive the same SQLite
tables (`shift_records`, `week_records`, `restaurant_locations`,
`target_cycles`, `import_runs`, ...) that production reads from.
There is no demo-only reader branch and no `demo_*` table.

The email + Firebase harnesses are transport-layer soak harnesses,
not UX walkthroughs; they do not need a `kDemoMode` flip and their
demo / prod parity is enforced inside their own binaries.

## What this runner does NOT do

- It does NOT update trackers, ledgers, or audit docs. Closeout
  for the wave is a parallel slice owned by the orchestrator.
- It does NOT raise `kAdvisorProxyMaxLines`. The proxy is untouched.
- It does NOT widen permission gates.
- It does NOT add a parallel demo-only reader path (HP #2).
- It does NOT add a `demo_*` SQLite or Postgres table.
