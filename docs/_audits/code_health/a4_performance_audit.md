# A4 — Performance Audit (Static Survey + Measurement Plan)

Auditor: parallel sub-agent on `claude/nifty-clarke-d3ec25` (post-Codex
wave Step 4). Audit date: 2026-05-12. This is a static, code-reading
audit — no measurements were run; this document scopes what to measure
and where the risk lives.

Authority context: this audit complements (does not duplicate) the
Step 3 Lane A lens-audit running in parallel and the A11 soak-harness
durable-kit audit. The A11 audit explicitly defers p95 / p99 latency
budgets to A4
(`docs/_audits/code_health/a11_soak_harness_durable_kit.md:52-54`); this
document picks up that handoff. The B1+B2 hot-fix slice already
shipped `runZonedGuarded`, the Postgres pool gauge, the
`pubsub_subscriber.ring_buffer_keys` gauge, and the two `p4_*` soak
lanes (PR #476) — those are referenced below as baseline, not as
findings.

References:

- `docs/frameworks/PERFORMANCE_FRAMEWORK.md` (active, 2026-05-03).
- `docs/_decisions/post_codex_wave_decisions_2026-05-12.md` lock #8
  (audit hierarchy filter read-side join).
- `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`
  blocks A3 (ltree + descendant cache), B2 (soak harness).
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` S1–S5.
- `docs/_audits/code_health/a11_soak_harness_durable_kit.md`.
- `docs/contracts/slice_runtime_acceptance_contract.md`.
- `runbooks/cloud_run_env_vars.md:42`.
- `docs/POST_HARDENING_FOLLOWUPS.md:508-526` (preview pool exhaustion).
- `PROJECT_TRACKER.md`.

---

## Section 1 — Methodology

### 1.1 What this audit covers

Static-survey identification of the 20+ highest-risk perf hotspots
across the Flutter mobile app, the Flutter Web admin console, the
Flutter Web operator-web console, and the Dart `tool/advisor_proxy`.
For each hotspot the audit records:

- **Location** at `file:line` granularity from the worktree at
  `claude/nifty-clarke-d3ec25` (2026-05-12).
- **Symptom** the hotspot can produce (rebuild storm, duplicate
  fetch, polling cost, queue/wait, etc.).
- **Measurement approach** — the probe path, baseline JSON shape,
  and acceptable-range hypothesis. None of this has been measured;
  it scopes the next slice.
- **Mitigation hypothesis** — the smallest behavior-preserving fix
  that the framework's "allowed changes" list (PERFORMANCE_FRAMEWORK
  §Hard Boundaries) would admit.

### 1.2 What this audit does NOT do

- **No actual measurements were run.** This is a static survey only.
  The framework's golden-rule baseline (PERFORMANCE_FRAMEWORK §103-130)
  belongs to the execution slice that follows this audit.
- **No code edits** — the audit only writes
  `docs/_audits/code_health/a4_performance_audit.md`.
- **No load tests, no `/health` flooding, no proxy round-trips.** The
  framework's controlled-load section (§316-339) governs that work
  and requires explicit operator approval.
- **No proxy decomposition opinions.** Those live in A3
  (`a3_proxy_monolith_decomposition.md`).
- **No scaffold inventory.** That is A2's scope per the addendum C4.
- **No soak-harness extension proposals.** Those live in A11. This
  audit only flags the *perf assertions* the kit could surface in
  Section 4 below.
- **Production rate limiting / cost ceiling enforcement.** Those are
  proxy_idempotency_cache + usage_caps slices, not A4 scope.

### 1.3 Framework cross-reference

`docs/frameworks/PERFORMANCE_FRAMEWORK.md` is present, 465 lines, and
actively used. The framework's main gaps (relative to what A4 needs):

- **No numeric budget table** for mobile app surfaces (only the web
  console budgets in `tool/perf_gate/staging_console_probe.dart:39-49`).
  Section 5 below proposes the missing mobile budgets so a future
  slice can wire them into a `mobile_perf_probe.dart` companion.
- **No mention of bundle-size budgets for the operator-web flavor**
  (only the admin `admin_mainjs_gzip_c4` budget exists). Operator-web
  ships on the same Flutter Web infrastructure; same budget shape
  should apply.
- **No formal SLO for backend p95 / p99 per route family.** The
  framework's backend section (§234-258) lists what to record, but the
  numeric SLO lives in `phase_9_scalability_decisions_2026-04-27.md`
  scattered across locks and is not summarized for performance
  consumers. Section 5 below extracts the relevant numbers.

These gaps are flagged for A7 (cross-frameworks-update) consumption,
not fixed here.

---

## Section 2 — Frontend hotspots

| # | Hotspot | Location (file:line) | Symptom | Measurement approach | Mitigation hypothesis |
|---|---|---|---|---|---|
| F1 | Three independent 30s `Timer.periodic` instances on the Shift dashboard | `lib/screens/shift_dashboard.dart:361, 784, 951, 1329` | Each ticker drives `setState({})`; with two `context.watch` lookups per build (lines 797-798, 964-965, 1342-1343) the dashboard rebuilds the period selector, daypart scaffold, and time-into-service header every 30s independently — three rebuild waves per minute even when the operator is idle. | Profile-mode trace: capture frame timeline for 2 min on the dashboard with `flutter run --profile`; count `setState` calls and rebuilt widget count via `debugProfileBuildsEnabled`. Baseline: `build/perf_gate/mobile_shift_dashboard_idle.json` with `{"setstate_calls_per_min": N, "rebuilt_widget_count_per_min": M}`. | Coalesce into one shared `ValueListenable<DateTime>` ticker exposed via Provider; each consumer subscribes to the same tick instead of owning its own timer. The `_DaypartScaffoldSection` doc comment at line 928 even acknowledges the duplication ("Has its own `Timer.periodic` ... so the chip stays accurate"). |
| F2 | Pub/Sub subscriber pulls every 1 second per Cloud Run pod | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:146, 250-268` | Every pod runs a 1Hz pull loop against Pub/Sub Subscriber API; under Cloud Run autoscale with N pods, the project sees N pulls/sec at idle. Each pull touches a per-pod ring buffer `_ringBuffers` (line 186) keyed by `(operator_id, topic)` with no eviction (a1 §S3 already flagged this; gauge already wired). | Probe via `/health` runtime gauges → `pubsub_subscriber.ring_buffer_keys` (already gauged). Add `pubsub_subscriber.pulls_per_minute_per_pod` derived from the existing log line `pull_failed` / `pull_succeeded` counter (would need one structured-counter addition). Baseline shape: `{"pulls_per_min_per_pod": 60, "ring_buffer_keys_per_pod": N}`. | Adaptive back-off when N consecutive pulls return zero messages (Pub/Sub already exposes `receivedMessages: []`); same 1s floor on activity. Operator behavior unchanged — operators don't see this. |
| F3 | Connectivity probe runs `InternetAddress.lookup('example.com')` every 15s on mobile | `lib/state/connectivity_notifier.dart:28, 53, 64-72` | Periodic DNS lookup to a third-party domain. Battery cost is small but observable; also a quiet privacy issue (15s DNS heartbeats to `example.com` from every operator device). One known consumer: `ConnectivityRequiredButton`. | Capture frame + network trace for 5 min of idle mobile; count `InternetAddress.lookup` calls and bytes. Baseline: `{"dns_lookups_per_5min": 20, "external_dns_dest": "example.com"}`. | Two options: (a) cut interval to 60s when the app has been backgrounded for >5 min; (b) replace the lookup with a same-origin `HEAD /readyz` against the proxy — same proof of connectivity, no third-party traffic. Operator-visible behavior unchanged (the button shows the same offline state). |
| F4 | Admin console: every route switch blows away widget state via `ValueKey(routeId + scope)` | `lib/admin/admin_shell.dart:113-117` | The shell pegs `_AdminBody`'s key to a string composed of the current route id + scope cache key. Switching tabs forces full re-mount — every `initState()` re-fetches. `OperatorLocationAdminScreen._refresh` (line 130) fires on every mount with no caching. Same shape repeats in `corpus_admin_screen.dart:135`, `members_admin_screen`, `polling_and_pricing_admin_screen`, `roles_hierarchy_sessions_admin_screen`, `pricing_tier_admin_screen`, `feature_flags_admin_screen`, `integration_admin_screen`. | Web devtools network trace over a known route-cycle (Operators → Pricing → Members → Operators). Baseline: `{"unique_fetches_per_cycle": K, "duplicate_fetches_per_cycle": L}`. Initial hypothesis: L ≥ 3 because operator listing fires on every Operators re-entry. | Per-route gateway result cache with explicit invalidation: hold the last `Future<T>?` per gateway-class and replay it when the screen re-mounts within a freshness window (e.g. 60s). Each gateway already returns terminal results; a single `_listOperatorsCache: Future<List<OperatorAdminBundle>>?` field on a `AdminGatewayCacheScope` would dedupe. Operator behavior unchanged (manual "Refresh" button forces a new fetch). |
| F5 | Operator-web shell same pattern: KeyedSubtree per route id | `lib/operator_web/widgets/web_app_shell.dart:116-119` | Same teardown-on-tab-switch as F4. Operator-web ships with Members / Roles / Hierarchy / Sessions / Audit / Security routes that each re-fetch on every mount. The demo gateways are fine; the live HTTP gateways will not be once the `11W.*.live` follow-ups land. | Same as F4 — DevTools network trace across operator-web tab cycles after `11W.x.live` lands. Today the demo path is local-only. | Same cache-with-invalidation pattern. Worth designing once and dropping into both `admin_app.dart` and `operator_web_app.dart` Provider trees. |
| F6 | Admin Debug Console live-tail polls every 5 seconds when enabled | `lib/admin/screens/debug_console_admin_screen.dart:483-496`; `lib/admin/services/debug_console_admin_gateway.dart:194` | `kDebugConsoleTailPollInterval = Duration(seconds: 5)`. With 12 in-flight admin requests/min the screen burns 12 proxy round-trips per minute of dwell time. The in-flight guard at line 504 prevents pileup, but cost is still real. | Capture `/v1/admin/debug-console/tail-recent` request rate from proxy access logs while the live-tail toggle is on. Baseline: `{"tail_polls_per_min": 12}`. Comparison: with adaptive back-off, target `≤ 6`. | Adaptive back-off: 5s while new rows arrived in the last poll, 15s while three consecutive polls were empty. The screen even acknowledges the freshness contract — "live tail" is a UX promise, not a freshness guarantee; 15s is still well within "live" for an ops console. |
| F7 | Audited support actions screen ticker runs unbounded while an erasure is mid-grace | `lib/admin/screens/audited_support_actions_admin_screen.dart:194-213` | `Timer.periodic(widget.graceWindowTickInterval, ...)` rebuilds the screen until grace-window expires. Default tick interval is not pinned in the file; if it defaults to 1s the screen `setState({})` 30 minutes straight. | Read the default at the constructor site and verify the cadence — there is no widget-tree-visible label change faster than 60s (the chip reads "Xh Ym remaining" — minute granularity). | Pin the ticker cadence to `Duration(minutes: 1)` if it is not already; the chip's minute-granularity label has no need for faster ticks. |
| F8 | Barrio assets (~2.6 MB) bundled into every F&F build | `pubspec.yaml:147` declares `- assets/internal/barrio/` unconditionally; `du -sh assets/internal/barrio = 2.6M` | Barrio is paused per `memory/project_barrio_paused.md` and the entry point `lib/main_barrio.dart` is the only place these load — yet `flutter build apk --flavor forgeflow` and the operator-web build both bake in the 2.6 MB. App-bundle size affects mobile cold-start and operator-web first-paint. | `flutter build apk --flavor forgeflow --release --analyze-size` and compare against a parallel build with `assets/internal/barrio/` commented out. Baseline: `{"forgeflow_apk_mb": M, "delta_with_barrio_removed_mb": -2.6}`. | Move the barrio assets behind a flavor-conditional include. Flutter doesn't natively support flavor-conditional assets in pubspec.yaml; the usual workaround is a `pubspec.{flavor}.yaml` swap step in the build script. Operator-visible behavior unchanged on the F&F flavor. |
| F9 | Forge & Flow startup runs three sequential awaits in `_warmUpPersistedState` after the first frame | `lib/forge_flow_bootstrap.dart:228-255`, called from `unawaited(_warmUpPersistedState())` at line 141 | `primeManagerOverride` → `getActiveRestaurantId` → `loadOrBootstrapProfile` → `hydrateBenchmarkHonestyFromActiveCycle` — four serial SQLite reads inside the same warm-up future. The unawaited call means it doesn't block the first frame, but the sequential chain delays the dashboard's first read-model emission. | Measure cold-start to first useful frame on a profile build per the framework's mobile loop (§180-209). Baseline: `{"cold_start_to_useful_ms": N, "warmup_total_ms": M}`. | Parallelize the independent reads with `Future.wait` — `getActiveRestaurantId` is needed by two of the four steps, so the dependency shape is `(primeManagerOverride || getActiveRestaurantId) → (loadOrBootstrap || hydrateBenchmark)`. Operator-visible: dashboard fills in faster on cold start. |
| F10 | `firebase_auth_web` is bundled into BOTH the admin AND operator-web flavors, BOTH wire identical Firebase project options to `forge-flow-staging` as defaults | `lib/main_admin.dart:87-112`, `lib/main_operator_web.dart:87-112` | The two web flavors duplicate ~25 lines of `kFirebaseOptions` and the same gateway-resolver shape (`_resolveHealthAdminGateway`, `_resolveOperatorLocationGateway`, etc. — `main_admin.dart` has 11 such resolvers, each `if (rawBaseUri.isEmpty) return null;` shape). Each adds a constant amount of bundle weight that ships to every operator browser. | Inspect `flutter build web` output size for each entry point separately. Baseline: `{"admin_console_main.dart.js_kb": A, "operator_web_main.dart.js_kb": O}`. | Extract the resolver pattern into a single `_resolveAdminHttpGateway<T>({required factory})` helper. Saves bundle bytes; primarily a maintenance win. Operator-visible: none. |
| F11 | Two `Provider<ConnectivityNotifier>` reads in widget tree, only one consumer | `lib/state/connectivity_notifier.dart` (file) ↔ `lib/widgets/connectivity_required_button.dart` | The notifier is constructed even on operator-web (where it would lookup `example.com` through a JS shim) and on admin (where it has no UI consumer). Verified by the `dart:io` import at line 19 — admin / operator-web should not import `dart:io` per the operator-web entrypoint contract (`main_operator_web.dart:31-35`). | Grep the operator-web + admin entrypoints for `ConnectivityNotifier` construction. If the notifier is wired by `forge_flow_bootstrap.dart` only, no risk on web flavors. If it slips into the admin/operator-web bundle, that's an audit finding. | If the cross-flavor leak doesn't exist (i.e. mobile-only construction), close this row. If it does, gate the construction behind `!kIsWeb` and ensure no widget tree above `ConnectivityRequiredButton` panics. |
| F12 | `tzdata.initializeTimeZones()` called at first `_ensureTzInitialized()` invocation in the shift dashboard | `lib/screens/shift_dashboard.dart:36-40` | Lazy-loads the full IANA timezone DB (~30 kB) the first time the dashboard mounts. The dashboard is the operator's primary surface, so this runs on virtually every cold start. | Measure cold-start frame budget; isolate whether the tzdata init shows up in the dashboard's first build. | Move the init into the bootstrap warm-up at `forge_flow_bootstrap.dart:228` so the cost is paid after the first frame, not on the dashboard's first build. Operator-visible: dashboard's first frame paints faster. |
| F13 | `MaterialApp` rebuilds entire route on `AuthSessionNotifier` notify | `lib/forge_flow_app.dart` uses `context.watch<AuthSessionNotifier>()` 13 times (`Grep` count above) | Every `notifyListeners()` call on the session triggers a build of the surface using `context.watch`. Login screen, MFA challenge, auth_gate, etc. all watch it. Sign-in transitions, FCM token refresh, in-app update checks all touch the notifier. Worst case: a re-emit during an active sync rebuilds the entire `MaterialApp` tree. | Wrap the `AuthSessionNotifier` listener in a `Selector` that only fires when `session.userId` changes (vs. token-refresh emits). Capture rebuild count via `WidgetsBinding.instance.addPostFrameCallback` instrumentation. Baseline: `{"app_tree_rebuilds_per_signin_cycle": N}`. | Replace `context.watch<AuthSessionNotifier>()` at top-level with `context.select<AuthSessionNotifier, String>((n) => n.session?.userId ?? '')` so non-identity-changing emits don't trigger the rebuild. |
| F14 | `forge_flow_app.dart` is 1603 lines and re-rendered as one widget tree | `lib/forge_flow_app.dart` (full file) | The entry-tree widget is monolithic; small changes cause large `build` walks. 13 `context.watch` calls plus FutureBuilder/StreamBuilder usage means the tree's rebuild radius is wide. | Read the file with `Selector` analysis tooling. Confirm via DevTools: percent of build time spent inside `ForgeFlowApp.build`. | Decompose `ForgeFlowApp` into `AuthScope` + `RealtimeScope` + `SyncScope` + `ShellScope` so each rebuild has a tighter radius. Larger refactor — gate behind explicit slice approval. |
| F15 | `flutter analyze`-suggested const upgrades not enforced | Implicit — many Material widget tree subnodes lack `const` (admin screens scan shows `Column(children: [` with non-const children) | Non-const subtrees skip equality short-circuit and rebuild even when their inputs are unchanged. Mass effect on rebuild storm screens (F1, F4, F13). | `flutter analyze --no-fatal-warnings` + grep for `prefer_const_constructors` hits. Baseline: `{"prefer_const_constructors_hits": N}`. | One slice's worth of mechanical const-introduction across the worst offender (`forge_flow_app.dart`). |

Total frontend hotspots: 15. Of these, F1 / F4 / F8 / F12 are the
operator-visible-latency P0 candidates.

---

## Section 3 — Backend / proxy hotspots

| # | Hotspot | Location (file:line) | Symptom | Measurement approach | Mitigation hypothesis |
|---|---|---|---|---|---|
| B1 | Postgres pool default 4 connections; runbook-recommended 20 not pinned in production env | `lib/infrastructure/persistence/postgres/postgres_executor.dart:55, 84-100`; `tool/advisor_proxy/proxy_bootstrap.dart:117-121`; `runbooks/cloud_run_env_vars.md:42` | `kPostgresDefaultMaxConnectionsPerPool = 4`; A1 §S2 ranks this as HIGH evidence-strength crash trigger. Pressure-preview-v1 P1 #5 (POST_HARDENING_FOLLOWUPS:508-526) corroborates exhaustion at preview scale. Production runs with the same default unless `POSTGRES_POOL_MAX_CONNECTIONS=20` is set in Cloud Run env. | Confirm production env var. If unset: set to 20 (runbook value) and re-observe `/health.runtime_gauges.postgres_pool` over a full operator-day soak. Baseline JSON shape already exists via `PostgresPoolGaugeSnapshot.toJson()` (`advisor_proxy.dart:3691`). | Update Cloud Run env-var pin to `POSTGRES_POOL_MAX_CONNECTIONS=20`. Soak via `p4_operator_day_soak.dart` to confirm waiter count stays ≤ ½ of max. Operator-visible: latency under multi-session burst drops. |
| B2 | Audit log hierarchy filter join (decision lock #8) not yet implemented; ltree + descendant-set cache (addendum A3) also not built | Searches: no `JOIN locations` or `JOIN org_units` in `tool/advisor_proxy/`. Lock-doc reference: `post_codex_wave_decisions_2026-05-12.md:26`; addendum: `post_codex_wave_decisions_addendum_2026-05-12.md:23` | When the audit log hierarchy filter UI ships, it will trigger a 3-way join (audit_logs → locations → org_units) per query. At 200+ locations per operator the lock-doc's re-open trigger fires (`> 2× equivalent location-only query`). | Synthetic operator-day audit log query latency benchmark, run against a seeded fixture with N=200 locations and M=10k audit rows. Baseline measurement: `{"audit_filter_location_only_p95_ms": A, "audit_filter_hierarchy_p95_ms": B, "ratio": B/A}`. Pass if ratio ≤ 2. | Adopt the addendum A3 lock: add `org_unit_id_path` ltree column to `org_units` + a per-operator descendant-set cache in Postgres. Query becomes `WHERE org_unit_id_path <@ <ancestor_path>` — index-friendly. Slice owner: a future audit-filter UX slice. Operator-visible: filter latency stays predictable as hierarchies grow. |
| B3 | `_ringBuffers` map in `GoogleCloudPubsubSubscriber` grows unbounded by `(operator_id, topic)` key count | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:186` | A1 §S3 ranked MEDIUM; gauge `pubsub_subscriber.ring_buffer_keys` is now live (PR #476). What's missing: eviction. Each per-key list is bounded by `_ringBufferCapacity`, but the key count is not. At 17 vendors × 6+ topics per operator × N operators, the key count grows linearly with onboarded operators. | The gauge value over a multi-hour `p4_operator_day_soak.dart` run. Baseline: `{"ring_buffer_keys_at_t0": K0, "ring_buffer_keys_at_t2h": K2}`. Pass condition: `K2 - K0 ≤ ε` once the operator pool reaches steady-state. | LRU eviction with a max-keys cap (e.g. 1000 per pod). On overflow drop the oldest `(operator_id, topic)` ring entirely — replay request from a client with that operator falls through to the proxy's persistent replay path. Operator-visible: none unless replay-from-cache hit rate drops, which is observable in `realtime_bridge` metrics. |
| B4 | `_ringBufferCapacity` per-key default not pinned in any constant | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:180` (field, no nearby default — constructor param) | The per-key cap is constructor-supplied; if a future bootstrap site forgets the cap, the per-key list grows unbounded. Static finding only — current bootstrap looks correct. | Grep instantiation sites; confirm every `GoogleCloudPubsubSubscriber(...)` passes `ringBufferCapacity`. | Move the default into a top-level `kPubsubSubscriberDefaultRingBufferCapacity` constant in the same file. Operator-visible: none. |
| B5 | 58 deep-health producers run concurrently on `/health` hit | `tool/advisor_proxy/health_producers/producer_registry.dart` total: 8 family files, 58 producers per `proxyHealthRegisteredProducerCount()` | The framework's golden rule (§63-84) puts deep-health behind manual trigger. Verify the `/health` endpoint genuinely refuses auto-polling and is not being hit by an admin console heartbeat in the wild. The staging-probe budget already caps `/health` runs (`tool/perf_gate/staging_console_probe.dart:34-37`). | Production `/health` request rate observed in Cloud Run logs. Expected: ≤ 6/hr (manual operator runs only). Baseline: `{"health_calls_per_hour": N}`. If `N > 24` someone is polling. | If unauthorized polling is found: trace the caller, gate them. Operator-visible: faster Cloud Run cold-start cost averaged across the deployment because deep-health is not on the critical path of every request. |
| B6 | `/health` budget per-producer not visible in current PERFORMANCE_FRAMEWORK | Framework cross-reference: PERFORMANCE_FRAMEWORK §234-258 lists what to measure, no numeric SLO; `health_operation_budget.dart` exists but its budget shape is not documented in the framework | New producers can drop without a documented latency budget. Detected at A11 as a cross-framework gap; A4 confirms. | Document the budget contract per producer in the framework or in `slice_runtime_acceptance_contract.md`. | Documentation-only update; flag for A7. |
| B7 | `_BootstrapLocationResolver._cache` and `_knownOperatorIds` grow with operator count, no eviction | `tool/advisor_proxy/main.dart:1628`; `tool/advisor_proxy/realtime_bridge.dart:238` | Per A1 §S3, both grow linearly with operator count. Bounded by total onboarded operators. At launch scale (≤10 operators), negligible. At Tier-M (200+ operators per holding co.), still small but worth annotating as bounded. | Per-pod RSS over a 24h soak with 50+ operators connected. Baseline: `{"rss_mb_at_t0": R0, "rss_mb_at_t24h": R24, "delta_per_operator_kb": (R24-R0)/operator_count}`. | Annotate with a documented upper-bound comment + add to the runbook scale ceiling. Operator-visible: none. |
| B8 | Bare `catch (_)` debt (16 sites in `advisor_proxy.dart`) collapses error types into 503 | `tool/advisor_proxy/advisor_proxy.dart` (16 sites — see `POST_HARDENING_FOLLOWUPS.md:430-439`); A1 §H3 + §1.5 step 2 | Not a direct perf hotspot, but it directly blocks root-causing the next perf-induced 503 spike. Every 503 looks the same to the operator. | Audit-finding handoff to A3 (proxy decomposition). A4 only flags the perf-investigation impact. | Typed catches; A3 slice work. Operator-visible: operators eventually see better error copy. |
| B9 | Worker startup wiring constructs LISTEN connections + Pub/Sub subscriber + 58 producers + 12 admin gateway registries during cold start | `tool/advisor_proxy/main.dart` boot path + `worker_startup_wiring.dart` (369 lines); various gateway constructors fired before `serve()` | Cloud Run cold start cost compounds: cold pod can't accept traffic until LISTEN connections + initial JWT verifier warm-up + Pub/Sub subscription creation finish. The B1+B2 slice already added `runZonedGuarded`; this is about the duration, not the safety. | Cloud Run `instance_count` startup-time histogram for the proxy revision. Baseline: `{"cold_start_p50_ms": M, "cold_start_p95_ms": N}`. Pass condition: `p95 ≤ 5000`. | Audit deferral: many of these can be lazy-init on first request that needs them. Slice-sized work; bigger than A4 scope. Operator-visible: first-request-after-deploy latency drops. |
| B10 | Health-producer registry runs producers through bounded concurrency lane — concurrency floor not documented | `tool/advisor_proxy/health_producers/producer_registry.dart:1-9` mentions "bounded concurrency lane" without naming the bound | Misconfigured bound (= 1) makes /health 58× slower than necessary; misconfigured high bound saturates the pool. | Inspect `RegistryProxyHealthCheckStore` for the bound. | Document the bound in the file's top doc comment. Operator-visible: /health probe latency consistent. |
| B11 | Cloud Run autoscale + per-pod ring buffer: each new pod cold-starts a fresh subscriber that does NOT replay events older than retention window | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:77` (`kPubsubSubscriptionDefaultMessageRetention = Duration(minutes: 5)`) | When a pod cold-starts during an autoscale event, operators connected to that pod see "Reconnecting" until the new subscription seeds. The 5-minute retention is fine for normal traffic but blends with B9 cold-start cost. | Cloud Run pod-spawn event correlated with operator `RealtimeConnectionState` transitions captured client-side. Baseline: `{"connection_state_seconds_in_reconnecting": S}`. | No fix; this is documented behavior. Flag as a known scale-out characteristic in `runbooks/`. |

Total backend hotspots: 11. Of these, B1 (Postgres pool sizing) and
B2 (audit hierarchy filter join) are the P0 / P1 candidates.

---

## Section 4 — Soak harness gap analysis

The B2 slice (PR #476) shipped two new lanes
(`tool/pressure/p4_session_soak.dart`,
`tool/pressure/p4_operator_day_soak.dart`) plus a shared predicate
(`p4_session_record_predicate.dart`). The harness already asserts:

1. Every successful sign-in matches the role-mode session-record
   shape (`assertComplete`).
2. The proxy survives sustained sign-in load without root-zone
   crashes (via the B1 slice's `runZonedGuarded` wrap).
3. Pod RSS over a multi-hour run, observed externally via
   `/health.runtime_gauges`.

What's NOT yet asserted (the A4 wishlist that the next A11/B2
follow-up can pick up — A11 owns the kit's extension shape, A4 owns
the assertion list):

| # | Assertion | Why | Where to wire |
|---|---|---|---|
| S1 | `postgres_pool.waiter_count` stays ≤ ½ of max_connections over the run | Direct corroboration that B1 (pool sizing) is enough at the configured load. Today the gauge is captured but not asserted. | Add a soak-run-end assertion that reads the gauge time-series from `/health` polls fired at 30s cadence; fail if any sample crosses the threshold. |
| S2 | `pubsub_subscriber.ring_buffer_keys` is bounded after warm-up | Verifies B3 mitigation hypothesis. Today the gauge is captured but not bounded. | Same shape; fail when growth-rate over the last 30 min of the run exceeds 0 (steady-state pass). |
| S3 | Audit-log filter latency at Tier-M-shape locations (200+ rows) under sustained read load | Verifies B2 (audit hierarchy filter ratio ≤ 2). | New `p5_audit_log_filter_load.dart` lane; reuses the soak-output contract from A11. |
| S4 | Mobile cold-start to first useful frame stays under budget | Verifies F1 / F9 / F12 mitigation. | Out of scope for `p4_*` (those are proxy lanes). Belongs in a separate `tool/perf_gate/mobile_perf_probe.dart`. |
| S5 | Admin console route-cycle network trace shows no duplicate fetches within a 60s window | Verifies F4 / F5 mitigation. | `tool/perf_gate/staging_console_probe.dart` extension; bumps `--include-network-trace` flag. |
| S6 | Proxy `/health` deep call rate stays ≤ 6/hr per Cloud Run service | Verifies B5 framework rule. Catches accidental admin-screen auto-polling. | Add a Cloud Run log-based assertion in CI (read access logs, count `/health` 200s per hour). |

The harness's failure-mode taxonomy (per A11 §8) is well-formed; A4
asks A11 to extend it with **perf-regression** as a sibling category
alongside saturation and contract violation.

---

## Section 5 — Measurement plan

For the top 10 hotspots the next perf slice will measure first.
Probe paths, baseline shapes, and pass thresholds proposed below.
Each row maps to a row in §2 / §3.

### 5.1 Frontend — mobile

| Risk | Probe path | Baseline JSON shape | Acceptable range | Regression alert |
|---|---|---|---|---|
| F1 (Shift dashboard rebuild storm) | `flutter run --profile`, capture `Timeline.startSync('build')` events for 2 min of idle dwell | `build/perf_gate/mobile_shift_dashboard_idle.json` shape: `{"setstate_calls_per_min": N, "rebuilt_widget_count_per_min": M, "frame_jank_count": J}` | `N ≤ 3 (one consolidated 30s tick)`; `M ≤ 30`; `J ≤ 1` over 2 min | Manual check in PR description for any slice that touches `shift_dashboard.dart`; gate by a `flutter test integration_test/shift_dashboard_rebuild_count_test.dart` |
| F9 (cold-start warm-up serialization) | Cold-launch the F&F flavor, instrument `WidgetsBinding.addTimingsCallback` for first 5 frames | `build/perf_gate/mobile_cold_start.json`: `{"first_frame_ms": F, "first_useful_frame_ms": U, "warmup_total_ms": W}` | `F ≤ 1500 (release mode mid-tier Android)`; `U ≤ 3000`; `W ≤ 2000` | Mobile perf probe runs nightly against a Firebase Test Lab device |
| F12 (tzdata lazy-init) | Same probe as F9, with stack trace on first dashboard build | Same as F9 + `{"tzdata_init_during_first_dashboard_build": bool}` | `tzdata_init_during_first_dashboard_build == false` after mitigation | Same as F9 |
| F3 (DNS heartbeat) | 5 min idle on mobile, capture `dart:io` lookups via a `dart:developer` post-trigger | `build/perf_gate/mobile_idle_dns.json`: `{"dns_lookups_per_5min": L, "dns_dest_breakdown": {dest: count}}` | `L ≤ 5`; `dns_dest_breakdown` does not include `example.com` after mitigation | Reviewer check |

### 5.2 Frontend — web

| Risk | Probe path | Baseline JSON shape | Acceptable range | Regression alert |
|---|---|---|---|---|
| F4 / F5 (admin/operator-web route-cycle duplicate fetch) | `staging_console_probe.dart --run --include-network-trace=routes=Operators,Pricing,Members,Operators` (new flag) | Existing probe + `{"unique_fetches_per_cycle": K, "duplicate_fetches_per_cycle": L}` | `L ≤ 0` after mitigation | `--enforce-budgets` PR gate on the existing probe |
| F8 (Barrio asset bundle bloat) | `flutter build apk --flavor forgeflow --release --analyze-size` JSON output | Standard `flutter build` size-analysis JSON | F&F APK ≤ baseline − 2.0 MB after mitigation | Manual check in any pubspec.yaml-touching PR |
| F10 (web bundle bloat) | Same as F4 (the existing `admin_mainjs_gzip_c4` budget at `staging_console_probe.dart:42` covers admin; needs a sibling `operator_web_mainjs_gzip_c4` budget) | Same budget shape | Operator-web budget mirrors admin: `maxBytes: 1_250_000` | Same as F4 |

### 5.3 Backend / proxy

| Risk | Probe path | Baseline JSON shape | Acceptable range | Regression alert |
|---|---|---|---|---|
| B1 (Postgres pool sizing) | `dart run tool/pressure/p4_operator_day_soak.dart --ops=50 --duration=2h`; sample `/health.runtime_gauges.postgres_pool` every 30s | `postgres_pool: {"open": O, "idle": I, "waiters": W}` already shipped | Over the run: `max(W) ≤ max_connections / 2` and `max(O) < max_connections` | `S1` soak assertion above |
| B2 (audit hierarchy filter join) | New `p5_audit_log_filter_load.dart` lane after the ltree migration lands; `EXPLAIN ANALYZE` baseline first | `{"location_only_p95_ms": A, "hierarchy_p95_ms": B, "ratio": B/A}` | `ratio ≤ 2` per lock-doc #8 re-open trigger | New CI gate when the audit-filter UI slice ships |
| B3 (ring buffer key growth) | Same soak as B1; sample `/health.runtime_gauges.pubsub_subscriber.ring_buffer_keys` | `{"ring_buffer_keys": K}` already shipped | Steady-state growth ≤ 0 after warm-up | `S2` soak assertion above |
| B9 (proxy cold start cost) | Cloud Run instance-startup time histogram from Logs Explorer | `{"cold_start_p50_ms": M, "cold_start_p95_ms": N}` | `N ≤ 5000` | Manual check per deploy; auto-fail if `N > 10000` |

---

## Section 6 — Prioritization

P0 = operator-visible latency today.
P1 = scalability risk at >100 locations or multi-pod scale.
P2 = developer iteration speed (build/test time / bundle size).

| Rank | ID | Title | Tier | Justification |
|---|---|---|---|---|
| 1 | B1 | Postgres pool default 4 — pin to 20 in prod env | P0 | Direct cause of multi-session 503s today (A1 §S2 + POST_HARDENING_FOLLOWUPS:516). One-line config change with strongest expected impact. |
| 2 | F1 | Shift dashboard's three independent 30s tickers | P0 | Mobile rebuild storm on the operator's primary surface; every shift exposes the cost; addressable in one screen. |
| 3 | F4 | Admin console route-cycle re-fetches | P0 | Every F&F admin tab cycle costs unnecessary round-trips; visible drag on Operators / Pricing / Members workflows. |
| 4 | F8 | Barrio assets (~2.6 MB) bundled into F&F flavor | P2 | Smallest fix, biggest single-axis win (mobile APK + operator-web bundle both drop 2.6 MB). |
| 5 | B2 | Audit hierarchy filter join (lock #8) needs ltree+cache before scale | P1 | Re-open trigger at 200+ locations × 2× ratio. Not visible today but baked-in for V1.5. |
| 6 | F9 | Cold-start warm-up serial chain | P0 | Mobile cold-start visible; parallelizable; small slice. |
| 7 | F12 | tzdata lazy-init runs on first dashboard build | P0 | Same mobile cold-start branch as F9; same slice candidate. |
| 8 | B3 | Pub/Sub ring-buffer key eviction | P1 | Per-pod RSS growth; bounded today but not when N > 100 operators. Gauge already wired; only the eviction is needed. |
| 9 | F2 | Pub/Sub 1Hz pull cadence | P1 | Direct GCP cost line; multi-pod multiplier. Adaptive back-off is operator-invisible. |
| 10 | F13 | `MaterialApp` rebuild on token refresh | P1 | Hidden cost; rare but observable on long sessions. |
| 11 | F6 | Debug-console live-tail 5s polling | P2 | Admin-only; only burns proxy when toggled on. Adaptive back-off is cheap. |
| 12 | F5 | Operator-web route-cycle re-fetches (mirrors F4) | P1 | Same pattern as F4 but on operator-web; matters once `11W.*.live` lands. |
| 13 | F3 | Connectivity DNS heartbeat to `example.com` | P2 | Minor battery + privacy; one consumer; quick swap. |
| 14 | B9 | Cold-start cost of producer registry + Pub/Sub provisioning | P2 | Visible on every Cloud Run deploy + autoscale event; deserves its own slice. |
| 15 | F14 | `forge_flow_app.dart` monolithic build tree | P1 | Wide rebuild radius; not a quick fix; defers to a structural slice. |
| 16 | F10 | Bundle-bloat from duplicated resolver pattern (admin + operator-web) | P2 | Bundle-byte win; helps F4 / F5 measurements look cleaner. |
| 17 | F7 | Audited-support grace ticker cadence | P2 | Minor; possibly already fine; verify. |
| 18 | F15 | Missing `const` upgrades | P2 | One mechanical sweep across the worst offenders. |
| 19 | B4 | Pubsub ring-buffer capacity hardcoded at constructor | P2 | Constant move; defensive. |
| 20 | B5/B6/B10 | /health policy + concurrency-bound documentation | P2 | Framework cross-reference work; ties to A7. |
| 21 | F11 | ConnectivityNotifier flavor scoping | P2 | Verify-only finding; likely already correct. |
| 22 | B7 | Bootstrap caches grow linearly with operator count | P2 | Bounded; needs only documentation. |
| 23 | B11 | Pod-spawn replay window | P2 | Documentation-only. |
| 24 | B8 | Bare-catch debt collapses error types | P2 | A3 lane owns the typed-catch slice. |

---

## Section 7 — Suggested slice clustering

The 24 hotspots above naturally fall into five perf-focused slices.
Each slice respects the framework's "performance work must preserve
behavior" rule (PERFORMANCE_FRAMEWORK §15-23) and the
slice-runtime-acceptance contract.

### Slice A — `perf.proxy.pool-and-prereq` (P0)

Scope: B1 + B7 + (the Cloud Run env pin) + (`S1` soak assertion).

Files touched: `runbooks/cloud_run_env_vars.md` (no — already pinned),
production Cloud Run env var (operations, not code), assertion code
in `tool/pressure/p4_*` lanes for the gauge thresholds.

Why bundled: smallest config change with the highest production
ROI; can ship in days; the soak assertion locks the regression net.

### Slice B — `perf.mobile.shift-dashboard` (P0)

Scope: F1 + F9 + F12 + (mobile perf probe scaffolding for §5.1).

Files touched: `lib/screens/shift_dashboard.dart`,
`lib/forge_flow_bootstrap.dart`, new
`tool/perf_gate/mobile_perf_probe.dart` shaped after
`staging_console_probe.dart`.

Why bundled: all three are the same screen's cold-start +
steady-state perf story; the mobile probe is the regression net.

### Slice C — `perf.admin.route-cycle-cache` (P0)

Scope: F4 + F5 (parallel demo + live shapes for admin and
operator-web) + F10 + (extended `staging_console_probe.dart`).

Files touched: new `lib/admin/widgets/admin_gateway_cache_scope.dart`
(shared cache + invalidation policy), updates to the 8 admin
screens listed in F4, parallel update to the operator-web shell.

Why bundled: one shared cache scope serves both consoles; one slice
clears the duplicate-fetch class of finding.

### Slice D — `perf.bundle.barrio-decouple-and-asset-budget` (P2 but largest single-axis win)

Scope: F8 + F10 + extending `staging_console_probe.dart` to add an
`operator_web_mainjs_gzip_c4` budget.

Files touched: build scripts (`scripts/deploy_*.ps1`), `pubspec.yaml`
swap shim, `tool/perf_gate/staging_console_probe.dart` budget
table.

Why bundled: one slice covers all bundle-size-class findings.

### Slice E — `perf.realtime.pubsub-eviction-and-backoff` (P1)

Scope: F2 + B3 + B4 + (soak assertions `S1` and `S2`).

Files touched:
`lib/services/realtime/google_cloud_pubsub_subscriber.dart` (add
LRU eviction + adaptive back-off), constants for ring-buffer
default, soak assertion code.

Why bundled: same subscriber class; ships with its own gauge-asserts.

### Out of A4's clustering

Slices F13 / F14 (deep refactors of `forge_flow_app.dart`) and B2
(audit hierarchy filter — depends on the addendum A3 ltree migration)
land in their own slices when the dependencies arrive. Slices B8 / B9
fold into A3 (proxy decomposition) and the proxy_split phase, not A4.

---

## Section 8 — What was NOT audited

Explicit boundary statements so the next reader doesn't expect more:

- **No actual benchmarks were run.** Section 5 is the measurement
  PLAN. Numbers like "p95 ≤ 5000 ms" are proposed thresholds, not
  observed values. The execution phase after this audit is where
  numbers get written.
- **No scaffold inventory.** That is A2's scope per addendum C4.
  A4 only references scaffolds when they show up in a perf hotspot
  (none did directly).
- **No proxy decomposition / typed-catch work.** That is A3's scope.
  Bare-catch debt is flagged in B8 only as a perf-investigation
  blocker, not as A4-owned fix work.
- **No email-pipeline scenarios.** That is C's scope (already
  audited).
- **No soak-harness extension contract.** A11 owns that. A4 only
  flagged the perf assertions (Section 4) the kit could surface,
  not the kit's extension shape.
- **No schema-versioning work.** That is A5's scope (already
  audited).
- **No framework-update PRs.** Findings against
  `PERFORMANCE_FRAMEWORK.md` (Section 1.3 + B6) are flagged for A7
  cross-frameworks-update consumption, not patched here.
- **No advisor / RAG / AGE perf work.** Phase 11b / 12 are paused
  (per `project_phase_pause_2026_05_03.md`). When they unfreeze the
  retrieval and graph producer perf budgets become A4's concern;
  today they are out of scope.
- **No iOS-specific cost analysis.** Mobile measurements in §5.1
  call out Android (the framework's mobile loop §180-209 is
  device-agnostic; iOS-specific perf characteristics like dyld
  cache + scene rehydration are not covered here).
- **No browser-flavor differences (Chrome / Safari / mobile
  Safari).** Probe runs are Chrome-only today
  (`staging_console_probe.dart` is HTTP, not browser-driven). Real
  browser perf belongs to the Browser Use slice owners.
- **No advisor proxy AI cost telemetry.** `usage_caps` and AI
  cost-class measurement belong to phase 11a.10; not A4 scope.
- **No mobile push delivery latency.** Phase 8 push notification
  proof slice owns that.
- **No login flow latency vs the addendum A1 redemption-code
  handoff.** That handoff is a B11 slice (post-Codex wave); when it
  lands its sign-in latency becomes a perf concern; today the JWT
  handoff is decision-locked but not implemented.

---

## Cross-reference summary

| Audit | Relationship |
|---|---|
| A1 (`a1_proxy_bug_root_cause.md`) | S1 / S2 / S3 directly feed B1 / B2 / B3. A4 is the measurement-plan companion to A1's diagnostic. |
| A3 (`a3_proxy_monolith_decomposition.md`) | Owns the typed-catch slice that unblocks B8. A4 does not duplicate. |
| A5 (`a5_schema_versioning_and_a7_frameworks.md`) | A7 surface owns the framework-update slice; A4 contributes Section 1.3 + B6 to that backlog. |
| A11 (`a11_soak_harness_durable_kit.md`) | A11 owns the soak kit extension contract; A4 contributes Section 4 (the perf-assertion list) + the regression-category extension request. |
| C (`c_email_notification_scenario_inventory.md`) | Disjoint scope; no overlap. |
| Lock doc + addendum | Decision #8 (lock) + A3 (addendum) drive B2. |
| `PERFORMANCE_FRAMEWORK.md` | Authoritative; A4 reuses its loop shapes, budgets table, and golden rule verbatim. |

---

## Appendix A — Investigative inventory

The grep + read counts below are recorded so a follow-up auditor can
re-run them and detect drift. All counts captured 2026-05-12 in the
`claude/nifty-clarke-d3ec25` worktree.

### A.1 Polling and timers

`rg "Timer\.periodic|Stream\.periodic" lib` — 13 hits across 9 files:

| File | Lines | Cadence | Disposed? |
|---|---|---|---|
| `lib/state/connectivity_notifier.dart` | 53 | 15s | yes (dispose:75) |
| `lib/screens/shift_dashboard.dart` | 361 | 30s | yes (367) |
| `lib/screens/shift_dashboard.dart` | 784 | 30s | yes (790) |
| `lib/screens/shift_dashboard.dart` | 951 | 30s | yes (957) |
| `lib/screens/shift_dashboard.dart` | 1329 | 30s | yes (1335) |
| `lib/admin/screens/debug_console_admin_screen.dart` | 493 | 5s (when live-tail on) | yes (488) |
| `lib/admin/screens/audited_support_actions_admin_screen.dart` | 194 | unset default (likely 1s) | yes (182) |
| `lib/services/system_info_service.dart` | 78 | 1h | yes |
| `lib/services/current_state_boundary_monitor.dart` | 186 | 1m | yes (191) |
| `lib/services/realtime/outbox_tripwire_poller.dart` | 94 | 60s | yes |
| `lib/services/realtime/google_cloud_pubsub_subscriber.dart` | 250 | 1s | yes (stop:277) |

Disposal hygiene is uniformly good — every timer cancels in `dispose`.
Cadence audit findings live in §2 (F1, F2, F6, F7) and §3 (B11).

### A.2 Non-virtualized list usage

`rg "ListView\(" lib` — only 20 hits, all of which the grep also
matches via `ListView.builder` (18 of 20). The two consumers of
non-builder ListView are short, fixed-length lists. Not a hotspot.

### A.3 `FutureBuilder` / `StreamBuilder` density

`rg "FutureBuilder|StreamBuilder" lib | wc -l` — 26 hits across 9
files. The single largest concentration is in
`lib/admin/admin_routes.dart` (16 of 26 — all `StreamBuilder<AdminAuthState>`
wrappers around route-specific bodies). The pattern is structurally
fine (auth-state-aware route rendering) but every route ends up
re-evaluating the stream on each rebuild. Captured in §2 F4.

### A.4 Bundle-affecting imports

`grep -l "package:postgres\|package:sqflite" lib/main_admin.dart
lib/main_operator_web.dart` — both web entry points are clean
(neither imports the server-only deps). The pubspec.yaml declares
`postgres: ^3.5.9` and `sqflite_common_ffi: ^2.3.4` as direct
dependencies, but tree-shaking should drop them from web builds.
F8 (Barrio assets) is the larger bundle finding.

### A.5 Pool gauges + ring buffer gauges

Already wired post-B1+B2:

- `tool/advisor_proxy/advisor_proxy.dart:3691` —
  `postgres_pool` snapshot.
- `tool/advisor_proxy/advisor_proxy.dart:3707` —
  `pubsub_subscriber.ring_buffer_keys` snapshot.

Soak assertions on these gauges are the work item from §4 S1, S2.

### A.6 Health producer surface

`tool/advisor_proxy/health_producers/` — 8 family files, 58
producers total per `proxyHealthRegisteredProducerCount()`. Total
file size ~3227 lines. Categories: infra, audit, outbox, graph,
vector, rollup, retrieval, cost. The framework's golden rule
(§63-84) requires deep-health to be manual; B5 is the audit row.

### A.7 Proxy file sizes

- `tool/advisor_proxy/advisor_proxy.dart` — 18,623 lines.
- `tool/advisor_proxy/main.dart` — ~1,612 lines (proxy boot).
- `tool/advisor_proxy/proxy_bootstrap.dart` — bootstrap config.
- `tool/advisor_proxy/worker_startup_wiring.dart` — 369 lines
  (LISTEN consumers + tick handlers).

These sizes feed A3's monolith-decomposition motivation; A4 just
notes that the file size makes cold-start parse cost worth
measuring in B9.

### A.8 Front-end entry-point file sizes

- `lib/forge_flow_app.dart` — 1,603 lines (F14).
- `lib/admin/admin_routes.dart` — 3,045 lines (route catalog).
- `lib/admin/admin_app.dart` — 79 lines (slim).
- `lib/main_forgeflow.dart` — 150 lines.
- `lib/main_admin.dart` — 571 lines (resolver duplication —
  F10).
- `lib/main_operator_web.dart` — 252 lines.
- `lib/forge_flow_bootstrap.dart` — 255 lines.

### A.9 In-flight dedup adoption

`rg -i "in.?flight|_dedup|_pendingRequests" lib` — 38 files. Spot
checked:

- `lib/state/demo_mode_state_notifier.dart:145` — proper
  `_inFlight: Future<void>?` dedup with completion guard.
- `lib/state/realtime_auth_bridge.dart` — same pattern.
- `lib/admin/screens/debug_console_admin_screen.dart:504` —
  `_refreshing || _tailing` early-return guard.
- `tool/advisor_proxy/proxy_idempotency_cache.dart:68-69` —
  `_inflight: Map<String, Future<...>>`.

Admin gateway calls in the admin screens (e.g. `_refresh` in
`operator_location_admin_screen.dart:133`) do NOT dedup at the
gateway level — they rely on the in-mount lifecycle to prevent
overlap. F4 is the slice that adds an explicit per-gateway cache.

### A.10 Cache eviction discipline

- `proxy_idempotency_cache.dart:46-149` — bounded
  (`maxEntries: 10000`, TTL GC, LRU re-insert). Safe.
- `advisor_response_cache.dart` — Postgres-backed. Safe.
- `google_cloud_pubsub_subscriber.dart:186` `_ringBuffers` — per-key
  list is bounded; key count is not (B3).
- `tool/advisor_proxy/main.dart:1628` `_BootstrapLocationResolver._cache`
  — bounded by operator count (B7).
- `tool/advisor_proxy/realtime_bridge.dart:238` `_knownOperatorIds`
  — bounded by operator count (B7).

End of audit.
