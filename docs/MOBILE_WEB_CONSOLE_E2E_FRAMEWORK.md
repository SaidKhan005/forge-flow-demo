# Mobile And Web Console E2E Framework

Status: Active
Last updated: 2026-05-03

This framework is the repeatable end-to-end testing guide for the Forge & Flow
mobile operator app and the Flutter Web admin console. It translates the
2026-05-03 live admin, proxy, and phone testing pass into a durable workflow.

Use it when a future prompt mentions live acceptance, Browser Use, mobile
device QA, admin console QA, deployed web verification, service-worker/cache
issues, CORS, auth roles, safe action sweeps, Debug, Observability, Health,
Feature Flags, staging smoke tests, or "test it for real."

## Core Promise

End-to-end testing must prove the real product path.

Do not accept a slice because local tests pass, a screenshot looks plausible,
or source code contains the expected text. Acceptance must connect:

1. updated branch and commit
2. built artifact
3. deployed or installed runtime
4. real browser origin or physical device
5. live proxy/backend route
6. UI contract and safe-action behavior
7. producer/health truth
8. repeatable evidence

If any link is missing, report the missing proof precisely.

## Relationship To Other Docs

Read this framework with:

- `docs/contracts/slice_runtime_acceptance_contract.md`
- `docs/PERFORMANCE_FRAMEWORK.md`
- `runbooks/browser_use_acceptance_harness_runbook.md`
- `runbooks/admin_console_browser_qa_runbook.md`
- the active phase doc for the slice

Performance work asks "is it fast enough and bounded?" This framework asks
"did the real mobile or web product work end to end?"

## Hard Boundaries

Allowed without additional action-time approval:

- navigating pages, tabs, routes, and menus
- opening dialogs without submitting
- changing filters, sort order, search text, or local view state
- triggering read-only refresh actions
- inspecting DOM, console logs, network failures, screenshots, and device logs
- installing a debug/profile APK on an approved connected test device
- restarting the app or hard-refreshing the browser to avoid stale assets

Stop for action-time approval before:

- submitting forms that mutate live state
- changing pricing caps, feature flags, provider credentials, corpus state, or
  operator status
- onboarding, suspending, reactivating, deleting, rebuilding, replaying, or
  rotating anything
- sending credentials, OTPs, passwords, bearer tokens, or provider calls
- applying migrations, changing cloud enforcement, or altering Firebase/Auth
- running aggressive load tests or expensive diagnostics outside the stated cap

Do not put secrets, OTPs, bearer tokens, private emails, or credential material
in committed docs, screenshots, logs, or final reports.

## Browser Use Rule

When the prompt explicitly names Browser Use, the in-app browser is the primary
web test surface.

The tester must prove Browser Use can:

- launch or attach to the in-app browser
- navigate to the target origin
- hard refresh or otherwise defeat stale cache when needed
- inspect visible text or DOM state
- capture screenshots
- click real controls
- observe console or network failures when available

If Browser Use cannot launch, attach, navigate, inspect, screenshot, or click
for real, stop immediately and report the exact failure. Do not replace an
explicit Browser Use requirement with Playwright, shell `open`, static source
inspection, or a claimed visual check unless the operator approves the
fallback.

## Intake Checklist

Every E2E pass starts by answering:

1. What branch, commit, PR, and merge base are under test?
2. Is the worktree clean except for known unrelated files?
3. Which authority docs and runbooks apply?
4. Which admin URL, proxy URL, mobile package, and backend mode are live?
5. Which deployed revisions, image tags, or installed APK builds are expected?
6. Which surfaces are safe to click, and which require action-time approval?
7. Which routes, tabs, dialogs, filters, and refresh actions are reachable?
8. Which metrics are cheap readiness versus expensive diagnostics?
9. What evidence will prove the result: screenshot, DOM text, logs, network
   request, route payload, perf probe, or device screenshot?
10. What issue taxonomy will be used if something fails?

If the answers are unknown, discover them before changing code.

## Issue Taxonomy

Classify every defect before fixing it:

- `browser/plugin`: Browser Use or in-app browser capability failure
- `cache`: stale Flutter web service worker, stale asset, or browser storage
- `CORS`: route works from server but fails from the tested browser origin
- `auth`: missing login, role, grant, token, tenant, or operator permission
- `artifact`: built or deployed image is missing required runtime files/assets
- `migration`: schema, grant, or seed state is missing from the target runtime
- `producer/data`: UI is correct but live producer state is absent, stale, or bad
- `app bug`: product code, layout, state, routing, request, or error handling bug
- `test environment`: device, SDK, network, or local harness setup problem

The classification belongs in the report with the observed evidence and the
fix or carry-forward decision.

## Branch And Worktree Setup

Use a fresh branch or worktree for non-trivial E2E remediation.

```powershell
git fetch origin
git status --short --branch
git switch master
git pull --ff-only origin master
git switch -c codex/<short-e2e-scope>
git rev-parse HEAD
```

If using a separate worktree:

```powershell
git worktree add <path> -b codex/<short-e2e-scope> origin/master
```

Never erase unrelated worktree changes. If unrelated files already exist,
record that they were left untouched.

## Web Console E2E Loop

Use the real admin console, not a mock shell.

1. Confirm target URLs:

   ```text
   admin: <admin-console-url>
   proxy: <proxy-url>
   ```

2. Confirm deployed revisions and traffic when testing Cloud Run:

   ```powershell
   gcloud run services describe forge-flow-admin-console --project <project> --region <region>
   gcloud run services describe forge-flow-staging-proxy --project <project> --region <region>
   ```

3. Open or attach Browser Use to the exact origin.

4. Defeat stale Flutter web cache:

   - use a fresh query string such as `?codexQa=<timestamp>`
   - hard refresh
   - clear site storage if stale behavior persists
   - verify headers or asset text when code appears missing
   - record the exact URL and revision tested

5. Sweep reachable safe surfaces:

   - shell/navigation
   - Operators
   - Pricing
   - Corpus
   - Integrations
   - Debug
   - Observability
   - Health
   - Feature Flags
   - route-specific filters, tabs, refresh actions, dialog openers, and
     non-destructive buttons

6. For every surface, capture:

   - route or click target
   - expected visible signal
   - actual visible signal
   - screenshot or DOM evidence
   - console errors
   - failed requests
   - CORS/auth/role failures
   - stale asset suspicion
   - safe-action boundary

7. If code changes are deployed, retest the live deployed URL after deploy. Do
   not rely on local build proof when the defect was found in staging.

## Debug And Observability Contract

Debug and Observability are high-risk E2E surfaces because they expose runtime
truth and can become accidental load generators.

Verify:

- routes are called from the tested browser origin, not only from curl
- browser-origin requests pass CORS and auth
- filters bound request scope before refresh
- manual refresh is explicit and bounded
- automatic refresh does not stack in-flight calls
- payload fields map to the documented UI states
- empty/unknown producer state remains neutral
- populated bad producer state degrades visibly
- failed producers show recovery copy or runbook direction
- slow or unavailable routes fail safely without blanking the console
- console logs and network failures are captured and classified

Do not "fix" a yellow/red live signal by hiding it in UI. Investigate the
producer, migration, grant, artifact, or data source.

## Health Contract

Health E2E checks must prove truth, not optimism.

Rules:

- `/readyz` stays cheap and automatic.
- Deep `/health` is manual, confirmed, bounded, or explicitly scheduled.
- Unknown metrics stay neutral.
- Populated bad metrics degrade.
- Red/yellow means find the producer.
- UI should explain the state but must not convert backend failure to green.

For every red/yellow health item, record:

- metric name
- producer
- source table/service/job
- current state
- likely class: artifact, migration, producer/data, auth, CORS, or app bug
- runbook or next recovery command

## Mobile E2E Loop

Use a real connected phone when mobile behavior is in scope. A mobile-width web
viewport is useful for quick layout iteration, but it is not enough for mobile
acceptance.

1. Confirm device and package:

   ```powershell
   flutter devices
   adb devices
   adb shell pm list packages com.forgeflow
   ```

2. Build the correct flavor and backend:

   ```powershell
   flutter build apk --debug --flavor forgeflow -t lib/main_forgeflow.dart --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true --dart-define=FORGE_FLOW_PROXY_BASE_URI=<proxy-url>
   ```

   Use profile or release builds for performance measurement. Debug builds are
   acceptable for functional layout verification and fast E2E fixes.

3. Install without wiping the test session when safe:

   ```powershell
   adb install -r -d build\app\outputs\flutter-apk\app-forgeflow-debug.apk
   ```

4. Wake and launch the phone:

   ```powershell
   adb shell input keyevent KEYCODE_WAKEUP
   adb shell wm dismiss-keyguard
   adb shell am force-stop com.forgeflow.app
   adb shell monkey -p com.forgeflow.app -c android.intent.category.LAUNCHER 1
   ```

5. Capture device evidence:

   ```powershell
   adb logcat -c
   adb shell screencap -p /sdcard/forge_flow_smoke.png
   adb pull /sdcard/forge_flow_smoke.png build\reports\forge_flow_smoke.png
   adb logcat -d -t 900
   ```

6. Sweep safe mobile surfaces:

   - shell/navigation
   - Shift
   - Variance
   - Plan
   - Benchmark
   - Settings
   - Account
   - Team
   - Setup
   - Data
   - Diagnostics
   - any changed screen, tab, filter, dialog opener, or safe refresh action

7. Inspect for:

   - Flutter overflow stripes
   - clipped text
   - overlapping controls
   - inaccessible buttons
   - blank screens
   - auth/session failures
   - stale installed artifact
   - bad backend URL
   - fatal exceptions
   - `E/flutter`
   - `RenderFlex overflowed`
   - repeated network/auth failures

8. If the device still shows old behavior after install, clean and rebuild
   before blaming runtime logic:

   ```powershell
   flutter clean
   flutter build apk --debug --flavor forgeflow -t lib/main_forgeflow.dart --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true --dart-define=FORGE_FLOW_PROXY_BASE_URI=<proxy-url>
   adb install -r -d build\app\outputs\flutter-apk\app-forgeflow-debug.apk
   ```

9. Remember that a git merge does not distribute mobile code. Mobile fixes need
   a rebuilt and distributed artifact before users see them.

## Safe Screen Sweep Matrix

Use this matrix in execution reports.

| Surface | Required checks | Common defects |
| --- | --- | --- |
| Web shell/navigation | route changes, selected nav, no blank shell | stale service worker, bad route, auth loop |
| Operators | filters, table/empty state, details opener | auth grant, pagination, PII handling |
| Pricing | safe dialog openers, current values | accidental mutation, stale payload |
| Corpus | tabs, graph/candidate artifacts, refresh | missing artifact, missing producer |
| Integrations | provider cards, status copy | secret/config gap, producer stale |
| Debug | filters, request logs, manual refresh | CORS, auth grant, unbounded refresh |
| Observability | payload mapping, neutral/degraded states | bad producer, unknown painted red/green |
| Health | readiness versus deep checks | hiding yellow/red, expensive auto-refresh |
| Feature Flags | read state, safe openers only | accidental live mutation |
| Mobile shell | bottom nav, live state, safe settings opener | stale APK, backend define gap |
| Mobile Settings | Account/Team/Setup/Data/Diagnostics tabs | overflow, PII screenshots, auth role |
| Mobile Diagnostics | advisor/data checks, safe actions | layout overflow, provider route failure |

## Fix And Retest Loop

For each defect:

1. Classify the issue.
2. Identify whether source, build artifact, deploy, browser cache, installed
   APK, backend producer, or data state is responsible.
3. Make the smallest targeted fix.
4. Add a scoped test or guardrail when the defect can recur.
5. Rebuild the affected artifact.
6. Redeploy web/proxy or reinstall mobile only when needed.
7. Retest the exact failed path on the real browser/device surface.
8. Capture after evidence.

Do not mark the issue fixed from source inspection alone.

## Required Tests And Commands

Run the smallest credible verification suite for the changes.

For web/admin console and proxy E2E work:

```powershell
dart analyze
flutter test <scoped-admin-and-proxy-tests>
dart run tool\perf_gate\staging_console_probe.dart --run --admin-url=<admin-url> --proxy-url=<proxy-url> --enforce-budgets
```

For mobile UI/layout E2E work:

```powershell
dart analyze
flutter test <scoped-mobile-widget-tests>
flutter build apk --debug --flavor forgeflow -t lib/main_forgeflow.dart --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true --dart-define=FORGE_FLOW_PROXY_BASE_URI=<proxy-url>
adb install -r -d build\app\outputs\flutter-apk\app-forgeflow-debug.apk
```

For docs-only framework updates:

```powershell
git diff --check
```

## Evidence Packet

Every completed E2E pass should report:

- Browser Use status: worked or exact failure
- mobile device status: device id, package, installed artifact, or blocker
- branch and commit
- PR or merge state
- admin URL and proxy URL
- admin/proxy/backend revisions where applicable
- mobile backend/proxy define
- screens and workflows tested
- safe actions opened
- destructive actions skipped or approval reference
- defects found and taxonomy classification
- fixes made
- tests and commands run
- perf probe results when web/admin/proxy performance is in scope
- screenshots/log paths, with PII/secrets excluded
- remaining blockers

## Future Prompt Template

Use this template when asking an agent to run mobile and web console E2E:

```text
Task:
Run a live end-to-end acceptance pass for <scope> on branch <branch>. Use
Browser Use as the primary web test surface. Use a connected physical mobile
device when mobile is in scope. Do not perform destructive or mutating admin
actions without action-time approval.

Authority:
- PROJECT_TRACKER.md
- docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md
- docs/PERFORMANCE_FRAMEWORK.md
- docs/contracts/slice_runtime_acceptance_contract.md
- runbooks/browser_use_acceptance_harness_runbook.md
- runbooks/admin_console_browser_qa_runbook.md
- <active phase doc>

Targets:
- admin: <admin-url>
- proxy: <proxy-url>
- mobile package/flavor: <package/flavor>
- device: <device id or require discovery>

Required workflow:
1. Confirm Browser Use can attach, navigate, inspect, screenshot, and click.
2. Refresh authority docs and confirm branch/commit/revisions.
3. Hard refresh or clear stale Flutter web cache.
4. Sweep every reachable safe web screen, tab, filter, dialog opener, refresh,
   and non-destructive button.
5. Prioritize Operators, Pricing, Corpus, Integrations, Debug,
   Observability, Health, Feature Flags, and shell/navigation.
6. Verify Debug/Observability browser-origin routing, bounded/manual refresh,
   payload/UI contract, neutral unknown states, and degraded populated-bad
   states.
7. Launch the mobile app on the connected device against the live proxy.
8. Sweep mobile shell and Settings Account/Team/Setup/Data/Diagnostics.
9. Inspect browser console, network, CORS, auth, role, failed requests, stale
   assets, runtime packaging, missing producers, device logs, and UI overflow.
10. Classify every issue as browser/plugin, cache, CORS, auth, artifact,
    migration, producer/data, app bug, or test environment.
11. Fix issues found, add scoped tests/docs/runbooks when needed, rebuild or
    redeploy affected artifacts, and retest live.
12. Run `dart analyze`, scoped `flutter test`, and the staging console perf
    probe with enforced budgets when web/admin/proxy performance is touched.

Final report:
- whether Browser Use worked
- live revisions tested
- mobile device and artifact tested
- screens tested
- defects found with taxonomy
- fixes made
- perf results
- remaining blockers
```

## Carry-Forward Lessons

- Browser Use claims must be real or stopped with the exact plugin failure.
- A live URL can serve old Flutter web code through cache or service worker.
- Cache-busting query strings help, but headers and storage still matter.
- Source code merged to `master` is not proof that staging serves it.
- A mobile merge is not a mobile rollout; rebuild and install/distribute.
- Physical phone screenshots and logcat are stronger evidence than desktop
  mobile-width guesses.
- If a fresh install still shows old code, clean rebuild before over-fixing.
- Debug and Observability must use real browser-origin routing, not curl-only
  proof.
- Unknown metrics stay neutral; populated bad metrics degrade.
- Red/yellow health starts a producer investigation.
- Long-lived WebSocket or diagnostic work must not block cheap readiness.
- Safe E2E testing opens and observes; it does not mutate live state without
  action-time confirmation.
