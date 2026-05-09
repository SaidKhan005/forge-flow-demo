# Performance Framework

Status: Active
Last updated: 2026-05-03

This framework is the repeatable prompt and execution guide for performance
audits and performance-only optimization passes across the Forge & Flow mobile
operator app and the web/admin console.

Use it when a future prompt mentions performance, scale, latency, load,
responsiveness, bundle size, refresh behavior, polling, health, staging load
testing, mobile smoothness, web console timing, or production-cutover
performance gates.

## Core Promise

Performance work must preserve behavior.

The goal is to make the existing product faster, lighter, less wasteful, and
more resilient under load. It is not a license to change product logic, hide
backend truth, relax auth, replace the UI, change API contracts, or skip real
runtime proof.

Every performance pass follows this order:

1. Confirm the branch and runtime being tested.
2. Run the existing app or console, not a mock or replacement.
3. Capture baseline measurements before code changes.
4. Identify hotspots with evidence.
5. Apply targeted performance-only fixes.
6. Re-run the same measurements.
7. Verify the deployed or browser-served runtime.
8. Report exact before/after numbers, remaining risks, and carry-forward
   lessons.

## Hard Boundaries

Allowed:

- Remove duplicate fetches.
- Coalesce repeated requests.
- Prevent stacked in-flight actions.
- Add safe memoization where freshness behavior is unchanged.
- Lazy-load heavy screens, tabs, modules, or data after the user asks for them.
- Reduce unnecessary widget rebuilds.
- Improve table/list rendering with pagination, builders, or virtualization.
- Improve static asset caching, compression, and bundle delivery.
- Add smoke, benchmark, or performance guardrail scripts.
- Tune polling only when the same freshness guarantee is preserved.

Not allowed without explicit approval:

- Business logic changes.
- Auth, role, permission, or tenant isolation changes.
- API contract changes.
- Schema or migration changes.
- Hiding red/yellow/unknown backend health.
- Replacing the console or building a new UI.
- Removing visible data because it is slow.
- Aggressive load tests, destructive tests, or unbounded flood tests.
- Shipping fixture/demo behavior to public staging or production.

## Golden Rule

Do not let expensive truth become automatic UI refresh.

Cheap readiness and expensive diagnostics are different things. A page may load
cheaply and quickly, while deeper truth checks are manual, confirmed, scoped,
queued, or deferred.

Examples of expensive truth:

- `/health` dependency envelopes.
- Debug request logs.
- Audit chain verification.
- Replay tools.
- Vendor sync status across many operators.
- Advisor graph/vector/model runs.
- Workflow execution and polling.
- Large exports.
- Cross-operator admin tables.

These should not run just because a screen mounted unless the product
freshness requirement explicitly demands it.

## Prompt Intake Checklist

Every future performance prompt should start by answering:

1. Which surface is in scope: mobile app, web/admin console, proxy/backend, or
   all of them?
2. What exact branch, commit, deployment revision, URL, and backend/proxy are
   being tested?
3. What screens, routes, actions, forms, and workflows are exposed to the user?
4. Which calls are cheap readiness, and which are expensive diagnostics?
5. What are the current freshness guarantees?
6. What is the safe load-test ceiling before human approval is needed?
7. What measurements will prove improvement without behavior change?
8. What tests or guardrails will prevent regression?

If those answers are unknown, gather them before changing code.

## Baseline Measurement Matrix

Capture baseline numbers before making changes. At minimum, record:

- Initial cold load.
- Warm reload or repeated open.
- First meaningful visible state.
- Route/tab transition timing.
- API request count per screen.
- Duplicate or stacked requests.
- Polling cadence and timer cleanup.
- Slowest API requests with p50/p95/p99 where possible.
- Failed request rate and timeout behavior.
- Bundle or asset transfer size for web.
- Large list/table render behavior.
- Empty, error, and loading states.
- Rapid navigation behavior.
- Repeated button click behavior.
- Auth/session transition behavior.

For every number, include the environment:

- branch and commit
- local or deployed URL
- admin/proxy/backend revision
- browser origin or device id
- cache/service-worker posture
- whether the run is cold or warm

## Web/Admin Console Loop

Use the real existing web/admin console.

1. Confirm branch and latest integration point:

   ```powershell
   git status --short --branch
   git rev-parse HEAD
   git fetch origin
   ```

2. Confirm staging services and revisions:

   ```powershell
   gcloud run services describe forge-flow-admin-console --project forge-flow-staging --region northamerica-northeast2
   gcloud run services describe forge-flow-staging-proxy --project forge-flow-staging --region northamerica-northeast2
   ```

3. Run the local console against the real staging proxy:

   ```powershell
   .\scripts\run_admin_console_dev.ps1 -Device chrome -AdminProxyBaseUri https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app -- --web-port 7362
   ```

4. Open the browser-served console using the exact origin under test. Remember
   that `localhost` and `127.0.0.1` are different browser origins.

5. Avoid stale browser/service-worker cache:

   - use a fresh query string with branch/revision labels
   - clear storage when behavior looks stale
   - confirm served asset text or hashes when needed
   - record the exact URL tested

6. Run the staging console guardrail probe:

   ```powershell
   dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=<admin-url> --proxy-url=<proxy-url> --admin-revision=<admin-revision> --proxy-revision=<proxy-revision> --write-json=build\perf_gate\<label>.json
   ```

7. For `/health`, do not include deep health load by default. Use
   `--include-health` only when explicitly approved and keep the built-in caps.

8. Sweep every visible navigation area and exposed action. For admin tables,
   debug surfaces, health, observability, replay, provider usage, and exports,
   treat the screen as performance-sensitive by default.

## Mobile App Loop

Use the real operator mobile app path.

1. Confirm the branch, backend, auth mode, and operator/location dataset.

2. Prefer a physical Android device or representative emulator for the main
   pass. Use Chrome/narrow web only as a fast layout aid, not as the sole
   mobile performance proof.

3. Run in profile or release mode when measuring performance. Debug mode is
   useful for iteration but is not a performance baseline.

   ```powershell
   flutter devices
   flutter run --profile -d <device-id>
   ```

4. Record:

   - app startup time
   - sign-in/session restoration time
   - first useful screen
   - frame jank during navigation
   - scroll smoothness on long lists
   - network request count per screen
   - repeated refresh behavior
   - offline/poor-network behavior where safe
   - memory growth after repeated navigation
   - battery/heat symptoms during long-running animations or polling

5. Mobile-specific hotspots to look for:

   - expensive work inside `build`
   - broad provider/listener rebuilds
   - unbounded `Column`/`SingleChildScrollView` lists
   - large images decoded at full size
   - repeated SQLite or secure-storage reads during render
   - timers that survive route disposal
   - animation controllers that run when off-screen
   - duplicate auth/session refreshes
   - network calls triggered by every rebuild

6. Fix with behavior-preserving patterns:

   - narrower listen scopes
   - `const` widgets where useful
   - `ListView.builder` or paged lists
   - cached projections with explicit invalidation
   - debounced refresh actions
   - lifecycle-aware timer/subscription disposal
   - image sizing and cache discipline
   - deferring non-critical work until after first useful paint

## Backend And Proxy Loop

Frontend performance cannot be judged without the proxy/backend path.

For every performance-sensitive screen, record:

- endpoint path
- request count
- p50/p95/p99 latency
- status distribution
- timeout behavior
- retry behavior
- whether requests are scoped by operator/location
- whether the endpoint depends on graph, vector, vendor, AI, audit, or health
  producers

Backend/proxy performance rules:

- `/readyz` stays cheap.
- Deep `/health` is manual or explicitly scheduled, never casual polling.
- Cross-operator queries need filters and limits.
- RLS-backed tables need tenant-leading index discipline.
- Vendor syncs need idempotency, backoff, and freshness visibility.
- AI/provider calls need cost caps, timeouts, cache policy, and fallback copy.
- Exports, replay, and workflow runs should be async or explicitly bounded.

## Hotspot Decision Tree

When something is slow, classify it before fixing:

1. Duplicate client requests?
   - Coalesce or guard in-flight calls.

2. Expensive screen initialization?
   - Lazy-load tabs, defer diagnostics, or split cheap shell from heavy data.

3. Rebuild storm?
   - Narrow state listeners, memoize derived view models, and avoid work in
     `build`.

4. Large list/table?
   - Page, filter, virtualize, or switch to builder-based rendering.

5. Asset or bundle issue?
   - Measure transfer size, compression, caching headers, and lazy imports.

6. Backend latency?
   - Measure endpoint p95/p99, query plan risk, producer state, and timeout
     behavior before changing UI.

7. Polling or timers?
   - Prove freshness requirements, prevent overlap, add disposal, and back off
     where behavior allows.

8. Slow health/debug truth?
   - Make it manual, confirmed, scoped, and honest.

## Required Tests And Guardrails

Performance fixes should add or update tests that prove the waste does not
return. Good test examples:

- screen does not fetch until the heavy tab is selected
- opening Health does not call `/health`
- repeated button clicks create one in-flight request
- route disposal cancels timers/subscriptions
- list renders from a builder or page source
- cache invalidates when the source freshness token changes
- performance gate script fails on transfer-size or p95 budget regression

Run the smallest credible suite:

```powershell
flutter analyze
flutter test <targeted-tests>
dart run tool\perf_gate\staging_console_probe.dart --run --enforce-budgets --admin-url=<admin-url> --proxy-url=<proxy-url>
```

For docs-only framework updates, tests are usually not required, but run
`git diff --check`.

## Controlled Load Testing

Load tests must be controlled and reversible.

Start small:

- concurrency 1
- then 2
- then 4
- stop at the first sign of instability, high error rate, or unreasonable cost

Measure:

- p50/p95/p99 latency
- status distribution
- timeout rate
- error rate
- health impact
- recovery after the test stops

Do not run aggressive or expensive load tests without explicit approval.

Do not escalate deep `/health`, vendor, AI, replay, workflow, export, or
cross-operator tests casually. These can be real cost or ops events.

## Deployment And Runtime Proof

A code fix is not real until the actual runtime proves it.

Before final acceptance:

- rebuild only what changed
- redeploy or restart only what is necessary
- confirm Cloud Run service revision and image
- confirm proxy/backend revision
- confirm 100 percent traffic target
- open the real deployed URL or real browser-served local URL
- avoid stale browser/service-worker cache
- capture the exact URL tested
- confirm the live asset contains the expected behavior when necessary
- rerun the same measurements used for baseline

If the latest commit is docs-only and the deployed runtime already contains all
code changes, say that precisely instead of redeploying unnecessarily.

## Future Prompt Template

Use this template when asking an implementation agent to perform a performance
pass.

```text
Task:
Run a performance-only optimization pass for <mobile app / web admin console /
both> on branch <branch>. Do not change business logic, auth, API contracts,
schema, or visible truth. Do not build a replacement UI.

Authority:
- PROJECT_TRACKER.md
- docs/PERFORMANCE_FRAMEWORK.md
- docs/contracts/slice_runtime_acceptance_contract.md
- <active phase doc, if this belongs to a phase>

Runtime target:
- Mobile device/backend: <device id, backend/proxy, auth/data notes>
- Web console URL/proxy: <local URL and staging/deployed URL>
- Staging revision(s): <admin/proxy/backend revisions, or require discovery>

Required workflow:
1. Confirm branch, commit, origin, and latest integration point.
2. Confirm local/staging proxy/backend/admin revisions are current.
3. Run the existing app/console, not a mock or replacement.
4. Open the real browser/device experience.
5. Avoid stale browser/service-worker cache.
6. Sweep every visible screen, route, tab, action, form, and refresh path.
7. Capture baseline timing, request, polling, render, and load numbers.
8. Identify hotspots with evidence.
9. Make targeted performance-only fixes.
10. Add tests or guardrails that prevent recurrence.
11. Re-run the same measurements.
12. Redeploy/restart only what is necessary.
13. Re-test the live runtime.
14. Run controlled load tests only within safe bounds.
15. Report exact baseline vs after numbers and remaining risks.

Allowed changes:
- duplicate fetch removal
- in-flight guards
- lazy loading
- safe memoization
- request coalescing
- table/list pagination or virtualization
- asset/bundle delivery improvements
- benchmark/smoke/performance scripts

Blocked without approval:
- migrations
- auth/role changes
- API contract changes
- business logic changes
- hiding health or backend failures
- aggressive load tests
- destructive actions

Final report must include:
- exact URL/device tested
- branch and revision tested
- screens/workflows covered
- baseline vs after numbers
- load/proxy test results
- findings by severity
- fixes made
- tests/guardrails added
- anything intentionally not fixed and why
- risks remaining
- lessons for the next cycle
```

## Executive Report Shape

Every completed performance pass reports:

- Exact surface tested: mobile device, local web URL, deployed web URL, or all.
- Branch and commit.
- Admin/proxy/backend revisions.
- Screens and workflows covered.
- Baseline numbers.
- After numbers.
- Requests removed or deferred.
- Rendering/list improvements.
- Polling/timer changes.
- Bundle/asset changes.
- Load-test results and stop conditions.
- Tests and guardrails added.
- Behavior-preservation proof.
- Items intentionally not fixed.
- Remaining risks.
- Lessons to carry forward.

## Carry-Forward Lessons

- Test the real runtime, not an imagined one.
- Staging health can reveal real producer or ops state; do not paint it green.
- `localhost` and `127.0.0.1` are different browser origins.
- Browser cache and service workers can make old code look current.
- Runtime artifacts must be included in Docker/Cloud Build contexts.
- Deep diagnostics belong behind manual confirmation unless freshness requires
  automatic checks.
- Admin convenience screens can become accidental load generators.
- Future scale is protected by small defaults: scoped reads, bounded lists,
  in-flight guards, cheap readiness, and honest slow-path UX.
