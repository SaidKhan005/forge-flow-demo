# A11 — Soak Harness Durable Kit — Code-Health Audit

Auditor: parallel sub-agent on `claude/nifty-clarke-d3ec25` (post-Codex wave Step 4).
Audit date: 2026-05-12.
Scope: durable design of `tool/pressure/p4_*` soak lanes + accompanying
`/health` runtime gauges. Planning document only; no code changes were
made by this audit.

Authority context: this audit complements (does not duplicate) Step 3
Lane A lens-audit running in parallel. The B1+B2 hot-fix slice already
landed as PR #476 (commits `c3f1ce0d` + `fc1a3f80` + follow-up
`e26e53af`, audited in `docs/archive/_audits/post_codex_wave_2026-05-13/pr_476_b1_b2_audit.md`).
That slice shipped the R3 §3 quick-wins (`runZonedGuarded`,
`PostgresPoolGaugeSnapshot`, `pubsub_subscriber.ring_buffer_keys`,
`SessionRecordCompleteness.assertComplete`, two `p4_*` harnesses). What
remains and what this audit documents is the **durable kit framing** —
the lasting contract, CI integration, extension rules, and gap list
that the next person extending these lanes (`p5_*`) must read first.

References:
- `docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` Block B (B2).
- `docs/archive/_research/post_codex/r3_soak_pressure_testing.md` (full read, §1–§6).
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` (Bug A / Bug B taxonomy).
- `docs/contracts/slice_runtime_acceptance_contract.md`.
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`.
- `PROJECT_TRACKER.md`.

---

## Section 1 — Methodology and Scope

### 1.1 What "durable kit" means

The B1+B2 slice shipped a working soak harness. "Durable kit" is the
framing that turns that one-shot work into a permanent regression net:

| Dimension | Quick-win (what shipped in PR #476) | Durable kit (what this audit defines) |
|---|---|---|
| Code | Two `p4_*` lanes + shared predicate + runtime gauges | Same code, plus extension contract for `p5_*+` |
| CI | Local + smoke-runner test gated by `FF_RUN_PRESSURE_PREVIEW_P4*=1` | Tiered cadence: structural-only on every PR, full smoke nightly, weekly multi-hour |
| Forensics | Pool gauge + ring-buffer gauge + `runZonedGuarded` | Add audit-anchor lag, fd watcher, heap-snapshot trigger, structured `proxy.session_record.incomplete` counter |
| Output | JSONL raw + JSONL findings + MD summary | Same shape, formally locked as the soak-output contract for `p5_*+` |
| Documentation | Lane README at `test/load/pressure/README.md` | This audit + an extension-contract block appended to the README |
| Failure semantics | Exit code 3 on any incomplete session record; 0 otherwise | Formal failure-mode taxonomy → assert-site map (Section 8) |

### 1.2 What is NOT part of this kit

- **Real-browser E2E** — Playwright / Cypress runs live outside this
  repo via Browser Use (Codex-driven, `runbooks/browser_use_codex_acceptance_workflow.md`).
- **Production canaries** — Grafana Cloud Synthetic Monitoring is a
  future R3 §6 item; out of scope for this kit.
- **Performance benchmarks** — A4 (perf audit) owns p95 / p99 latency
  budgets. The soak kit only fails on saturation and contract
  violations, not on absolute throughput.
- **OpenAPI / Schemathesis** — R3 §6 future item; the kit ships
  without a proxy OpenAPI schema today.

### 1.3 Why the Dart-native shape was chosen (R3 §1 reaffirmed)

The harness can `import` proxy DTOs and the `SessionRecord` predicate
verbatim. k6 / Locust / Gatling cannot. For Bug A (contract
regressions), Dart fidelity is what catches the bug. A black-box k6
lane is on the R3 §1 secondary-recommendation list but is explicitly
not part of this kit (see Section 11).

---

## Section 2 — Current State Inventory

### 2.1 Files in `tool/pressure/` (counts via `wc -l`, 2026-05-12)

| File | Lines | Phase | What it asserts | What it does NOT assert |
|---|---|---|---|---|
| `p3a_webhook_flood.dart` | 1407 | Pressure-Preview-v1 §3A | Webhook idempotency under retry; proxy 5xx-free under load; signature verifier rejects forged sigs with 4xx (never 5xx); pool exhaustion `connection_acquire_timeout` patterns surface in finding sink | No multi-hour soak; no session contract; no root-zone crash forensics |
| `p3b_backfill_flood.dart` | 1526 | Pressure-Preview-v1 §3B | Backfill worker pool throughput; OAuth advisory-lock held across concurrent first-connection backfills; RLS context-switch under load; synthetic tenant cleanup in tearDown | No session lifecycle; no sustained operator-day journey |
| `p3c_oauth_refresh_storm.dart` | 816 | Pressure-Preview-v1 §3C | OAuth refresh advisory-lock contention; atomic token rotation; 11 OAuth vendors firing in same TTL window | Single-shape only — no TTL distribution sweep, no vendor-mix weighting, no jitter parameterization (R3 §4 quick-wins not yet land) |
| `p4_session_soak.dart` | 611 | Post-Codex addendum B2 | Every successful sign-in returns a complete session record per `SessionRecordCompleteness` (Bug A class); root-zone uncaught traps under hours of sustained load (Bug B class); pool/ring-buffer gauges via `/health` | No multi-step journey; sign-in is the only request shape |
| `p4_operator_day_soak.dart` | 596 | Post-Codex addendum B2 | Sign-in → dashboard → notifications → settings-nav → sign-out journey integrity; multi-step skip-downstream-on-401 discipline (no garbage traffic amplification); shared `assertComplete` on every sign-in step | No fresh-MFA step-up flow; no real vendor-connect step; no admin-impersonation flow |
| `p4_session_record_predicate.dart` | 195 | Post-Codex addendum B2 | Shared `SessionRecordCompleteness.assertComplete` predicate + CLI helpers (`parseSoakDurationSeconds`, `kSoakAllowedHostSubstrings`, `SoakShutdownSignal`, `SoakFinding`) | Not a harness — pure predicate + shared types |
| **Total** | **5151** | — | — | — |

### 2.2 Cross-lane shared infrastructure (what every `p*` already has)

Sourced from `p3a_webhook_flood.dart:90-115` and
`p4_session_record_predicate.dart:175-195`:

1. **Preview-URL guard** — `kAllowedProxyHostSubstrings` /
   `kSoakAllowedHostSubstrings`. Hard fail if proxy URL doesn't match
   `forge-flow-preview-*`, `forge-flow-staging-*`, `localhost`, or
   `127.0.0.1`. Belt-and-braces against accidental Production1 hits.
2. **Synthetic identifier convention** — deterministic UUID via
   `sha256('<role>-<ordinal>-<runSalt>')` reshaped to UUIDv4 layout
   (`p4_session_soak.dart:174-190`). Per-run salt isolates pressure
   traffic from staging tenants and from prior runs.
3. **Placeholder credentials** — `PLACEHOLDER-PRESSURE-PREVIEW-V1`
   secrets and `alg: none` JWTs that the proxy verifier rejects with
   401. The harness exercises the request loop, not the happy path —
   except when `FF_PRESSURE_SYNTHETIC_VERIFIER` is wired (preview
   only).
4. **Output shape** — JSONL raw (one record per request) +
   `SoakFinding` JSONL (one finding per category) + Markdown summary
   table. Gitignored.
5. **SIGINT drain** — `SoakShutdownSignal` future fires on
   `ProcessSignal.sigint`; worker loops check `shutdown.isFired`
   between iterations. Multi-hour runs survive Ctrl-C cleanly.
6. **CLI parser shape** — `--proxy-url=`, `--ops=`, `--concurrency=`,
   `--duration=` (parsed by `parseSoakDurationSeconds` supporting
   `30s`, `5min`, `2h`).
7. **30-second checkpoint summaries** — periodic `[checkpoint @ ts]
   n=… 2xx=… 5xx=… incomplete=…` lines so multi-hour runs surface
   drift mid-run.

### 2.3 Gap analysis — what the current set does NOT cover

Bridges to Section 8 (failure mode taxonomy):

| Gap | Bug class | Why current lanes miss it | Where the kit closes it |
|---|---|---|---|
| Long-running multi-hour soak that isn't auth-shaped | Bug B (Cloud Run crash after hours of live use) | `p3a` runs ≤30 min; per-vendor adapter only | `p4_session_soak` extended duration cap (≤4h documented) |
| Multi-step flow integrity (one bad step doesn't poison the next) | Bug A class regressions inside a journey | `p3*` issues one request per loop iteration | `p4_operator_day_soak` skip-downstream-on-non-200 guard |
| Audit chain anchor lag during sustained writes | Audit chain integrity (HP-adjacent) | No producer reads `audit_chain_anchors.anchored_at` from inside a soak | `auditChainLagSecondsProducer` already exists at `tool/advisor_proxy/health_producers/audit_producers.dart:22-59` — kit just consumes it via `/health` |
| OAuth refresh storm parameter sweeps (R3 §4) | Refresh-window thundering herd | `p3c` ships a single shape | **Not in this kit.** Future `p3c.1` extension; tracked in R3 §4 backlog. |
| fd-leak detection in soak | Bug B (socket / pg conn leak) | No gauge | **R3 §3 Pattern D quick-win** — proposed `/health` addition in Section 5 |
| Heap-snapshot-on-threshold | Bug B forensic depth | No trigger | **R3 §3 Pattern B durable** — Slice 4 in Section 10 |

---

## Section 3 — Two New p4 Scripts — Design

The harnesses landed in PR #476. This section formalizes them as
durable contract so a future engineer knows what they're allowed /
required to assert.

### 3.1 `tool/pressure/p4_session_soak.dart` (611 LOC, shipped)

**Scope.** Concurrent multi-session sign-in soak. N synthetic operators
loop `POST /v1/auth/session/login` for the configured duration with
realistic ±25% jittered think-times. Every 7th operator is `ff_support`
(scope-less) so the harness exercises the global-admin branch of
`SessionRecordCompleteness.assertComplete` (Bug A H1 hypothesis from
A1 §1.3).

**Scenario steps** (per operator, looped):

1. Build placeholder JWT with the operator's deterministic
   `user_id` / `operator_id` / `location_id` (empty when global-admin).
2. `POST /v1/auth/session/login` with `Authorization: Bearer <jwt>` +
   `x-pressure-test-lane: p4-session-soak` header (so staging log
   filters can isolate pressure traffic).
3. If status 200: call `SessionRecordCompleteness.assertComplete(body,
   roles: state.roles)`. On `assertion.complete == false`, append a
   `SoakFinding(category: 'incomplete_session_record', ...)`.
4. Append a `_RequestRecord` to `records[]` and `rawSink` JSONL.
5. Sleep `think-ms ± 25%`.

**Assertion sites** (`p4_session_soak.dart:486-500`):

- **`incomplete_session_record`** finding when status 200 +
  `assertionComplete == false`. The list of missing/unexpected fields
  is recorded verbatim in `evidence` so triage doesn't need to re-run.
- Run exits with code 3 when `incomplete > 0` at end-of-run. Code 0
  otherwise. Code 2 reserved for the preview-URL guard fail.

**Expected output**:
- `test/pressure/p4_session_soak_raw.jsonl` — one `_RequestRecord` per request.
- `test/pressure/p4_session_soak_findings.jsonl` — one `SoakFinding` per detected incomplete record.
- `test/pressure/p4_session_soak_summary.md` — Markdown table with totals + finding count.

**Runtime budget**:
- Smoke (CI / local dev): `--ops=5 --concurrency=5 --duration=60s` →
  finishes in ~60s + small overhead.
- Nightly: `--ops=20 --concurrency=10 --duration=10min`.
- Full-scale soak (weekly / on demand): `--ops=100 --concurrency=20
  --duration=2h`. Documented in the harness header
  (`p4_session_soak.dart:71-74`).

### 3.2 `tool/pressure/p4_operator_day_soak.dart` (596 LOC, shipped)

**Scope.** Synthetic operator-day journey, looped per operator. Five
steps per loop with ±25% jittered think-times. The proxy verifier
rejects the placeholder JWT with 401 in default deployments, so the
common path is "sign-in returns 401, downstream steps skipped, think,
loop." This is **intentional** — the lane stresses the proxy request
loop and exercises the multi-step integrity guard.

**Scenario steps** (per operator, looped):

1. `POST /v1/auth/session/login` (step: `sign_in`).
2. Skip steps 3-5 unless `sign_in` returned 200 (multi-step integrity
   guard at `p4_operator_day_soak.dart:436`).
3. `GET /v1/auth/account` (step: `dashboard`).
4. `GET /v1/operator/notification-preferences` (step: `notifications`).
5. `GET /healthz` (step: `settings_nav` — stand-in because real
   settings need fresh-MFA which the harness doesn't have).
6. `POST /v1/auth/session/refresh` with empty session_id (step:
   `sign_out` — placeholder; will 400/401, which is correct).
7. Sleep `think-ms ± 25%`, loop.

**Assertion sites** (`p4_operator_day_soak.dart:418-428`):

- **`incomplete_session_record`** finding on `sign_in` step when
  status 200 + `assertionComplete == false` (Bug A class).
- Run exits with code 3 when `incomplete > 0`. Same shape as 3.1.

**What the lane catches that 3.1 doesn't**:
- **Bug A inside a journey** — if `sign_in` returns the wrong shape
  inside a multi-step context (e.g., proxy state cached from a prior
  call), this lane sees it.
- **Garbage-traffic amplification** — if the multi-step guard breaks
  (e.g., a future refactor removes the `signIn.statusCode == 200`
  check), the lane would emit step 3/4/5 calls into a broken auth
  state, and the proxy 5xx rate would climb. The kit catches this as
  "5xx > 0" finding (future addition; see Section 8).

**Runtime budget**: identical to 3.1 (smoke / nightly / full-scale).

### 3.3 Why these two lanes, and not one combined

R3 §1 and §5 are deliberately separate. §1 (multi-session sign-in
soak) targets Bug A's exact regression class — sign-in shape under
load. §5 (operator-day) targets integration bugs that the per-route
lanes miss. Combining them would dilute the assertion sites: the
combined lane would have to track which step-N response to assert
`assertComplete` against, and the bug would slip through.

Keeping them separate also keeps each lane <650 LOC, which matches
the `p3*` precedent and keeps reviewer cognitive load bounded.

---

## Section 4 — `SessionRecord.assertComplete()` Predicate

### 4.1 Current shape (shipped in PR #476)

File: `tool/pressure/p4_session_record_predicate.dart` (195 LOC).
Predicate entry point: `SessionRecordCompleteness.assertComplete`
(`p4_session_record_predicate.dart:70-103`).

The predicate accepts a `Map<String, Object?>` body + a `Set<String>`
of roles. It has **two modes**:

**Mode 1 — Tenant-scoped (default)**. The body MUST carry non-empty
strings for all four fields:
- `session_id`
- `user_id`
- `operator_id`
- `location_id`

**Mode 2 — Global-admin** (any role in
`SessionRecordCompleteness.globalAdminRoles` = `{ff_support, super_admin}`).
The body MUST carry non-empty `session_id` + `user_id`, and MUST
carry empty strings for `operator_id` + `location_id`. This mirrors
the B1 proxy contract at `tool/advisor_proxy/advisor_proxy.dart:2168-2266`
(`requireOperatorContext`).

### 4.2 Why this exact shape

Two failure modes:
- **Missing field** — the proxy stripped a field that should have
  been present. A1 §1.3 H1 root-cause. Caught via `missingFields[]`.
- **Unexpected field** — the proxy emitted a tenant-scoped field for
  a global admin. Would mean a global-admin user got pinned to a
  specific operator on sign-in without going through the impersonation
  flow. Caught via `unexpectedFields[]`.

The predicate returns both lists in one assertion so a failing run
records all violations in a single finding, not N separate ones.

### 4.3 Coverage rationale

The predicate is covered by 9 unit tests at
`test/pressure/p4_session_record_predicate_test.dart:11-148`:

1. Tenant-scoped: all four fields non-empty → complete.
2. Tenant-scoped: missing `operator_id` → flagged.
3. Tenant-scoped: missing `user_id` AND `location_id` → both flagged.
4. `ff_support`: empty operator/location → complete.
5. `ff_support`: non-empty `operator_id` → flagged as unexpected.
6. `super_admin` uses the same global-admin contract.
7. Mixed-role token (`ff_support` + `advisor.read`) still uses
   admin contract.
8. Missing `session_id` flagged in both modes.
9. `parseSoakDurationSeconds` parses `30s`, `5min`, `2h`; rejects
   `'forever'`.
10. `isSoakProxyUrlAllowed` accepts preview/staging/localhost; refuses
    arbitrary URLs.

### 4.4 Proposed durable contract (no code change needed)

The predicate is the **single source of truth** for what "complete"
means. Three call sites are allowed:

1. **Soak harnesses** (`p4_session_soak.dart:336-339`, `p4_operator_day_soak.dart:282-285`).
2. **Future production gauge** — `proxy.session_record.incomplete{route, missing_field}`
   counter inside the proxy `/v1/auth/session/login` 200 emit path
   at `tool/advisor_proxy/advisor_proxy.dart:12430-12437`. R3 §2
   recommendation #3 / R3 §2.4 production-defense pattern. Not
   shipped; tracked as a follow-up slice.
3. **Future in-proxy assertion** — fail-closed on the response shape
   before it ever leaves the proxy. Same predicate, no fork. Tracked
   as a "stretch" item in R3 §2.

The predicate MUST NOT have a fourth call site without an explicit
contract update. The PR #476 audit at
`docs/archive/_audits/post_codex_wave_2026-05-13/pr_476_b1_b2_audit.md:18-22` calls this
out as "three-mirror discipline (proxy / soak predicate / client)" —
keeping the contract single-sourced is the whole point.

---

## Section 5 — `/health` Gauge Additions

### 5.1 Current `/health` envelope (shipped)

Endpoint: `GET /v1/health/deep` (deep-health envelope; `tool/advisor_proxy/advisor_proxy.dart:8653-8711`).
Shallow probes at `/health` and `/healthz` are unchanged (`tool/advisor_proxy/main.dart:289`).

Live gauges already in the deep-health envelope as of PR #476:

| Field | Source | Where computed | Computation |
|---|---|---|---|
| `runtime_gauges.postgres_pool.open_connection_count` | `PackagePostgresPool.gaugeSnapshot` (`lib/infrastructure/persistence/postgres/package_postgres_executor.dart:140-144`) | `PostgresPoolGaugeSnapshot` (`:58-77`) | `_ReusablePackagePostgresConnections._snapshotForGauges()` (`:280-285`) reads `_openConnections.length` |
| `runtime_gauges.postgres_pool.idle_count` | same | same | reads `_idle.length` |
| `runtime_gauges.postgres_pool.waiter_count` | same | same | reads `_waiters.length` |
| `runtime_gauges.postgres_pool.max_connection_count` | same | same | reads `maxConnectionCount` ctor arg |
| `runtime_gauges.pubsub_subscriber.ring_buffer_keys` | `GoogleCloudPubsubSubscriber.ringBufferKeyCount` | `tool/advisor_proxy/main.dart:639-640` | reads `_ringBuffers.length` from the subscriber |

The gauge surfacing path is `ProxyRuntimeGauges.snapshotJson()` at
`tool/advisor_proxy/advisor_proxy.dart:3684-3718`. Each gauge is
independently null-tolerant — a single collector throw never tips
`/health` to 5xx.

The deep-health envelope ALSO carries platform-wide metrics via the
producer registry (`tool/advisor_proxy/health_producers/`):
- `audit_chain_lag_seconds` (`audit_producers.dart:22-59`) — yellow 30
  min, red 6 h.
- `audit_chain_anchor_age_seconds` (`audit_producers.dart:74-110`) —
  yellow 24 h, red 48 h.
- (~25 other producers per `producer_registry.dart`).

### 5.2 Gauge additions the durable kit needs

These are **proposals**, not shipped. The R3 §3 quick-wins shipped 2
of 3 (pool + ring buffer); the third (fd watcher) plus three
soak-specific producers are durable-kit work.

| Gauge | Source | Computation | Alerting threshold | Status |
|---|---|---|---|---|
| `runtime_gauges.process.fd_count` | `/proc/self/fd` directory entry count (R3 §3 Pattern D) | `Directory('/proc/self/fd').listSync().length` from inside `ProxyRuntimeGauges` ctor closure; sampled at deep-health time | yellow at 70% of cgroup limit, red at 90% (Cloud Run fd limit is ~10% of memory by default) | **NOT SHIPPED** — propose adding alongside the two existing closures at `tool/advisor_proxy/main.dart:631-641` |
| `runtime_gauges.session_record_incomplete_count` | counter incremented by the proxy at `/v1/auth/session/login` 200 emit path when `assertComplete` returns `complete == false` | atomic int in `ProxyRuntimeGauges`; reset on read or kept monotonic | red on any non-zero value | **NOT SHIPPED** — depends on R3 §2 stretch item (in-proxy assertion). Slice 3 in Section 10 |
| `runtime_gauges.root_zone_uncaught_count` | counter incremented inside the `runZonedGuarded` uncaught handler at `tool/advisor_proxy/main.dart:104-128` | atomic int; reset on /health read or kept monotonic | red on any non-zero | **NOT SHIPPED** — proposed in Section 10 Slice 2 |
| `runtime_gauges.pubsub_subscriber.ring_buffer_total_bytes` | `GoogleCloudPubsubSubscriber._ringBuffers` sum of `events.length * average_event_bytes` | new getter on `GoogleCloudPubsubSubscriber` | yellow at 50 MB, red at 200 MB | **NOT SHIPPED** — A1 §2.4 also recommended this; out of B1+B2 scope. Slice 5 |
| `runtime_gauges.realtime_subscriptions_active_count` | counter in `InProcessRealtimePublisher` at `tool/advisor_proxy/realtime_route.dart:288-308`, increments on `subscribe`, decrements on cancel | new atomic int | yellow at 5000, red at 20000 (per-pod) | **NOT SHIPPED** — A1 §2.1 S4 recommendation. Slice 5 |

The audit-anchor lag gauges are **already wired** as `audit_chain_lag_seconds`
+ `audit_chain_anchor_age_seconds` producers — the kit just needs the
soak harness to read `/v1/health/deep` periodically and surface the
lag value in the summary MD when it crosses yellow (Slice 3).

### 5.3 Why these specific gauges (vs. the long R3 list)

R3 §3 enumerates five forensic patterns. Pattern A (Dart VM Service)
and Pattern B (heap snapshot to GCS) are diagnostic-heavy with
multi-day implementation costs. Pattern C (`package:leak_tracker`) is
harness-side only and doesn't need a `/health` surface.

The durable kit's gauge picks are the **observable** signals — counts
and ages that the soak harness checks on every checkpoint and that
operators can watch in production. Diagnostic-only forensics (heap
snapshot, leak tracker) stay in Section 10 Slice 4 as a separate
slice with a separate audit gate.

---

## Section 6 — CI Integration

### 6.1 Cadence picks

The kit runs at three tiers. Each tier serves a different question.

**Tier 1 — PR-time (every PR)**: structural-only test.

- File: `test/pressure/p4_session_record_predicate_test.dart` — runs
  unconditionally on every PR via the existing `flutter test`
  invocation. Already shipped. Pure unit tests — no network.
- **Proposed addition** — runner-style test that asserts the harness
  binary parses CLI flags without crashing (cf. `p3a_webhook_flood_runner_test.dart:38-53`
  pattern). Cheap structural check — does not exercise the network.
- **Red trigger**: any predicate unit test failure OR harness fails
  to parse its CLI flags.

**Tier 2 — Nightly soak (scheduled cron)**: smoke run against preview.

- Both `p4_*` harnesses run via the env-flag pattern from `p3a_webhook_flood_runner_test.dart:12-15`:
  `FF_RUN_PRESSURE_PREVIEW_P4_SESSION_SOAK=1` /
  `FF_RUN_PRESSURE_PREVIEW_P4_OPERATOR_DAY_SOAK=1`.
- Knobs: `--ops=20 --concurrency=10 --duration=10min` per lane.
- Runs against the preview Cloud Run revision, NOT Production1.
  Preview-URL guard at `isSoakProxyUrlAllowed` provides belt-and-suspenders.
- **Red trigger**: exit code 3 (any incomplete session record) on
  either lane.

**Tier 3 — Weekly full-scale soak**: multi-hour run.

- Knobs: `--ops=100 --concurrency=20 --duration=2h` per lane.
- Run alongside an alert on the `/v1/health/deep` `runtime_gauges`
  envelope — if `postgres_pool.waiter_count` > 50% of
  `max_connection_count` for >5 minutes, OR `pubsub_subscriber.ring_buffer_keys`
  grows monotonically over the run, OR `root_zone_uncaught_count` >
  0, the run is red.
- **Red trigger**: exit code 3 OR any of the three gauge thresholds.

### 6.2 Why this tiered shape (not "run on every PR")

The harnesses count against staging-Postgres connection budget
(per `test/pressure/README.md:7-9` and the bounded-run
discipline at `:33-46`). Running them on every PR would burn quota
that operators need for actual feature staging work. The
structural-only Tier 1 check catches the common regressions (broken
predicate, broken CLI parsing) without network cost; the smoke and
soak tiers stay scheduled / on-demand.

### 6.3 Flake mitigation

- **Smoke duration cap** — Tier 2 hard-caps at 10 min wall-clock.
  Beyond that, the run kills itself and reports `duration_cap_reached`
  as a non-failure finding.
- **Network-error tolerance** — `_RequestRecord.errorKind == 'network_error'`
  is recorded but does NOT trigger exit code 3 unless rate > 5% of
  total requests (proposed threshold; current code records but doesn't
  fail on network errors at all, which is right for staging — staging
  Postgres can blip).
- **Random salt per run** — `runSalt =
  DateTime.now().toUtc().toIso8601String()` (`p4_session_soak.dart:417-420`)
  prevents cross-run synthetic-tenant collisions.
- **SIGINT-clean shutdown** — Tier 3 runs that catch a deploy in
  flight can be killed mid-run without polluting subsequent runs;
  the in-flight requests drain via `SoakShutdownSignal`.

### 6.4 What "red" means (the verdict tree)

```
exit code 0  → green; no incomplete records, no fatal errors
exit code 2  → red; preview-URL guard failed (operator config bug)
exit code 3  → red; ≥1 incomplete session record observed (Bug A class)
non-zero exit → red; harness crashed (Bug B class; investigate root-zone log)
```

For Tier 3 the gauge-threshold reds are additive (the run can exit
0 but still be red because the operator-facing dashboard tripped).

---

## Section 7 — Local Developer Setup

### 7.1 From a clean clone to first smoke run

Prerequisites (assumed already on a dev machine):
- Dart SDK ≥ 3.4 (verify with `dart --version`).
- Flutter SDK (for `flutter test`-based smoke runners).
- Local Postgres reachable at `localhost:5432` if running the proxy
  locally — OR access to the preview Cloud Run URL.

Steps:

1. **Install hooks** — `scripts/install_git_hooks.ps1` (or `.sh`).
   Cheap guardrails; do not run graphify.
2. **Start the proxy locally** (optional if hitting preview):
   ```
   $env:POSTGRES_URL = "postgres://forge_flow@localhost:5432/forge_flow_dev"
   dart run tool/advisor_proxy/main.dart
   ```
   Proxy comes up on `localhost:8080` by default. The `/v1/health/deep`
   endpoint comes online once Postgres connects.
3. **Smoke the predicate** (no network needed):
   ```
   flutter test test/pressure/p4_session_record_predicate_test.dart
   ```
   Should pass all 12 tests in <5 s.
4. **Smoke the session soak harness**:
   ```
   dart run tool/pressure/p4_session_soak.dart `
     --ops=2 --concurrency=2 --duration=30s `
     --proxy-url=http://localhost:8080
   ```
   Expected output: ~60 request records, all 401 (placeholder JWTs),
   exit code 0 (no 200s, so no incomplete-record findings possible).
5. **Smoke the operator-day soak harness**:
   ```
   dart run tool/pressure/p4_operator_day_soak.dart `
     --ops=2 --concurrency=2 --duration=30s `
     --proxy-url=http://localhost:8080
   ```
   Same shape. The skip-on-non-200 guard means only the `sign_in` step
   fires per loop. Exit code 0.

### 7.2 Required setup (none beyond Dart + Flutter)

The kit has **zero new dependencies**:
- No Docker compose recipe needed — the harnesses are pure Dart
  binaries that POST HTTP to a URL.
- No Redis / Memcached — proxy bootstrap doesn't require them.
- No Cloud Tasks emulator — the realtime publisher is in-process by
  default; Cloud Pub/Sub is opt-in via `PUBSUB_REALTIME_ENABLED`.
- No special env vars to read findings — JSONL output writes to
  `test/pressure/` (gitignored).

### 7.3 Inspecting `/health` runtime gauges locally

While a soak is running:
```
curl http://localhost:8080/v1/health/deep | jq '.runtime_gauges'
```
Expected shape:
```json
{
  "postgres_pool": {
    "open_connection_count": 4,
    "idle_count": 1,
    "waiter_count": 0,
    "max_connection_count": 4
  }
}
```
The `pubsub_subscriber.ring_buffer_keys` field appears only when
`PUBSUB_REALTIME_ENABLED=true`.

### 7.4 Inspecting findings post-run

Three files per harness invocation:
- `test/pressure/<lane>_raw.jsonl` — per-request JSONL.
- `test/pressure/<lane>_findings.jsonl` — per-finding JSONL.
  Empty file = clean run.
- `test/pressure/<lane>_summary.md` — Markdown summary table.

`jq` examples:
```
# All findings of a category
jq 'select(.category == "incomplete_session_record")' \
  test/pressure/p4_session_soak_findings.jsonl

# Distribution of HTTP statuses
jq -r '.status_code' test/pressure/p4_session_soak_raw.jsonl \
  | sort | uniq -c
```

---

## Section 8 — Failure Mode Taxonomy

The durable kit detects six failure categories. Each maps to a
specific assert site so triage doesn't need to re-derive the mapping.

| # | Failure category | Assert site (file:line) | Likely root cause | Exit code | Finding category |
|---|---|---|---|---|---|
| 1 | Incomplete session record (tenant-scoped) | `p4_session_record_predicate.dart:93-95` → `p4_session_soak.dart:336-340` | Proxy stripped `operator_id` or `location_id` from a tenant-scoped 200 (Bug A H1 inverted — partial body when it shouldn't be) | 3 | `incomplete_session_record` with `missing_fields: [...]` |
| 2 | Incomplete session record (global-admin) | `p4_session_record_predicate.dart:86-91` → `p4_session_soak.dart:336-340` | Proxy emitted a non-empty `operator_id` for `ff_support` / `super_admin` (contract violation; would mean global-admin got auto-pinned to a tenant without going through impersonation) | 3 | `incomplete_session_record` with `unexpected_fields: [...]` |
| 3 | Multi-step flow integrity break | `p4_operator_day_soak.dart:436-492` | Future refactor removed the "skip downstream on non-200" guard; harness amplifies garbage traffic on broken auth | (none today) | **Proposed** — `multi_step_amplification` finding when downstream step rate > 0% while `sign_in` 200 rate is 0%; Slice 3 in Section 10 |
| 4 | Postgres pool saturation under load | `tool/advisor_proxy/advisor_proxy.dart:3686-3700` (gauge collection) + soak harness reads `/health` | Pool max too low; per-request hold too long; advisory-lock contention | (gauge-driven, not harness-driven today) | **Proposed** — `pool_saturation` finding when `waiter_count / max_connection_count > 0.5` for 5+ checkpoints in a row |
| 5 | Pubsub ring-buffer unbounded growth | `tool/advisor_proxy/advisor_proxy.dart:3702-3717` (gauge collection) + soak harness reads `/health` | A1 §2.1 S3 — operator-topic keys never evicted; per-pod RSS climbs monotonically | (gauge-driven) | **Proposed** — `ring_buffer_growth` finding when `ring_buffer_keys` increases monotonically across all checkpoints in a 30+ minute run |
| 6 | Root-zone uncaught (proxy crash) | `tool/advisor_proxy/main.dart:104-128` (runZonedGuarded handler) → emits `proxy.root_zone_uncaught` log | A1 §2.1 S1 — unhandled async error escapes a request scope (Bug B class) | (today: harness sees connection-refused on next request; reported as `network_error`. Slice 3 surfaces it explicitly via `root_zone_uncaught_count` gauge.) | **Proposed** — `root_zone_uncaught` finding when the gauge transitions from 0 to non-zero during the run |

**Note on harness vs production semantics**: the kit's exit codes
(today: 0/2/3) cover Bug A directly. Bug B is currently surfaced
indirectly through network errors and runtime-gauge thresholds; the
explicit `root_zone_uncaught_count` gauge in Slice 3 closes that
gap so Bug B becomes a first-class assert site.

---

## Section 9 — Extension Contract for Future `p5+`

This section is the binding instruction for the next engineer who
adds a soak lane. Copy it into the README appendix when Slice 5
lands.

### 9.1 Naming convention

- Pressure lanes live in `tool/pressure/`.
- Filename: `p<phase><lane-letter>_<short_purpose>.dart`.
  - `p3a`, `p3b`, `p3c` — Pressure-Preview-v1 phase (3 lanes).
  - `p4_*` — Post-Codex addendum B2 (2 lanes + shared predicate).
  - **`p5_*`** — next phase. Reserve `p5a`, `p5b`, etc. when adding
    multiple lanes in one phase; use plain `p5_<purpose>` for a single
    lane.
- Shared helpers (predicate / shutdown signal / finding type) live
  alongside as `p<phase>_<helper_name>.dart`. The B2 slice put them
  in `p4_session_record_predicate.dart`; future shared helpers should
  follow the same shape.

### 9.2 Required structure

Every `p<phase>_<lane>.dart` MUST include:

1. **Header comment block** — sprint + phase + slice doc reference,
   what the lane proves, what it does NOT prove (gap acknowledgment),
   output paths, hard rules, usage examples. Pattern lives at
   `p3a_webhook_flood.dart:1-87`.
2. **Preview-URL guard** — call `isSoakProxyUrlAllowed(opts.proxyUrl)`
   from `p4_session_record_predicate.dart:182-184`, exit code 2 on
   failure. **Do not** add a new allow-list; reuse the shared one.
3. **CLI parser** — same flag shape: `--proxy-url=`, `--ops=`,
   `--concurrency=`, `--duration=`. Use `parseSoakDurationSeconds`
   from the shared helper. Lane-specific flags get a name prefix
   (`--vendor-mix=`, `--ttl-dist=`, etc.) — see `p3c` for precedent.
4. **Synthetic identifiers** — deterministic UUID via the
   `_deterministicUuid` pattern at `p4_session_soak.dart:174-190`.
   Per-run salt from `DateTime.now().toUtc().toIso8601String()`.
5. **Placeholder credentials** — `alg: none` JWTs OR
   `PLACEHOLDER-PRESSURE-PREVIEW-V1`-prefixed secrets. NEVER use a
   real key, even a test key.
6. **`SoakShutdownSignal`** — wire SIGINT cleanly. Workers check
   `shutdown.isFired` between iterations.
7. **`SoakFinding` records** — use the shared type for any
   harness-detected anomaly. The fields are `category`, `detail`,
   `evidence` (free-form `Map<String, Object?>`).
8. **Output triplet**:
   - `<lane_name>_raw.jsonl` — per-request records.
   - `<lane_name>_findings.jsonl` — `SoakFinding`s, one per line.
   - `<lane_name>_summary.md` — Markdown summary with totals + finding
     count.
9. **Exit codes**:
   - 0 — clean run.
   - 2 — preview-URL guard failure.
   - 3 — at least one finding of a configured-fatal category.
   - Other non-zero — harness crash (root-zone uncaught).
10. **30-second checkpoints** — periodic `[checkpoint @ ts] n=… key=…`
    line so long runs surface drift mid-run.

### 9.3 Required tests

For every new `p5_*` lane:

1. **Predicate unit tests** (if the lane introduces a new predicate)
   — under `test/pressure/p5_<name>_predicate_test.dart`. Pattern at
   `test/pressure/p4_session_record_predicate_test.dart`.
2. **Runner test** — under `test/pressure/p5_<lane>_runner_test.dart`.
   Pattern at `test/pressure/p3a_webhook_flood_runner_test.dart`.
   Two test groups:
   - Structural — `harness binary parses CLI without crashing`,
     unconditional, asserts the file exists and declares `main` +
     uses the shared allow-list constant.
   - Smoke — gated by `FF_RUN_PRESSURE_PREVIEW_P5_<NAME>=1`. Runs the
     harness at a 30-second smoke scale; asserts exit code 0 + both
     JSONL files exist.

### 9.4 Required docs

- Append a row to the Five Load Lanes table at
  `test/pressure/README.md:17-23`.
- Append a "Phase 5 — ..." section to the same README mirroring the
  "Phase 4 — B2 hot-fix lanes" section at `:64-91`.
- If the lane introduces a new failure category, add a row to
  Section 8 of this audit (the durable kit doc).
- If the lane changes the `/health` envelope, add a row to Section
  5.2 of this audit.

### 9.5 Reviewer expectations (what the audit/review checks)

- The lane respects every rule in Section 9.2 above.
- The 30-second checkpoint cadence is honored.
- The finding shape matches `SoakFinding.toJson()` byte-for-byte.
- The runner test runs in <30s smoke; runs in <2h full-scale.
- If the lane writes to staging Postgres (writes that aren't rejected
  by signature verification), tearDown removes synthetic rows.
- No new dependency added to `pubspec.yaml` unless the lane absolutely
  needs it (k6, leak_tracker, postgresql client) — and even then, get
  operator sign-off first.

### 9.6 What `p5_*` MUST NOT do

- Add a fourth call site to `SessionRecordCompleteness.assertComplete`
  without operator sign-off (Section 4.4 contract).
- Bypass the preview-URL guard. The guard is the single defense
  against accidental Production1 hits.
- Run against Production1 directly. Even a "I'll be careful" run
  is forbidden — the guard refuses.
- Auto-retry on failure. The harnesses exit non-zero on the first
  finding so the operator sees it.
- Write to repository-tracked paths other than the three output
  files. The output dir is gitignored; reviewers should never see a
  PR that touches `test/pressure/*.jsonl`.

---

## Section 10 — Execution Slices

Sequencing for the durable kit work. Slice 1 (the B1+B2 hot-fix) has
already landed via PR #476. The remaining slices are the durable-kit
follow-ups.

### Slice 1 — `LANDED 2026-05-12` — B1+B2 hot-fix

PR #476 (commits `c3f1ce0d` + `fc1a3f80` + `e26e53af`).

Already shipped:
- `tool/pressure/p4_session_soak.dart` (611 LOC).
- `tool/pressure/p4_operator_day_soak.dart` (596 LOC).
- `tool/pressure/p4_session_record_predicate.dart` (195 LOC).
- `test/pressure/p4_session_record_predicate_test.dart` (192 LOC).
- `runZonedGuarded` wrap of `tool/advisor_proxy/main.dart:84-130`.
- `ProxyRuntimeGauges` at `tool/advisor_proxy/advisor_proxy.dart:3669-3719`.
- Pool gauge surfacing via `PackagePostgresPool.gaugeSnapshot`.
- Pubsub ring-buffer key gauge.
- Six instrumentation log lines per A1 §1.5 / §2.4.

### Slice 2 — Root-zone uncaught counter gauge (~0.5 day)

**Why**: Today the runZonedGuarded handler at `tool/advisor_proxy/main.dart:104-128`
logs `proxy.root_zone_uncaught` but doesn't increment a gauge. Soak
harness can't distinguish "no crashes" from "log line we missed in
grep." A counter gauge closes the gap.

**Scope**:
- Add `rootZoneUncaughtCounter` to `ProxyRuntimeGauges`
  (`tool/advisor_proxy/advisor_proxy.dart:3669-3719`). Atomic int,
  monotonic.
- Increment inside the `runZonedGuarded` handler at
  `tool/advisor_proxy/main.dart:104-128`.
- Surface in `snapshotJson()` as
  `runtime_gauges.process.root_zone_uncaught_count`.
- Soak harness checkpoint reads the counter; flags
  `root_zone_uncaught` finding (category) on any non-zero value.

**Tests**: unit test for the increment; predicate-style runner test
that flips the gauge to 1 and asserts the harness emits the finding.

### Slice 3 — Production `proxy.session_record.incomplete` counter (~1 day)

**Why**: R3 §2 recommendation #3 / R3 §2.4 production-defense pattern.
Today the predicate runs in soak; if the bug recurs in production
between soak runs (e.g., on a hot-path the soak doesn't exercise),
operators don't see it until a user reports it.

**Scope**:
- Add an in-proxy assertion at the `/v1/auth/session/login` 200
  emit path (`tool/advisor_proxy/advisor_proxy.dart:12430-12437`):
  call `SessionRecordCompleteness.assertComplete` on the response
  body before emitting.
- Increment a per-route counter on each `complete == false`. Emit
  via `runtime_gauges.proxy.session_record_incomplete_count{route, missing_field}`.
- The assertion does NOT fail-closed in v1 — it logs +
  increments and proceeds. Fail-closed is a separate operator
  decision (R3 §2 "stretch").

**Tests**: contract test that asserts a forced partial body
increments the gauge by 1 without changing the response status.

### Slice 4 — Forensic kit (fd watcher + heap-snapshot trigger) (~2.5 days)

**Why**: R3 §3 Patterns D + B. The fd watcher is the cheap one (0.5
day; ~10 lines of Dart reading `/proc/self/fd`); the heap-snapshot
trigger is the expensive one (2 days; encoding + GCS upload). Both
unlock Bug B forensics. Land together to give the kit a complete
forensic trail.

**Scope**:
- Add `fdCountGauge` to `ProxyRuntimeGauges`; surface as
  `runtime_gauges.process.fd_count`.
- Add heap-snapshot threshold trigger: when RSS exceeds 80% of the
  Cloud Run limit, call `developer.NativeRuntime.writeHeapSnapshotToFile()`
  and upload to GCS via `package:googleapis_auth`. Authorized by
  Cloud Run SA permission to a known bucket.
- Soak harness reads both gauges; flags `fd_growth` finding on
  monotonic increase over 30+ checkpoints.

**Tests**: producer test for the fd gauge; mocked snapshot trigger
test that asserts the threshold fires once and only once.

### Slice 5 — Subscription + ring-buffer-bytes gauges (~1 day)

**Why**: A1 §2.1 S4 (WebSocket subscription accumulation) + A1 §2.1
S3 supplementary (ring-buffer total bytes, not just keys). Both
catch the slow-leak shape that key-count alone misses.

**Scope**:
- Add `realtime_subscriptions_active_count` counter via
  `InProcessRealtimePublisher` subscribe/cancel sites at
  `tool/advisor_proxy/realtime_route.dart:288-308` / `:409, :418`.
- Add `ring_buffer_total_bytes` getter on `GoogleCloudPubsubSubscriber`
  at `lib/services/realtime/google_cloud_pubsub_subscriber.dart:186`.
  Compute as `sum(events.length * average_event_bytes)` across all
  ring entries; average updated on push.
- Surface both via `ProxyRuntimeGauges.snapshotJson()`.

**Tests**: increment/decrement parity test for the subscription
counter; ring-buffer-bytes test against a synthetic stream.

### Sequencing

Slice 2 → Slice 3 → Slice 4 → Slice 5. Slices 2/3 are required for
the durable kit's failure-mode taxonomy (Section 8 rows 6 + 1-2 in
production). Slices 4/5 add forensic depth and can be tabled until
post-launch if the wave plan needs to focus.

Total durable-kit follow-up effort: ~5 days, all out-of-scope for the
current B1+B2 slice that's already merged.

---

## Section 11 — What Was NOT Audited

Explicit boundary so reviewers know where the next audit starts.

- **A4 (Performance / perf budgets)** owns latency p95/p99 targets,
  throughput ceilings, and request-size budgets. The durable kit
  records latencies in `_RequestRecord.latencyMs` but does NOT
  assert against perf thresholds. If a soak run shows p95 climbing,
  that's an A4 audit input, not a durable-kit failure.
- **A1 (Proxy bug root-cause)** owns the Bug A / Bug B hypotheses.
  The durable kit consumes those hypotheses as failure modes; it does
  not re-investigate them. Any new bug class needs an A1-style root-
  cause audit first, then a Section 8 entry here.
- **Lane B (proxy split + new routes)** owns proxy-internal
  architecture changes. The durable kit doesn't propose new routes;
  it consumes whatever the proxy exposes via `/v1/auth/session/login`
  + `/v1/health/deep`. New routes need their own pressure shape (see
  Section 9 extension contract).
- **C (Email pipeline)** owns email-failure regression nets. The
  durable kit doesn't cover email scenarios; that's `c_email_notification_scenario_inventory.md`'s
  job.
- **Real-browser E2E (Browser Use / Codex workflow)** runs out of
  this repo per `runbooks/browser_use_codex_acceptance_workflow.md`.
  The durable kit is HTTP-shape only.
- **Production canaries** (Grafana Cloud Synthetic Monitoring) are an
  R3 §6 future item; the durable kit is staging/preview only by the
  hard preview-URL guard.
- **OAuth refresh storm extensions (R3 §4)** — `--ttl-dist`,
  `--vendor-mix`, `--jitter`, mock-vendor fault injection. These live
  in `p3c` and would extend it; they don't belong in `p4_*` and were
  out of scope for this kit.
- **OpenAPI / Schemathesis** — R3 §6 future item, ~1 week implementation
  effort, untouched here.
- **Permission editor + role catalog soak** — when the Trust & Account
  Control track (C1) lands, it will need its own pressure shape (role
  cascade resolution under N concurrent role-edit sessions). That's
  `p5_*` work per Section 9, not `p4_*`.

Hard Promise #2 (demo mode is writer-side switch only) is honored by
the kit: the harnesses run against the same proxy endpoints in demo
or live; no `kDemoMode` branching exists in any `p4_*` file (verified
by inspection of the three p4 files in Section 2.1).

---

## Appendix — Key file:line citations (for next-engineer ergonomics)

- Preview-URL guard: `tool/pressure/p4_session_record_predicate.dart:175-184`.
- Shared shutdown signal: `tool/pressure/p4_session_record_predicate.dart:186-194`.
- Predicate entry point: `tool/pressure/p4_session_record_predicate.dart:70-103`.
- Global-admin role set: `tool/pressure/p4_session_record_predicate.dart:57-60`.
- Predicate tests: `test/pressure/p4_session_record_predicate_test.dart:1-192`.
- Pool gauge struct: `lib/infrastructure/persistence/postgres/package_postgres_executor.dart:58-77`.
- Pool gauge accessor: `lib/infrastructure/persistence/postgres/package_postgres_executor.dart:140-144`.
- `ProxyRuntimeGauges` holder: `tool/advisor_proxy/advisor_proxy.dart:3669-3726`.
- Runtime gauges wiring (production): `tool/advisor_proxy/main.dart:620-641`.
- Deep-health envelope (gauge emission): `tool/advisor_proxy/advisor_proxy.dart:8659-8711`.
- `runZonedGuarded` wrap: `tool/advisor_proxy/main.dart:84-130`.
- Audit chain lag producer: `tool/advisor_proxy/health_producers/audit_producers.dart:22-59`.
- Audit chain anchor age producer: `tool/advisor_proxy/health_producers/audit_producers.dart:74-110`.
- `requireOperatorContext` (B1 proxy contract): `tool/advisor_proxy/advisor_proxy.dart:2168-2266`.
- Session login route: `tool/advisor_proxy/advisor_proxy.dart:12174-12437`.
- Client-side parser (the three-mirror discipline anchor): `lib/services/auth/proxy_auth_session_ledger_writer.dart:373-425`.
- Lane README: `test/pressure/README.md:1-101`.

End of audit.
