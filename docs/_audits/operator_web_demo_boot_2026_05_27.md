# Operator Web Demo Boot Regression — Triage 2026-05-27

## TL;DR (plain English)

The Operator Web Console demo build (the one used by `operator_web_qa_runbook.md`)
now boots to a polite "We couldn't reach Forge & Flow" error screen instead
of the real console. The runner reports `PASSED 16/78`.

The cause is a brand-new runtime guard added on 2026-05-26 in commit
`ff416729` ("fix: close full system audit gaps"). That guard was meant to
fail-close a *deployed* `--release` build that accidentally has the demo flag
turned on. But the runbook builds with `--profile`, which also has
`kDebugMode == false`, so the guard fires in our local QA flow too. The
result is the init-failed screen, every time.

The fix is a small carve-out so the guard only fires on `--release` builds,
or — equivalently — only blocks when the build is **also** not coming from
a local-dev / profile context.

## Reproduction

From the worktree at `C:\forge-flow-demo\.claude\worktrees\agent-a0b35d820f89126e4`:

```
& 'C:\src\flutter\bin\flutter.bat' build web --profile `
    -t lib/main_operator_web.dart `
    --dart-define=OPERATOR_WEB_DEMO_AUTH=true `
    --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-location-completed
```

Build succeeds (`Built build\web` in ~38 s). No analyzer / compile errors.

Serve via the `operator-web-static` launch config (dhttpd port 8185) and
navigate to `http://localhost:8185/`. After service-worker cache flush
and reload:

- `document.title` is `'Forge & Flow'` (not `'Forge & Flow - Operator Web Console'`)
- `document.querySelectorAll('flt-semantics').length` is 0
- Polyfill is active and Flutter painted (`canvasCount: 1`, `visualViewport: 1440x900`, `hasFocus: true`)
- Console contains the verbatim string:
  > `Bad state: Operator Web demo auth is blocked in a non-debug build. OPERATOR_WEB_DEMO_AUTH was set, but demo auth bypasses Firebase and must never ship on a public endpoint. Drop the demo flag and ship live Firebase auth.`
- Stack trace anchors at `main0` -> `main_closure0.call$0`, confirming the throw
  happens inside operator-web's `main()`.

The page title `'Forge & Flow'` is the literal `MaterialApp.title` set by
`OperatorWebInitFailedApp` in `lib/operator_web/widgets/init_failed_app.dart:42`.
That is what the operator sees.

## Root cause

Commit `ff416729` (PR closing the "full system audit gaps") added a new
runtime guard to `lib/main_operator_web.dart`:

- `kOperatorWebDemoAuthBlockedMessage` — the fail-closed copy. Defined at
  `lib/main_operator_web.dart:98-102`.
- `operatorWebDemoAuthBlockedInRelease({ required bool isDebugMode, required bool operatorWebDemoAuth })`
  — pure decision. Defined at `lib/main_operator_web.dart:106-112`. Returns
  `true` when `isDebugMode == false && operatorWebDemoAuth == true`.
- A new early-return block at `lib/main_operator_web.dart:163-178` that
  reports the error via `FlutterError.reportError` and runs
  `OperatorWebInitFailedApp`.

The intent is correct: prevent a `--release` build with `OPERATOR_WEB_DEMO_AUTH=true`
from being deployed to a public Cloud Run endpoint where it would bypass
Firebase auth. The previous `assert()`-only guard at lines 153-161 is
stripped from release artifacts, so prior to this commit a misconfigured
release deploy could silently ship demo auth. That hole is real and the
guard correctly closes it.

But the guard's predicate is `!kDebugMode`, and **`--profile` builds also
have `kDebugMode == false`**. The runbook builds with `--profile` precisely
because the DDC debug client blocks any browser other than the one Flutter
launched (see `runbooks/operator_web_qa_runbook.md` lines 12-14). So every
QA build now trips the guard.

Authority order check:
- HP #2 (Demo Mode persists post-launch) — preserved by the intent of the
  guard but contradicted by the implementation: the runbook-canonical QA
  build cannot reach the demo flow at all.
- HP #7 (F&F holds all provider keys server-side, no BYO-key) — the
  guard's *intent* protects this; we want to keep that.
- The fix below preserves both.

## Minimal proposed fix

Change the runtime guard to fire only when ALL of:
- not `kDebugMode`
- not `kProfileMode`
- `OPERATOR_WEB_DEMO_AUTH == true`

In Dart, `package:flutter/foundation.dart` already exports both `kDebugMode`
and `kProfileMode` as `const bool`. Replace `operatorWebDemoAuthBlockedInRelease`
with a release-only predicate. Concretely:

```dart
@visibleForTesting
bool operatorWebDemoAuthBlockedInRelease({
  required bool isDebugMode,
  required bool isProfileMode,
  required bool operatorWebDemoAuth,
}) {
  if (isDebugMode) return false;
  if (isProfileMode) return false;
  return operatorWebDemoAuth;
}
```

…and at the call site (`lib/main_operator_web.dart:163-166`):

```dart
if (operatorWebDemoAuthBlockedInRelease(
  isDebugMode: kDebugMode,
  isProfileMode: kProfileMode,
  operatorWebDemoAuth: _kOperatorWebDemoAuth,
)) {
```

This keeps the production fail-closed guarantee — a `flutter build web`
(release) with `OPERATOR_WEB_DEMO_AUTH=true` still lands on the init-failed
screen — while unblocking the runbook's `--profile` QA flow.

### Why this is the right shape (not a wider carve-out)

The Cloud Run deploy script (`scripts/deploy_operator_web.ps1`) defaults to
**release** builds; the `-DemoMode` switch only flips the build in demo
contexts. So gating on "not release" still blocks the failure mode the
guard was designed to catch (an operator forgetting to drop
`OPERATOR_WEB_DEMO_AUTH` on a release deploy). `--profile` is never the
deploy artifact — it is exclusively a local-QA build. Letting demo auth
flow through `--profile` parallels the long-standing posture of the
`assert()` debug-only guard, which has the same effective scope.

The B1.A5 doc comment on the `assert()` already says "Debug-time assertion
for local smoke, kept as a belt-and-suspenders signal" — pairing it with a
release-only runtime guard matches that stated intent.

## Tests to add alongside the fix

In `test/main_operator_web_demo_auth_guard_test.dart` (or wherever
`operatorWebDemoAuthBlockedInRelease` is currently covered):

| Case | isDebugMode | isProfileMode | operatorWebDemoAuth | Expected |
|---|---|---|---|---|
| Debug + demo on | true | false | true | NOT blocked |
| Profile + demo on (the runbook case) | false | true | true | NOT blocked |
| Release + demo on (the deploy hazard) | false | false | true | BLOCKED |
| Release + demo off | false | false | false | NOT blocked |
| Profile + demo off | false | true | false | NOT blocked |

## Scope this audit explicitly did NOT touch

- `web/_qa_runner.js` baseline drift (78 -> 42 in the runbook table; counts
  vary across iterations of the runner). Cannot be re-baselined until step 1
  is fixed and the bundle boots into the real console.
- The runbook itself. Once the fix lands, the build command at lines 38-42
  still works as written.
- The new `auditor_compliance` admitted role added in the same commit
  (`lib/operator_web/auth/operator_web_auth_source.dart:348`). Looks
  internally consistent; not exercised by the current regression.

## Evidence trail

- Repro build artifact: `C:\forge-flow-demo\.claude\worktrees\agent-a0b35d820f89126e4\build\web\main.dart.js` (12,124,934 bytes, built 2026-05-27 ~08:42 local).
- Console payload captured live via Claude Preview `preview_console_logs` on `http://localhost:8185/` after SW + cache flush + cache-bust reload.
- Probe result snapshot:
  ```json
  {"title":"Forge & Flow","semantics":0,"glassFound":true,"canvasCount":1,
   "visibilityState":"visible","hasFocus":true,
   "visualViewport":{"w":1440,"h":900},"bodyTextSnippet":""}
  ```
- Verbatim console error: see Reproduction section above.
- Code-side culprit lines: `lib/main_operator_web.dart:106-112` (predicate) +
  `:163-178` (call site).
- Introducing commit: `ff416729` ("fix: close full system audit gaps",
  2026-05-26 23:50 -0230). Specifically the `+18 / 0` block in
  `lib/main_operator_web.dart` containing
  `kOperatorWebDemoAuthBlockedMessage`,
  `operatorWebDemoAuthBlockedInRelease`, and the early-return guard.

## Recommended next steps

1. Apply the predicate fix above (1-file, ~3-line code delta + test additions).
2. Re-build with the runbook command and confirm `document.title == 'Forge & Flow - Operator Web Console'` + semantics count > 50.
3. Re-run `web/_qa_runner.js` and re-baseline the runbook's expected passed-count if it has drifted for unrelated reasons.
4. (Independent follow-up — not part of this fix) Audit any other entrypoints whose `_resolveAuthSource()` style of bootstrap might have an analogous "blocked in release" guard with the same profile-mode gap.
