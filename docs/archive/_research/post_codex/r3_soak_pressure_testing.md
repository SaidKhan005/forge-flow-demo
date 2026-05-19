# R3 — Soak / Pressure Testing Patterns for F&F

Research-only brief. Informs a durable soak / pressure-test capability on
top of the existing `pressure.preview.v1` lanes (`tool/pressure/p3a`/`p3b`/
`p3c_*.dart`) and helps root-cause two production bugs:

  - **Bug A** — Proxy returned an incomplete session record on sign-in
    after support-check (Firebase Auth → `/v1/sessions/...` finalize).
  - **Bug B** — Proxy crashed after some time of live use with multiple
    sessions (Cloud Run revision exited; symptoms TBD: OOM, fd exhaustion,
    or unhandled async error).

Reference baseline (existing pattern): in-process Dart harnesses emit
per-request JSONL + Markdown finding summary. Hard preview-URL guard,
bounded duration cap, synthetic operator UUIDs, placeholder secrets.
Three lanes today (3A webhook flood, 3B backfill flood, 3C OAuth
refresh storm) feed Phase 5 catalog, not CI gates.

The baseline is good at per-vendor adapter pressure, but does NOT cover
the two bugs. The gaps: (1) no hours-long soak lane; (2) no
session-record completeness invariant under load; (3) no runtime crash
forensics wiring; (4) OAuth storm doesn't sweep TTL / vendor-mix /
jitter; (5) no replayable operator-day workload; (6) no multi-step
sign-in flow integrity test. The six sections below address each gap.

---

## 1 — Long-running multi-session proxy soak harness

Goal: keep N synthetic operators (mix of Flutter Web + Flutter Mobile UA)
signed-in and exercising the proxy for hours, with multiple operators
concurrent, watching for slow leaks and tail-latency degradation.

### Reference patterns

**Pattern A — Custom Dart harness (continuation of `p3*` shape).**
One binary, per-operator async loop, sustained for hours. Reuses
preview-URL guard, JSONL findings sink, synthetic identifiers. The
soak shape is just a duration-cap extension + periodic checkpoint
summary every N minutes to detect drift mid-run.

**Pattern B — Grafana k6 with multi-stage `scenarios`.** Industry
default for HTTP soak. Single binary, JS scripts, native multi-stage
VU profiles (ramp-up → steady → ramp-down → hold), low per-VU
footprint. Scenarios co-run "anonymous mobile-UA browse" +
"authenticated web-UA dashboard poll" + "MFA challenge replay" as
separate VU pools. Soak is a first-class shape. Grafana Cloud
Synthetic Monitoring is k6 under the hood.

**Pattern C — Locust.** Python master/worker; great for complex
stateful Python clients. Slower per VU (GIL-bound). Language
mismatch for us.

**Pattern D — Artillery.** YAML-first, Node hooks. Weaker on
multi-hour soak; smaller ecosystem.

**Pattern E — Gatling.** Scala/Java; highest single-process
throughput. Overkill for a 10–50 RPS Dart proxy; language mismatch.

### Applicability to F&F

  - The proxy seam is HTTP-only; we need request **shapes** (UA,
    Origin, cookie/JWT lifecycle), not real browsers. k6 and Dart
    both handle that trivially (`p3a` already does it via
    `kHarnessUserAgent`).
  - k6's native `browser` API (Playwright-based) would let us drive
    real Flutter Web through the sign-in flow. Useful for Bug A
    repro if the contract violation sits in client-side response
    handling. But ≥256 MB per VU — overkill for a back-end bug.
  - The Dart harness wins because it can `import` proxy DTOs and
    assert contract at runtime fidelity (see §2). No new tool for
    reviewers to learn.

### Recommendation

**Primary: extend the Dart harness** (new `p4_session_soak.dart`) —
can assert against actual proxy DTOs. **Secondary: thin k6 scenario**
(`tool/pressure/k6_session_soak.js`) for black-box second opinion +
Grafana Cloud Synthetic Monitoring later. Two layers: Dart for
contract-level assertions, k6 for HTTP shape coverage.

### Cost

Dart extension ~1.5–2 days (hours-scale duration cap + per-operator
long-lived state machine + N-min checkpoint dump). k6 scenario
~0.5 day. Total ~2.5 days.

### Catches Bug A or B?

  - Bug A: YES if Dart harness asserts on response DTO (§2 + §6);
    NO if it only measures latency/status.
  - Bug B: YES — soak shape is exactly what Bug B needs. Requires
    §3 forensic wiring to diagnose; soak just provides time-on-task.

---

## 2 — Session-record completeness invariants under load

Goal: every successful sign-in (and every successful session-finalize,
session-refresh, MFA-step finalize) returns a complete session record.
Bug A was a regression where the proxy responded `200 OK` with a partial
DTO; the load harness must assert *every field* on *every successful
response*.

### Reference patterns

**Pattern A — Property-based testing with explicit invariants.**
Invariant ("for all sign-ins, response carries
`{user_id, operator_id, location_id, refresh_token, expires_at,
support_check_completed, mfa_factors[]}` non-null per state") +
input generator (synthetic operator pool, support-check on/off,
MFA on/off). Frameworks: Hypothesis (Py), QuickCheck (Scala),
`fast-check` (JS), `glados` (Dart).

**Pattern B — Schema-driven contract testing (Schemathesis).** Ingests
OpenAPI / GraphQL schema, auto-generates property tests against a
running service. Built-in checks: `status_code_conformance`,
`not_a_server_error`, `response_schema_conformance`, plus
`stateful_testing` via OpenAPI `links` for chained calls.

**Pattern C — Pact consumer-driven contracts.** Consumer records
expected shape; provider runs contracts in CI; broken provider fails
before deploy. CI-shaped, not load-shaped — but catches Bug A.

**Pattern D — Runtime invariant assertion (observability-driven).**
Proxy response handler validates every 200 body against
`SessionRecord.requireComplete()`; emits
`proxy_session_record_incomplete_total{route, missing_field}`.
Soak harness fails if counter > 0; same metric catches the bug in
production. Mirrors the metric-honesty doctrine.

### Applicability to F&F

No OpenAPI schema for the proxy today, so Schemathesis isn't
drop-in. We DO have Dart DTOs (`SessionRecord` + siblings) shared by
proxy and clients — cheapest invariant assertion is to import the
DTO in the Dart soak harness and call `SessionRecord.assertComplete()`
on every 200 response. Pattern D (runtime counter) is the strongest
durable defense — catches it in production, not just soak.

### Recommendation

  1. Add `SessionRecord.assertComplete()` predicate in
     `lib/domain/session/...` shared by harness + proxy + clients.
  2. Soak harness calls it on every 200 response; records
     `incomplete_session_record` finding with missing-field list.
  3. (Stretch) proxy emits
     `proxy.session_record.incomplete{route, missing_field}` gauge
     so production traffic surfaces the regression class.

### Cost

Shared predicate ~0.5 day; harness assertion ~0.5 day; production
metric + dashboard tile ~1 day. Total ~2 days.

### Catches Bug A or B?

  - Bug A: YES, high confidence — exactly the class this pattern
    catches.
  - Bug B: NO directly. Indirectly: if the partial state leaves
    a half-allocated DB resource (session row without refresh-token
    row), the leak could contribute. Completeness check surfaces it
    earlier.

---

## 3 — Proxy crash investigation patterns for Dart on Cloud Run

Goal: when the proxy crashes after hours under live multi-session use,
we want a forensic trail (heap snapshot, fd count, pool stats, last-
N unhandled errors) attached to the crash log — not just a SIGKILL.

### Reference patterns

**Pattern A — Dart VM Service in prod.** The built-in VM service
(Observatory protocol) exposes heap snapshots, allocation profiles,
CPU samples, and isolate state over WebSocket when started with
`--enable-vm-service`. Expose a secondary Cloud Run port gated by
IAM; snapshot → diff → identify retained objects.

**Pattern B — `dart:developer` snapshot on threshold.** Call
`developer.NativeRuntime.writeHeapSnapshotToFile()` (newer SDKs) or
the service-protocol RPC from inside the process when RSS > N% of
the Cloud Run limit. Write to GCS for offline DevTools analysis.

**Pattern C — `package:leak_tracker`.** Dart-official framework that
wraps disposable objects (Streams, Subscriptions, Timers, Listeners)
and reports objects that should have been GC'd but weren't. Harness-
side only.

**Pattern D — FD watcher via `/proc/self/fd`.** Periodic count
(every 60s) emitted as a metric catches socket / pgconn / file-
handle leaks before they exhaust the cgroup limit. Cloud Run's fd
limit is roughly 10% of memory by default.

**Pattern E — Connection-pool saturation signal.** `package:postgres`
exposes `pool.size` / `pool.idle` / `pool.waiting`; emit as gauges.
`p3a` already pattern-matches `DependencyTimeoutException(surface:
postgres, operation: acquire_connection, ...)` post-hoc — promote to
a first-class metric + alert.

**Pattern F — Unhandled-future detection.** Wrap every top-level
async entry point in `runZonedGuarded`; log unhandled errors with
stack + last-N request IDs. Dart isolates terminate on uncaught
async errors by default — a guarded zone catches them and emits a
structured log line.

**Pattern G — Cloud Profiler.** GCP Cloud Profiler has no native
Dart agent today (supported: Go, Java, Node, Python, .NET). Not
viable; skip.

### Applicability to F&F

  - Heap snapshot on threshold (Pattern B) + fd watcher (Pattern D) +
    pool stats (Pattern E) + guarded zones (Pattern F) is the full
    forensic kit. None of these requires a new tool license.
  - `leak_tracker` (Pattern C) is harness-side only, not prod.
  - Cloud Profiler (Pattern G) is not viable yet.

### Recommendation (priority order for Bug B)

  1. **Pattern F — guarded zones**. Cheapest; catches the "unhandled
     async exception killed the isolate" case which is the modal Dart
     crash cause on Cloud Run.
  2. **Pattern E — pool stats metric**. The `p3a` harness already
     detects this *post-hoc* via response excerpts; promote to a
     proper gauge so we see saturation **before** it crashes.
  3. **Pattern D — fd watcher**. Cheap (10 lines of Dart reading
     `/proc/self/fd`); high signal for socket leaks.
  4. **Pattern B — threshold-triggered heap snapshot to GCS**.
     Highest forensic value, slightly more work.
  5. **Pattern C — `leak_tracker` in soak harness**. Diagnostic-only.

### Cost to implement

  - F (guarded zones): **0.5 day**.
  - E (pool gauge): **0.5 day**.
  - D (fd watcher): **0.5 day**.
  - B (snapshot trigger + GCS upload): **2 days** (snapshot
    encoding is non-trivial; the upload path needs Cloud Run SA
    permissions).
  - C (leak_tracker in harness): **0.5 day**.
  - Total full kit: ~4 days. Quick-win subset (F + E + D): ~1.5
    days.

### Would it have caught Bug A or B?

  - Bug A: NO directly (the bug returned 200 OK; the proxy didn't
    crash). The guarded zone would log if the partial DTO came from
    a swallowed exception, which is a strong hypothesis.
  - Bug B: YES, with very high confidence — at least one of the
    four signals (unhandled async, pool exhaustion, fd leak, heap
    leak) is the root cause. The forensic kit narrows it from "the
    proxy crashed" to "the proxy crashed because <X>".

---

## 4 — OAuth refresh storm extensions

Goal: extend the existing `p3c` harness to sweep parameters that
the current single-shape harness doesn't — token TTL distribution,
vendor-mix, retry-jitter — so we surface tail behaviors.

### Reference patterns

**Pattern A — TTL distribution sweep.** Real vendor TTLs vary (Toast
~14d, Square 30d, LinkedIn refresh 365d). Clustered TTLs → clustered
refreshes → the storm. Parameterize with uniform / normal / bi-modal
TTL distributions; record peak refresh-rate and whether the advisory
lock holds.

**Pattern B — Vendor-mix parameterization.** Today the harness fires
all 11 OAuth vendors with equal weight. Real operators carry 1–4
connections with a power-law mix (Toast + 7shifts dominate).
Parameterize `--vendor-mix=power-law`; rare-vendor refresh paths
may be where bugs hide.

**Pattern C — Retry-jitter parameterization.** AWS Builders' Library
canonical variants: none, full jitter (`random(0, base*2^n)`),
equal jitter (`half + random half`), decorrelated jitter. The
thundering-herd shape depends on which is used. Parameterize and
observe.

**Pattern D — Vendor mock + rate-limit response.** Vendors return
429 with varying `Retry-After` styles (header / body / none). Stub
HTTP server + toxiproxy-style fault injection lets us measure
broker behavior under realistic RTT + 429 shapes. `p3c` is
in-process today and doesn't exercise this.

**Pattern E — TTL fuzzing.** Random TTLs in a constrained range,
fed to the harness; verify advisory-lock + atomic-rotation contracts
hold for all. Property-based testing applied to the refresh contract.

### Applicability to F&F

All clean extensions of the `_StormCliArgs` shape already in
`p3c_oauth_refresh_storm.dart`. Add `--ttl-dist`, `--vendor-mix`,
`--jitter`, `--mock-vendor-latency-ms`, `--mock-vendor-rate-limit`.
The `SyntheticCredentialStore` covers TTL + mix in-process; Pattern
D needs a tiny in-process HTTP stub or toxiproxy sidecar. Aligns
with HP #4 (per-operator isolation).

### Recommendation

Add `--ttl-dist=uniform|normal|bimodal`, `--vendor-mix=equal|power-law`,
`--jitter=none|full|equal|decorrelated` flags. Default unchanged.
Pattern D becomes a separate `p4_vendor_mock_*.dart` binary, useful
for the broader integration soak too.

### Cost

A (TTL dist) 0.5d; B (vendor mix) 0.5d; C (jitter, touches
`vendor_credential_broker.dart`) 0.5d; D (mock vendor + fault
injection) 1.5d; E (TTL fuzz) 0.5d. All five ~3.5d; A+B+C alone
~1.5d.

### Catches Bug A or B?

  - Bug A: NO (orthogonal paths).
  - Bug B: PARTIAL — if root cause is refresh contention
    (advisory-lock starvation, pool exhaustion under bursty
    refreshes), the extended storm surfaces it. Low probability.

---

## 5 — Reproducible test scenarios mirroring real operator daily usage

Goal: a "synthetic operator workload" generator that mimics one
operator's *day* — sign in, open dashboard, check shift, resolve
alert, drill into Live Truth, sign out — and replays it across N
synthetic operators in parallel, for hours. This is the lane that
catches the integration-level bugs the per-route lanes miss.

### Reference patterns

**Pattern A — Shopify Genghis-style scripted workflows.** Versioned
user-journey scripts (browse, cart-add, checkout) with realistic
think times, ramped from multiple regions. Lesson: encode the
journey, not just the request shape.

**Pattern B — Production traffic replay (Speedscale, HHH, GoReplay).**
Capture real HTTP traffic, normalize identifiers, replay against a
target. HAR-replay (Hardy Har Har) is the lightweight version.
Speedscale productizes this.

**Pattern C — k6 `scenarios` with weighted executors.** Multiple
scenarios with different executors (`ramping-vus`,
`constant-arrival-rate`, `per-vu-iterations`); operator-day,
admin-occasional, webhook-ingest each in its own scenario.

**Pattern D — Stripe-style "test clock" + scripted scenarios.**
Stripe's billing test clocks compress months into seconds. F&F has
an equivalent: the existing demo-date advance (`_kDemoMode` carve-
out in `lib/screens/settings_screen.dart`). Combining demo-date
advance with replayable flows gives multi-day simulation in minutes.

**Pattern E — Chaos (Game Days, Toxiproxy).** Inject network
partition / latency / loss at dependency edges (e.g., Postgres);
run the operator-day workload alongside; observe degradation.

### Applicability to F&F

Pattern A (scripted workflow) is the right shape: Dart `Workflow`
abstraction — `signIn() → openDashboard() → checkShift() →
resolveAlert() → openLiveTruth() → signOut()`. Pattern B is the
future move once production traffic is captureable. Pattern C (k6)
is the lightweight black-box alternative; the same script seeds
production canaries later. Pattern D (demo-date advance) is unique
to us via HP #2 — compress multi-day journeys into minutes. Pattern
E (Toxiproxy) layers on top, see §3.

### Recommendation

Build `tool/pressure/p4_operator_day_soak.dart`: per-operator state
machine over the full day journey, realistic think times with jitter,
N synthetic operators in parallel for hours, same finding sink +
preview-URL guard as `p3*`, calls §2's completeness assertion at
every finalize step, emits 30-min checkpoint summaries. Add a
parallel k6 scenario for black-box coverage.

### Cost

Dart `Workflow` + operator-day journey ~2 days; finding + checkpoint
aggregation ~0.5 day; k6 scenario ~0.5 day. Total ~3 days.

### Catches Bug A or B?

  - Bug A: YES — sign-in is step 1; with §2's completeness assert
    the partial DTO surfaces immediately.
  - Bug B: YES — multi-hour multi-operator soak is exactly Bug B's
    shape. Pair with §3 forensic kit to diagnose.

---

## 6 — Sign-in flow integrity testing

Goal: assert end-to-end integrity of the multi-step sign-in flow
(sign-in credential → support-check → MFA challenge → fresh-MFA
verify → session record finalization). Specifically: catch the
class where step N succeeds but step N+1 silently emits incomplete
state.

### Reference patterns

**Pattern A — OWASP auth-bypass testing.** WSTG 4.4: complete step 1,
then force-browse / direct-API to post-auth state without step 2.
Map every step to an endpoint; verify each emits complete state and
no later step accepts a malformed earlier state.

**Pattern B — Schemathesis stateful testing with OpenAPI links.**
Chains requests via spec `links` (sign-in → finalize → MFA-challenge)
and asserts schema conformance + state-machine correctness at each
hop. Catches "step-N-emits-incomplete-state" because step N+1's
preconditions fail loudly.

**Pattern C — State-machine property testing.** `glados` (Dart),
`fast-check` (JS), or Hypothesis state-machines model the auth flow
as states + transitions + invariants. Property test: for any valid
sequence, the final state satisfies all invariants (session record
complete, MFA-required iff configured, support-check timestamp ≤
session creation, etc.).

**Pattern D — Synthetic monitoring (Datadog / Grafana / k6 cloud).**
Multi-step API + browser tests replay the sign-in flow every N
minutes as a production canary. Datadog's "critical user journey"
tagging routes auth-flow failures to the auth team. Catches Bug A
in production before users hit it.

**Pattern E — Pact consumer-driven contract testing.** Consumer
(Flutter) declares expected shape of each step's response; provider
(proxy) runs the contract in CI. Catches partial-response regressions
before deploy.

**Pattern F — Real-browser E2E (Playwright / Cypress + Firebase).**
Run the Flutter Web client headless through the full flow, inspect
intermediate state. Heaviest fidelity. Datadog/Grafana synthetic
monitoring is the productized form.

### Applicability to F&F

  - Pattern A (OWASP) is doctrine — every multi-step flow should
    have a bypass test. Encode as Dart integration test that
    completes step 1 then issues a forged step-2-skipping request.
  - Pattern B (Schemathesis stateful) requires an OpenAPI schema
    for the proxy. We don't have one. Cost: ~1 week to author
    + maintain. Worth it independently of pressure testing.
  - Pattern C (state-machine property test) is the cheapest
    correctness lever — encode the sign-in state machine in Dart
    with explicit `assertInvariants()` at every transition, hand
    to a property-test generator. Could live alongside the soak
    harness.
  - Pattern D (synthetic monitoring) is the production-canary
    layer; Grafana Cloud Synthetic Monitoring (k6-powered) is the
    natural target given we'd already have a k6 scenario from §5.
  - Pattern E (Pact) is CI-shaped, catches it before deploy.
  - Pattern F (real-browser E2E) is highest fidelity, heaviest
    cost; sensible for the V1 launch sign-in flow only.

### Recommendation

For Bug A specifically (catch the regression class going forward):

  1. **Now**: add §2's `SessionRecord.assertComplete()` predicate
     and call it from the soak harness on every step's success
     response. This is the cheap, immediate defense.
  2. **Soon**: add an OWASP-style integration test (Dart) that
     completes step 1 and asserts step 2 rejects a forged state.
     One test per step.
  3. **Later (production)**: a Grafana Cloud Synthetic Monitoring
     scripted check that runs the full multi-step flow every 5
     min from N geographies and pages on failure. Same script as
     the §5 k6 scenario.

### Cost to implement

  - §2 predicate already costed at ~2 days.
  - OWASP bypass tests: **1 day** (one per step, ~5 steps).
  - State-machine property test: **1.5 days** (model the FSM +
    invariants, hand to `glados`).
  - Grafana Synthetic Monitoring scripted check: **0.5 day** for
    the script + Grafana Cloud setup (operator decision required
    on the monitoring vendor).
  - Pact contract tests: **2 days** (consumer + provider sides).
  - Total: ~7 days for the full kit; ~3 days for the minimum
    viable (§2 predicate + OWASP tests + property test).

### Would it have caught Bug A or B?

  - Bug A: YES, very high confidence. §2 predicate + OWASP +
    property test are three independent defenses for this exact
    bug class. Production synthetic canary catches the same
    regression at deploy time, before users.
  - Bug B: NO direct relevance; the sign-in flow isn't the
    crash path.

---

## Summary — recommended sequencing

Anchored to root-cause for the two bugs + the durable capability ask.

### Quick wins (1–2 weeks, ~6 days total)

  - **§2 session-record completeness predicate + harness assertion +
    production metric counter** (2 days). Catches Bug A class going
    forward.
  - **§3 quick-win forensic kit**: guarded zones + pool gauge + fd
    watcher (1.5 days). Gives Bug B a forensic trail.
  - **§6 OWASP bypass tests** (1 day). One per sign-in flow step.
  - **§4 OAuth storm parameterization**: TTL dist + vendor mix + jitter
    (1.5 days). Extends the existing harness.

### Durable capability (2 weeks more, ~6 days)

  - **§1 + §5 long-running operator-day soak lane** (3 days).
    The lane that reproduces Bug B reliably.
  - **§3 heap-snapshot-to-GCS trigger** (2 days). Completes the
    forensic kit.
  - **§6 state-machine property test for sign-in flow** (1.5 days).
    Catches Bug A class at unit-test speed.

### Future (operator decision)

  - **§6 Grafana Cloud Synthetic Monitoring canary** for the
    production sign-in flow (0.5 day setup + ongoing cost).
  - **§4 mock vendor with fault injection** for OAuth storm
    (1.5 days). Higher fidelity.
  - **OpenAPI schema for proxy + Schemathesis stateful testing**
    (~1 week). Pays dividends across every proxy slice, not just
    pressure testing.

### Tools that fit (final picks)

  - **Custom Dart harness** (continuation of `tool/pressure/p3*.dart`)
    — primary surface, because it can import proxy DTOs and assert
    contracts at the same fidelity as the runtime client.
  - **k6** — secondary, for black-box HTTP shape coverage and a
    future Grafana Cloud Synthetic Monitoring path.
  - **`package:leak_tracker`** — harness-side only, for diagnosing
    soak-lane failures.
  - **Dart VM service + GCS upload** — production crash forensics.
  - **`glados` (Dart property testing)** — state-machine + invariant
    assertions.
  - NOT recommended: Locust (language mismatch), Gatling (overkill),
    Artillery (YAML-first weakness), Cloud Profiler (no Dart agent).

### Tools that fit Cloud Run constraints

  - All proposed tools are Dart-native or run as a one-off Cloud
    Run job from a workstation; no new always-on infra.
  - The forensic kit (heap snapshot, fd watch, pool gauge, guarded
    zones) is `dart:io` + `dart:developer` + `dart:async` — no new
    deps. The GCS upload uses `package:googleapis_auth` already
    in our pubspec.

## Sources

Load tooling: [Best Load Testing Tools 2026 (Vervali)](https://www.vervali.com/blog/best-load-testing-tools-in-2026-definitive-guide-to-jmeter-gatling-k6-loadrunner-locust-blazemeter-neoload-artillery-and-more/) ·
[k6 vs Artillery vs Locust vs Gatling PoC](https://medium.com/@dorangao/load-testing-poc-k6-vs-artillery-vs-locust-vs-gatling-node-js-express-target-f056094ffbef) ·
[Grafana — open-source load-testing review](https://grafana.com/blog/2020/03/03/open-source-load-testing-tool-review/) ·
[k6 scenarios](https://grafana.com/docs/k6/latest/using-k6/scenarios/) ·
[k6-learn load testing](https://github.com/grafana/k6-learn/blob/main/Modules/I-Performance-testing-principles/03-Load-Testing.md) ·
[k6 browser](https://grafana.com/docs/k6/latest/using-k6-browser/).

Dart runtime / Cloud Run: [Dart isolate HTTP memory leak (sdk #59937)](https://github.com/dart-lang/sdk/issues/59937) ·
[package:leak_tracker](https://github.com/dart-lang/leak_tracker) ·
[Dart DevTools memory view](https://docs.flutter.dev/tools/devtools/memory) ·
[Flutter Gems — Memory view part 7](https://medium.com/@fluttergems/mastering-dart-flutter-devtools-memory-view-part-7-of-8-e7f5aaf07e15) ·
[postgresql-dart #104 connection leak](https://github.com/stablekernel/postgresql-dart/issues/104) ·
[Dart concurrency](https://dart.dev/language/concurrency) ·
[Dart VM service protocol](https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md) ·
[Cloud Run memory limit](https://oneuptime.com/blog/post/2026-02-17-how-to-fix-cloud-run-memory-limit-exceeded-error-and-right-size-container-memory/view) ·
[Cloud Run SIGKILL troubleshooting](https://oneuptime.com/blog/post/2026-02-17-how-to-troubleshoot-cloud-run-container-exiting-with-signal-9-sigkill/view) ·
[Cloud Run container contract](https://docs.cloud.google.com/run/docs/container-contract).

Contract / property testing: [Schemathesis](https://schemathesis.io/) ·
[Schemathesis stateful testing](https://schemathesis.readthedocs.io/en/stable/guides/stateful-testing/) ·
[API contract testing — Steve Kinney](https://stevekinney.com/courses/enterprise-ui/api-contract-testing) ·
[Property-based testing — Kotest](https://kotest.io/docs/proptest/property-based-testing.html).

Production patterns: [Shopify performance testing](https://shopify.engineering/performance-testing-shopify) ·
[Shopify BFCM 2025](https://shopify.engineering/bfcm-readiness-2025) ·
[Shopify resiliency planning](https://shopify.engineering/resiliency-planning-for-high-traffic-events) ·
[Speedscale traffic replay](https://speedscale.com/blog/record-in-one-environment-replay-in-another/) ·
[AWS — timeouts, retries, jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) ·
[Nango — concurrent OAuth refreshes](https://nango.dev/blog/concurrency-with-oauth-token-refreshes) ·
[ReadyAPI — OAuth refresh in long load tests](https://support.smartbear.com/readyapi/docs/performance/practices/oauth.html).

Sign-in flow / synthetic: [OWASP WSTG — MFA testing](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/04-Authentication_Testing/11-Testing_Multi-Factor_Authentication) ·
[Datadog synthetic monitoring](https://www.datadoghq.com/blog/simplifying-troubleshooting-with-synthetic-monitoring/) ·
[Datadog MFA synthetic testing](https://www.datadoghq.com/blog/mfa-synthetic-testing-datadog/) ·
[Grafana Cloud Synthetic Monitoring](https://grafana.com/products/cloud/synthetic-monitoring/).
