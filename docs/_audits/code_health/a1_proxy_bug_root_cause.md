# A1 — Proxy Bug Root-Cause Investigation

Investigation only. Two production-observed bugs in `tool/advisor_proxy/`.
No fixes proposed beyond instrumentation/repros. All citations use
`file:line` shape; line numbers are from the worktree at
`nifty-clarke-d3ec25` (2026-05-12).

Context read: `docs/POST_HARDENING_FOLLOWUPS.md` (P0/P1/P2 open items),
`debug.md` (operator wishlist; no proxy-crash item). The decision doc
`docs/_decisions/post_codex_wave_decisions_2026-05-12.md` does not exist
yet — investigation proceeds from symptom + code.

---

## Bug 1 — "Proxy returned incomplete session record on sign-in after support-check"

### 1.1 Code path (server side)

**Sign-in route:** `tool/advisor_proxy/advisor_proxy.dart:12174`
(`POST /v1/auth/session/login`). Success path (after the
`failure_outcome` short-circuit):

1. Writer null-check → 503 `auth_session_ledger_not_configured`
   (`12305-12312`).
2. **JWT verification + scope guard** —
   `authGuard.requireOperatorContext(...)` (`12316`). Throws
   `ProxyAuthError` on missing/invalid bearer, verifier failure, or
   missing `operator_id` / `location_id`. Caught at `12321`, written
   as `{error: ...}` with status code.
3. `tokenHash` body check → 400 (`12328-12335`).
4. Pre-success lockout (`12341-12379`) → 423 `account_locked`.
5. `authSessionLedgerWriter.recordLogin(...)` at `12383`. Bare
   `catch (_)` at `12392` swallows ALL errors → 503
   `auth_session_ledger_unavailable`.
6. Lockout-success record (`12410-12428`, bare `catch (_)` at `12421`).
7. **Final 200 response:** `{session_id, user_id, operator_id,
   location_id}` (`12430-12437`).

The JWT verifier (`FirebaseProxyJwtVerifier.verify`,
`advisor_proxy.dart:1862-1967`) builds `ProxyJwtClaims` with
**nullable** `operatorId` / `locationId` (`1957-1958`). Roles come
from `_resolveRoles` (`2032-2050`); `super_admin` / `ff_support`
surface from JWT booleans `is_super_admin` / `is_ff_support`.

`requireOperatorContext` (`2157-2193`) refuses scope-less claims with
**403** at `2166-2174`. Roles do NOT bypass this check.

**Client-side asymmetry:** `lib/services/auth/firebase_auth_login_service.dart:203-228`
— when `operator_id` is null AND the user has `super_admin` /
`ff_support`, the client **allows** the missing id (defaults to `''`)
and **skips** the location resolver (`locationId = ''`).

Then `recordLoginAndResolveScope` POSTs to the proxy
(`auth_session_notifier.dart:299-307`). The response parser
(`proxy_auth_session_ledger_writer.dart:373-400`) requires non-blank
`session_id` + `user_id` + `operator_id` + `location_id`; missing any
throws `'malformed_response': 'returned incomplete scope'`. The
notifier maps the throw to `AuthLoginFailure(code:
'ledger_unavailable', ...)` (`auth_session_notifier.dart:344-347`).

So "**incomplete session record**" maps to: proxy returns
`/v1/auth/session/login` 200 missing a field (rare — the success path
always emits all 4), OR proxy returns 4xx and the client maps the
error body the same way.

### 1.2 Where "support-check" enters the path

Support flags (`is_super_admin` / `is_ff_support`) are projected by
`users_repository.dart:915-993` (`firebaseCustomClaimsForUser`) from
`user_roles` + `operator_admins`. `toCustomClaims`
(`users_repository.dart:236-246`) **omits false flags** to keep the JWT
under 200 bytes.

Callers — only role/team mutations:
`repository_auth_operations_gateway.dart:453` (invite create) and
`:1276` (`_refreshTargetClaims` for grant create/revoke). **No
sign-in-time server call refreshes claims.**

So "support-check on sign-in" is the **client-side branch** at
`firebase_auth_login_service.dart:203-228` reading flags ALREADY in
the JWT.

### 1.3 Candidate "missing field" sources, ranked by likelihood

#### H1 (HIGH) — F&F support / super-admin user signs in with no `operator_id` / `location_id` in their JWT; client tolerates it, proxy doesn't

**Evidence — asymmetric client/server contract:**

- `lib/services/auth/firebase_auth_login_service.dart:203-228` —
  client accepts `operatorId == null` for `_hasGlobalReadRole(roles)`
  callers, sets `locationId = ''` (NOT calling the resolver), and
  builds an `AuthSession` with empty strings.
- `lib/state/auth_session_notifier.dart:299-307` then POSTs
  `recordLoginAndResolveScope` carrying those empty strings.
- Proxy `FirebaseProxyJwtVerifier.verify`
  (`advisor_proxy.dart:1862-1967`) — `operator_id` / `location_id` are
  null on `ProxyJwtClaims`.
- `requireOperatorContext` (`advisor_proxy.dart:2166-2174`) returns
  **403** "verified token is missing operator or location scope".
- Client's `_postLogin`
  (`proxy_auth_session_ledger_writer.dart:362-371`) raises
  `ProxyAuthSessionLedgerError(code: <error>, statusCode: 403)`.
  `_recordFromLoginResponse:387-393` is never reached — the
  "incomplete scope" string surfaces from the proxy error mapping,
  not from a literal partial body — and the notifier
  (`auth_session_notifier.dart:334-347`) surfaces
  `AuthLoginFailure(code: 'ledger_unavailable', ...)`.

A support user attached only via `operator_admins.scope_type =
'ff_support'` / `'super_admin'` for the PLATFORM (no per-operator
scope) would mint a JWT with `is_ff_support: true` and no
`operator_id` — and hit exactly this path right after the support-flag
resolution.

**To confirm:**

- Log the verified `userId` + role flags at the 403 branch
  (`advisor_proxy.dart:2170-2173`).
- Match a failing user_id to its `auth_session_ledger_unavailable`
  client log.
- Reproduce: mint a Firebase test ID token with `is_ff_support: true`
  and no `operator_id` / `location_id`; expect proxy 403 → notifier
  `ledger_unavailable`.

#### H2 (MEDIUM) — `findSelfProfile` projects a malformed row → `/v1/auth/account` returns 503; the UI side of the "session record" (account/permissions snapshot) renders empty

**Evidence:**

- `users_repository.dart:1310-1320` throws `StateError('self profile
  lookup returned a malformed row')` if any of `display_name`,
  `email`, `status`, `locationLabel`, or `mfaEnabled` is null or
  wrong type.
- SQL fallbacks (`users_repository.dart:393, 388-394`) cover most
  cases; the remaining null window is `u.email` empty, `u.status`
  empty, or the `mfa_enabled` subquery returning a non-bool.
- `advisor_proxy.dart:9354-9358` — `/v1/auth/account` route catches
  the `StateError` via a bare `catch (_)` and returns 503
  `account_info_unavailable`. Flutter
  (`proxy_account_info_gateway.dart:68-84`) raises
  `ProxyAccountInfoError` and the Account tab shows blanks.

If "session record" was a UI-observable description (account/role
labels missing right after sign-in), the underlying surface is the
`/v1/auth/account` 503 path — not the `/v1/auth/session/login` 200
body.

**To confirm:** log the `findSelfProfile` row pre-projection (temp,
PII-aware); check if the failing operators have NULL `u.email` /
empty `u.status` (invited-user write paths that failed mid-write
could produce this).

#### H3 (MEDIUM-LOW) — Bare `catch (_)` at `advisor_proxy.dart:12392` silently maps any throw type from `recordLogin` to 503, hiding the real root cause

The catch sits around `recordLogin` only — no body leak past this
seam. But the pattern (also `12421`) matches
`POST_HARDENING_FOLLOWUPS.md:430-439` (16 sites). Unlikely to be the
root cause; high concealment cost for diagnosing the actual cause.

**To confirm:** widen the catch to typed arms with `error.runtimeType`
+ first stack frame, then re-observe.

#### H4 (LOW) — `_validateLoginScopeEcho` mismatch (sub-symptom of H1)

Client validates echoed scope matches submitted scope
(`proxy_auth_session_ledger_writer.dart:402-425`). The only practical
mismatch path is H1's empty-string-vs-real-id mismatch when the
support user actually had ONE id in their JWT but not the other. Surface
code: `scope_mismatch`. Watch for it co-occurring with
`ledger_unavailable` in client logs.

#### H5 (LOW) — `permission_version` JWT claim mismatch (forward-looking)

`users_repository.dart:1409-1411` coerces null → 0 server-side, so
legacy tokens without the claim are fine today. The migration
`202605080800_auth_permission_version.sql`
(`POST_HARDENING_FOLLOWUPS.md:65`) is pending Production1 apply; once
the proxy middleware comparator wires in, legacy tokens may 401 and
the client maps the same way.

### 1.4 Ranked hypotheses summary

| Rank | Hypothesis | Evidence strength | Confirming signal |
|---|---|---|---|
| H1 | F&F support user with no `operator_id` JWT → client builds blank session, proxy 403s | High | `requireOperatorContext` 403 + `ledger_unavailable` on the same user_id |
| H2 | `findSelfProfile` row malformed → `/v1/auth/account` 503 | Medium | `StateError('self profile lookup returned a malformed row')` in proxy logs |
| H3 | Bare `catch (_)` at `advisor_proxy.dart:12392` hides the real failure | Medium-Low | Any non-503 error type observed if catch is widened |
| H4 | `_validateLoginScopeEcho` mismatch (sub-symptom of H1) | Low | `code: 'scope_mismatch'` in client logs |
| H5 | `permission_version` claim mismatch (pending migration) | Low | 401 with the migration applied |

### 1.5 Bug 1 — Recommended next steps (instrumentation only)

1. Add structured log at `advisor_proxy.dart:2170-2173` capturing
   `userId`, `roles`, and presence-flags of operator_id /
   location_id whenever 403 fires. Cardinality is one per failed
   sign-in for a support user — bounded.
2. Add `firstStackFrame` + `error.runtimeType` log lines to the bare
   catches at `advisor_proxy.dart:12392` and `12421` (see
   `POST_HARDENING_FOLLOWUPS.md` P2 line `430`). Do NOT widen scope.
3. Capture client-side at `auth_session_notifier.dart:309` to log
   `error.runtimeType` plus the AuthSession's `operatorId` /
   `locationId` (already empty? prefilled?).
4. Run a synthetic sign-in test as a `ff_support` user attached only
   through `operator_admins.scope_type = 'ff_support'` for a single
   target operator. Inspect the JWT claims with
   `firebaseCustomClaimsForUser` test fixtures
   (`test/user_lifecycle_live_binding_test.dart:288-360`).
5. If H1 confirms, the architectural decision is whether the
   ff_support user should: (a) be required to pick an operator
   first via a separate `/v1/admin/auth/sessions` flow (already
   exists at `advisor_proxy.dart:6838`), or (b) get an `operator_id` in
   the JWT at issuance. Both decisions are out of scope for this
   investigation.

---

## Bug 2 — "Proxy crashed after some time during use with multiple sessions"

Symptom: Cloud Run proxy crashes after extended live use. Most likely
crash classes for Dart-on-Cloud-Run: unhandled-future-in-root-zone,
OOM from cache growth, FD-exhaust from leaked HttpClient or postgres
leases, or pool waiter pileup leading to slow-path failure cascade.

### 2.1 Top suspects, ranked

#### S1 (HIGH) — Unhandled async errors escape to the root zone and exit the process

**Evidence:**

- `tool/advisor_proxy/main.dart:84` — `main` is plain `async`, no
  `runZonedGuarded`. Whole serve loop runs in the root zone.
- `tool/advisor_proxy/main.dart:1433-1612` — request loop wraps each
  request in `unawaited((() async { try { ... } catch (e, st) {...}
  })())`. The try/catch catches synchronous + awaited errors. It does
  **NOT** catch errors from `unawaited` futures spawned inside
  `routeRequest` or the gateways.
- Multiple `unawaited(...)` sites inside the proxy
  (`worker_startup_wiring.dart:295, 309, 323, 335, 356`;
  `realtime_bridge.dart:347, 357, 366, 392`) — each wraps internal
  try/catch and is safe. The risk is any gateway implementation
  called via the request path that fires an unawaited future without
  a try/catch — its async throw lands in the root zone.
- Process-exit signature: Cloud Run instance terminates with exit
  code 70 (EX_SOFTWARE) or with "Unhandled exception:" stderr; no
  `shutdown.complete` log preceding it.

The SIGTERM/SIGINT handler at `main.dart:1372-1377` IS wired, so a
graceful Cloud Run termination emits `shutdown.signal_received` +
`shutdown.complete`. **Crashes that bypass those log lines are
root-zone escapes.**

**To confirm:** filter Cloud Run logs for `shutdown.complete` absence
preceding the instance disappearance; wrap `main()` body in
`runZonedGuarded(..., (e, st) => log('proxy.root_zone_uncaught',
...))` to capture the offending stack.

#### S2 (HIGH) — Postgres pool waiter exhaustion under sustained multi-session load + latent timeout-leak landmine

**Evidence:**

- `proxy_bootstrap.dart:117-121` — default pool size 4
  (`resolvePostgresMaxConnectionsPerPool` env override:
  `POSTGRES_POOL_MAX_CONNECTIONS`).
- `POST_HARDENING_FOLLOWUPS.md:508-526` — pressure-preview-v1 P1
  finding **"preview-env Postgres pool exhaustion"** (2026-05-08).
  Same defaults in production.
- Under sustained load, bursts of >4 concurrent requests queue on
  `_PackagePostgresWaiter` (`package_postgres_executor.dart:214-365`).
  Each waiter has bounded acquire timeout
  (`kPostgresAcquireConnectionTimeout`); exhausted waiters surface
  `DependencyTimeoutException` (`request.dependency_timeout`
  structured event, `package_postgres_executor.dart:36-44`).
- Latent landmine: `package_postgres_executor.dart:414-419` and
  `433-438` throw on `TimeoutException` from `query`/`execute`
  **without setting `_finalized`** and **without calling
  `_lease.discard()`**. The `TenantTransactionWrapper` finally at
  `tenant_transaction.dart:105-137` IS the saving grace — it calls
  `tx.rollback()` which discards the lease. So today's wrapper
  callers are safe. Any future raw `beginTransaction()` caller
  without a finally would leak.

The pool returns errors — it doesn't crash. The crash arrives if S1
fires while the timeouts are happening (e.g. a gateway hits a
dependency-timeout it didn't expect to be possible, throws in an
unawaited fan-out, escapes root zone).

**To confirm:** track `request.dependency_timeout` rate vs crash
window; emit pool gauges (`_openConnectionCount`, `_idle.length`,
`_waiters.length`) via a `/health` producer; raise
`POSTGRES_POOL_MAX_CONNECTIONS` to the runbook-recommended 20
(`runbooks/cloud_run_env_vars.md:42`) and re-observe.

#### S3 (MEDIUM) — Unbounded in-process maps grow during multi-session use

**Evidence:**

- `lib/services/realtime/google_cloud_pubsub_subscriber.dart:186`
  — `_ringBuffers` is a `Map<_RingKey, List<RealtimeEvent>>` keyed by
  `(operator_id, topic)`. Per-key length is bounded by
  `_ringBufferCapacity`, but the **key count is not** bounded.
  Every operator-topic pair that has ever flowed through this
  subscriber stays in memory for the pod's lifetime. With ~17 vendors
  per operator × 6+ topic surfaces, and operators scaling out post-launch,
  this grows.
- `tool/advisor_proxy/main.dart:1628` — `_BootstrapLocationResolver._cache`
  is `final Map<String, String>` with no eviction. One entry per
  operator. Bounded by operator count. Small risk.
- `tool/advisor_proxy/realtime_bridge.dart:238` — `_knownOperatorIds`
  is a `Set<String>` with no eviction. Same growth as above. Small.
- `tool/advisor_proxy/proxy_idempotency_cache.dart:46-149` — bounded
  via `maxEntries = 10000` and TTL GC. Safe.
- `tool/advisor_proxy/advisor_response_cache.dart` — Postgres-backed.
  Safe.

**Why this is medium:** None of the unbounded surfaces are touched
per-request; they grow per-operator. So even at scale, growth is
linear in operator count, not in request count. Unlikely to be the
**immediate** crash cause for a fresh production deploy with a small
operator pool. But the ring-buffer one is the right candidate for a
forward audit before scale-out.

**To confirm:**

- Emit per-pod gauges: `pubsub_subscriber.ring_buffer_keys`,
  `pubsub_subscriber.ring_buffer_total_bytes`. Compare across pod age.
- Heap dump on a pod ~24h after start; look for `_RingBuffers` or
  `_RingKey` retention growth.

#### S4 (MEDIUM-LOW) — WebSocket / realtime stream subscription leak when the upgrade is short-lived

**Evidence:**

- `tool/advisor_proxy/realtime_route.dart:288-308` — `subscription =
  publisher.subscribe(operatorId).listen(...)`. Cancelled at line
  `409` (onDone) and `418` (onError) when `socket.listen` is
  registered at line `402`.
- The order is: subscribe (288) → optional replay block (310-400) →
  socket.listen registers cancel handlers (402). If the **replay block
  throws** (e.g. `replayFetcher` returns a sentinel that throws on
  iteration) AND the throw escapes the local try/catch (it doesn't
  today — line `374` catches everything), the subscription would
  leak.
- This is well-defended today via the try/catch/finally at 374-399.
  The only window is if the dart:io `WebSocketTransformer.upgrade`
  succeeds, the subscription is created, AND the closure returning
  the `completer.future` is somehow abandoned. Cloud Run can sever
  the upgrade socket between the lib and the client at any moment;
  in that case `socket.listen`'s onDone/onError fire and cancel the
  subscription. Verified safe.

**Why this is medium-low:** The code structure looks safe. The risk
is "many WebSocket clients reconnecting often" cumulatively retaining
StreamSubscriptions. With multi-tab usage on operator-web + mobile,
this could be a thousand subscriptions for a single operator. Each
subscription holds a reference to the publisher's broadcast stream,
which holds the per-pod ring buffer state. Memory growth is bounded
but observable.

**To confirm:**

- Add per-operator subscription counter that increments on
  `publisher.subscribe(...)` and decrements on subscription.cancel.
- Cloud Run RSS metric vs pod uptime; a sawtooth pattern correlated
  with WebSocket reconnect bursts suggests this.

#### S5 (LOW) — Bare `catch (_)` at the listener-loop boundary swallows the actual crash trigger

**Evidence:**

- `tool/advisor_proxy/main.dart:1600-1610` — `catch (error, stack) {
  log(LogSeverity.error, 'proxy.listener_loop_error', ...)`. This is
  a proper typed catch with logging — NOT a bare catch. It catches
  any throw from `routeRequest` and logs it. The crash, if any, comes
  from outside this scope (S1).
- The 16 bare `catch (_)` sites inside `advisor_proxy.dart`
  (`POST_HARDENING_FOLLOWUPS.md:430-439`) are inside route handlers
  and map to 503 responses. They don't crash the proxy.

This is suspect-low. Listed so the surface is enumerated.

### 2.2 Recent-history correlation

Recent proxy commits (last 30 days):

- `363160e6 fix(p0-security): webhook signature secret cache + error sanitization` — touches `admin_integrations_routes.dart`. No proxy-listener change.
- `f39d84db fix(admin-integrations): wire Idempotency-Key guard into 4 admin write routes` — additive; no listener change.
- `02a8334f feat(doc1.timing-web-admin-live-parity)` — adds new routes.
- `b7a24b69 feat(doc1.keyed-data-accuracy-write)` — adds routes.
- `dba3c7e0 feat(realtime.pubsub-cross-pod-replay)` — wires the
  Pub/Sub subscriber + publisher. **Increases ring-buffer pressure
  (S3) and per-pod resource use.**
- `2acbe107 perf(scale.hardening): NOTIFY split + Cloud Run env +
  regression tests`.
- `e1df3239 refactor(error-handling): typed catch arms in
  auth_session_notifier + tenant_transaction + package_postgres_executor`
  — recent typed-catch work. Did NOT touch the timeout-leak pattern
  at `package_postgres_executor.dart:414-419` (S2).

The **`dba3c7e0` cross-pod replay wiring** is the highest-impact
recent change. The ring-buffer state on every pod grows per
subscription, and each subscriber pull cycle (1s default) writes
into the map. Worth checking pod uptime vs subscriber start time.

`docs/POST_HARDENING_FOLLOWUPS.md:508-526` (pressure-preview-v1)
lists **"preview-env Postgres pool exhaustion"** as a P1 finding from
the 2026-05-08 sprint. That directly corroborates S2 — pool
exhaustion was observed under load in the preview env. Production
running with the same defaults (4 connections per pool) under
sustained multi-session traffic would hit the same wall.

### 2.3 Ranked hypotheses summary

| Rank | Hypothesis | Evidence strength | Confirming signal |
|---|---|---|---|
| S1 | Unhandled async error escapes to root zone — no `runZonedGuarded` around `main()` | High | Cloud Run instance disappears without `shutdown.complete` log; stderr "Unhandled exception:" banner |
| S2 | Postgres pool waiter exhaustion (4 conn default, pressure-preview confirmed at preview) + timeout-leak landmine at `package_postgres_executor.dart:414, 433` | High | `request.dependency_timeout` rate climbs, then crash; pool size matters |
| S3 | `_ringBuffers` map grows unbounded in `GoogleCloudPubsubSubscriber` | Medium | RSS grows monotonically with operator-topic key count |
| S4 | WebSocket StreamSubscription accumulation under rapid reconnects | Medium-Low | Subscription counter climbs faster than disconnect rate |
| S5 | Bare catches mask the real trigger | Low | Already enumerated in followups; not a crash source |

### 2.4 Bug 2 — Recommended next steps (instrumentation only)

1. **Cloud Run log triage first.** Filter `severity=ERROR` for the
   crash window. Specifically look for:
   - Last `proxy.listener_loop_error` event before the disappearance.
   - Presence/absence of `shutdown.signal_received` and
     `shutdown.complete` lines (`main.dart:1330-1369`).
   - Any "Unhandled exception:" stderr lines (Dart's default
     unhandled-async sink).
   - Pattern of `request.dependency_timeout` events (S2 signal) in
     the minutes leading up to the crash.
2. Wrap `main()` body in `runZonedGuarded` and emit
   `proxy.root_zone_uncaught` (S1 mitigation observability — no fix
   required to get the diagnostic, just the wrap).
3. Emit pool gauges from `PackagePostgresPool` — `idle`, `open`,
   `waiters`. Surface via the `/health` producer registry (the
   shape is in `tool/advisor_proxy/health_producers/`).
4. Emit `pubsub_subscriber.ring_buffer_keys` gauge (S3).
5. If preview-env reproduction is available, run the 2026-05-08
   pressure-preview-v1 sprint's webhook/backfill harness against the
   proxy and capture heap/RSS over 30 minutes. The harness lives at
   `docs/archive/_execution/2026-05-08_pressure_preview_findings.md` per
   `POST_HARDENING_FOLLOWUPS.md:526`.
6. Raise `POSTGRES_POOL_MAX_CONNECTIONS` from default 4 to e.g. 20 (the
   value the runbook recommends at
   `runbooks/cloud_run_env_vars.md:42`) and re-observe production
   stability.

---

## Cross-bug observations

- **Bare-catch debt at `tool/advisor_proxy/advisor_proxy.dart`** (16
  sites, tracked in `POST_HARDENING_FOLLOWUPS.md:430-439`) is the
  single biggest barrier to root-causing either bug because it
  silently maps mixed error types to a single 503 surface. The
  proxy-split plan
  (`docs/phases/proxy_split/proxy_split_plan.md`) is the
  scheduled home for this work; until it lands, instrumentation has
  to substitute for typed catches.
- **`main()` not wrapped in `runZonedGuarded`** is the single
  highest-leverage instrumentation improvement — one wrap, one log
  line, identifies whether S1 is real on the next crash.
- **Pressure-preview P1 #5** (preview-env Postgres pool exhaustion,
  `POST_HARDENING_FOLLOWUPS.md:516`) is the production-relevant
  corroborator for S2. Pool exhaustion under multi-session load is
  the most likely "after some time during use" trigger.
- **F&F support / super-admin sign-in** has an asymmetric
  client/server contract (client tolerates missing `operator_id`;
  proxy doesn't) at
  `firebase_auth_login_service.dart:203-228` ↔ `advisor_proxy.dart:2166-2174`.
  Even if Bug 1 is not exactly H1, the asymmetry itself is a contract
  defect worth flagging.

All citations are inline above; no appendix.
