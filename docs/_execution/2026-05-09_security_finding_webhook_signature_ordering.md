# Security Triage — Webhook Signature / Credential-Lookup Ordering

Date: 2026-05-09
Origin: PR #452 (`pressure.preview.v1` Phase 3A — webhook flood)
Triage author: Claude (claude/security-triage-webhook-signature-ordering)
Severity recommendation: **P0 — schema-info leak + DOS amplification, treat as actively exploitable.**

---

## 1. Finding summary (what we observed under load)

The Phase 3A load harness (`tool/pressure/p3a_webhook_flood.dart`) flooded the
preview proxy at
`https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app`
with 1700 vendor webhook POSTs (10 ops × 5 min × 2 events/min × 17 vendors).
Headline numbers from the PR #452 body:

- 27 findings across 5 categories.
- 0 / 1700 2xx, 700 4xx, **1000 5xx**.
- HTTP-completion rate 41.2% (only 2xx + non-429 4xx).
- p95 = **10083 ms** vs. 2000 ms documented budget (5×).
- 640 of the 1000 5xx carried
  `DependencyTimeoutException(surface: postgres, operation: acquire_connection, elapsed_ms: 10000)`
  — Postgres pool starvation.

Two security-relevant patterns in the response bodies:

- **Schema-info leak.** `scenario_a_forged_signature.json` fixtures returned
  5xx with raw Postgres errors in the response body, e.g.:
  - `Severity.error 42P01: relation "public.vendor_credentials" does not exist`
  - `Severity.error 42703: column op.rollover_hour does not exist`
  - `DependencyTimeoutException(surface: postgres, operation: acquire_connection, elapsed_ms: 10000)`
  - the first stack frame of the throwing site
  inside a top-level `phase_8_0_route_error` envelope. The forged-signature
  fixture is meant to exercise the verifier's reject path; instead the proxy
  hit Postgres first and leaked the failure.
- **DOS amplification.** Every forged-signature request still cost a
  Postgres SELECT against `vendor_credentials` to fetch the operator's
  signing secret. With the connection pool saturated, that SELECT held a
  pgpool slot for up to the 10-second `acquire_connection` ceiling,
  ballooning tail latency and starving every other route on the same
  proxy revision.

The original triage hypothesis: the webhook handler runs the credential
lookup BEFORE signature verification, so a forged signature still
triggers a DB hit. Confirmed below — but with an important nuance about
the proposed fix.

---

## 2. Root-cause confirmation (exact code paths)

### 2.1 Handler ordering — confirmed bug

`lib/services/integration/inbound_webhook_handler.dart` `dispatch()`
executes (after vendor-adapter resolution) in this order:

| Step | Lines | What it does |
|---|---|---|
| Adapter resolved | 363–374 | Pure registry lookup, no I/O |
| Verifier registered? | 378–388 | Pure map lookup |
| **DB hit: lookupSigningSecret** | **389–393** | `await gateway.lookupSigningSecret(...)` — Postgres SELECT |
| Signing-secret null guard | 394–400 | Fail closed when no secret on file |
| **HMAC verify** | **401–406** | Pure compute, uses `signingSecret` from step 389 |
| Replay-window check | 426–446 | Pure compute, uses extracted timestamp |
| DB hit: lookupBinding | 451–462 | Postgres SELECT for cross-tenant id check |
| DB write: claimIdempotency | 488–501 | Postgres INSERT/conflict |

**Confirmed:** every inbound webhook — valid OR forged — pays one
Postgres SELECT (`vendor_credentials`) BEFORE any HMAC compare. A
forged-signature request still consumes a connection, still waits up to
the pool's `acquire_connection` ceiling, and on schema-gap
environments still surfaces the relation/column error.

### 2.2 Why the agent's literal fix proposal needs adjustment

PR #452's recommendation reads "flip the order — HMAC verify BEFORE
credential lookup." Taken literally that is impossible: the verifier
needs the signing secret to compute the HMAC. Every per-vendor verifier
in `lib/integrations/{pos,labor,reservation}/*_webhook_signature_verifier.dart`
takes `signingSecret` as a parameter (e.g. `square_webhook_signature_verifier.dart:67`
`verify(... required String signingSecret ...)`), and the secret is the
HMAC key — not a side input.

The real fix is two-headed (see Section 5):

1. **Sanitize the response path** so DB exceptions never reach the wire
   regardless of where they throw (closes the schema-info leak
   immediately, does not require any flow change).
2. **Cache the signing secret in-process** so the credential lookup is
   amortised across requests for the same `(operator, location, vendor)`
   triple (closes the DOS amplification by removing the per-request DB
   hit on the hot path).

Optionally (3): add a cheap pre-DB header-format sanity check (vendor
signature header present + base64-shape) so syntactically malformed
forgeries reject in O(1) without ever calling the gateway. This is
defence-in-depth, not the load-bearing fix.

### 2.3 Response-body leak — confirmed

`tool/advisor_proxy/admin_integrations_routes.dart` `tryHandle()`
lines **241–252**:

```
} catch (error, stack) {
  // Defensive: the marked-region call site does not catch our
  // throws, so any uncaught exception here would propagate to
  // the listener loop. Return a 500 with the error stringified
  // so the main loop's structured log captures the right field.
  _writeJson(request.response, 500, <String, Object?>{
    'error': 'phase_8_0_route_error',
    'message': error.toString(),
    'stack_first_frame': _firstStackFrame(stack),
  });
  return true;
}
```

This is the catch-all wrapping both `_handleWebhook` and `_handleAdmin`.
`error.toString()` is fed straight into the JSON response body, and
`_firstStackFrame` (line 1012) is the first newline-split frame of the
StackTrace — also written to the wire.

When `lookupSigningSecret` throws (schema gap, pool timeout,
`InboundWebhookGatewayException`), the throw propagates from
`gateway.lookupSigningSecret` → `dispatch` (no try/catch around it on
line 389) → `_handleWebhook` (line 553 has no try/catch around
`webhookHandler.dispatch`) → `tryHandle` (line 241 catches everything
and stringifies). That is exactly the path the PR #452 excerpts came
out of.

---

## 3. Production1 exposure assessment

### 3.1 Code surface — present in current master

Inbound-webhook handler ordering bug landed
2026-05-03 in commit `2ac0ada8` (`feat(8.0): integration framework + metric
honesty + timestamp sanity`). The Postgres-backed gateway's
`lookupSigningSecret` landed 2026-05-06 in commit `0b7bc2eb`
(`feat(8.framework.repository-inbound-webhook-gateway): production webhook
gateway with bounded retries`). The catch-all
`error.toString()` response leak landed with the route file in
`2ac0ada8` too. All three are present at master HEAD `95edc973`
(2026-05-09).

### 3.2 Production1 deployed SHA — bug present iff route exposed

`runbooks/preview_environment_runbook.md` documents the deployment
shape (preview vs. shared staging vs. production); it does not pin a
specific Production1 SHA — that lives in operator state outside the
repo. `PROJECT_TRACKER.md` plus
`docs/_execution/2026-05-06_v1_operator_punchlist_execution.md` record
that "Production1 runtime live" was declared 2026-05-06, with only
DNS-action items and 2 migrations remaining at that point.

The relevant migration —
`db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`
— is listed in `docs/POST_HARDENING_FOLLOWUPS.md` Section "P0 —
Production1 Migration Apply Gap" as one of the 28 still pending
Production1 apply. **That has two implications:**

1. If Production1's deployed proxy SHA is ≥ `2ac0ada8` (very likely —
   it was declared runtime-live three days after the framework
   landed), then `/v1/webhooks/{vendor}/{operator_id}/{location_id}`
   is registered and reachable, and a forged-signature POST will hit
   `lookupSigningSecret` and SELECT against `vendor_credentials`.
2. The `webhook_signing_secret_ciphertext` column does not exist in
   Production1 (migration unapplied), so the SELECT will throw a
   `42703 column does not exist` Postgres error. That error will be
   stringified by the `tryHandle` catch-all and returned in the
   response body — the EXACT leak we observed in preview.

**Conclusion:** Production1 is exposed. The forged-signature → schema-
leak path is reachable today. It is also worse than preview in one
sense (a sandbox attacker has no way of knowing whether the column
exists upstream; the leak tells them) and not-much-better in another
(the pool starvation is per-instance and applies wherever this proxy
runs).

The exposure assumes the route is publicly reachable. The webhook
endpoint `/v1/webhooks/{vendor}/{operator_id}/{location_id}` requires
no admin auth (vendors are unauthenticated until the HMAC verify
passes — that is by design for inbound webhooks), so the route is
internet-facing on Production1's Cloud Run service.

### 3.3 Confirmation needed from operator

- Operator: confirm Production1's deployed proxy revision SHA. If it
  is older than `2ac0ada8` (2026-05-03) the bug is not deployed; in
  that case Production1 is safe today but next deploy lights it up.
- Operator: confirm
  `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`
  is still unapplied to Production1. If applied, the schema-leak text
  changes (no `42703 column does not exist`) but the leak surface and
  DOS amplification both remain.

---

## 4. Response-body leak inventory

Every site below stringifies a thrown exception into the HTTP response
body. For each, the call site is reached by an upstream service (often
Postgres-backed) so a real DB error or `Exception.toString()` payload
can land on the wire.

| File | Line | Path / context | What leaks |
|---|---|---|---|
| `tool/advisor_proxy/admin_integrations_routes.dart` | **248** | `_handleWebhook` + `_handleAdmin` catch-all in `tryHandle` | `error.toString()` + `_firstStackFrame(stack)` for any throw from the webhook handler or admin route — the load harness saw exactly this for forged signatures |
| `tool/advisor_proxy/admin_integrations_routes.dart` | 249 | same site | first stack frame (`_firstStackFrame` reads `frames.first.trim()` — leaks a Dart symbol path) |
| `tool/advisor_proxy/integration_oauth_routes.dart` | 351 | OAuth `tryHandle` catch-all | `error.toString()` + first stack frame |
| `tool/advisor_proxy/integration_oauth_routes.dart` | 424 | `_handleBegin` `state_token_persist_failed` | `error.toString()` (Postgres path) + first stack frame |
| `tool/advisor_proxy/integration_oauth_routes.dart` | 786 | `api_key_validation_failed` (502) | `error.toString()` (vendor HTTP path, may include URL/host info) |
| `tool/advisor_proxy/integration_oauth_routes.dart` | 812 | `connect_persist_failed` (500) | `error.toString()` (Postgres path) |
| `tool/advisor_proxy/pepper_routes.dart` | 79 | `pepper_route_error` catch-all | `error.toString()` + `_firstFrame(stack)` |
| `tool/advisor_proxy/admin_email_routes.dart` | 202 | `email_test_unhandled_error` (500) | `error.toString()` (email provider exception path) |
| `tool/advisor_proxy/email_dispatch/vendor_lifecycle_promotion_routes.dart` | 211 | `lifecycle_promotion_unhandled_error` (500) | `error.toString()` |

Total: **9 leak sites** across 5 files. The webhook-handler path used
by the load harness is the catch-all at
`admin_integrations_routes.dart:248`, but the same pattern is
load-bearing on every admin/oauth/pepper/email surface above.

`tool/advisor_proxy/proxy_bootstrap.dart:6056` and `:6132` also stringify
exceptions but write into audit-log payloads (internal storage), not
HTTP response bodies — out of scope for this triage.

---

## 5. Proposed fix slice

### Title

`webhook-signature-secret-cache-and-error-sanitization`

### One-line scope

Cache vendor signing secrets in-process to remove the per-request
Postgres hit on the webhook hot path, and sanitize all proxy response
bodies so caught Postgres / framework exceptions never leak schema
identifiers, stack frames, or `Exception.toString()` text to
unauthenticated callers.

### Files to change

Authoritative list, smallest set that closes both the schema-info leak
and the DOS amplification:

1. `lib/services/integration/inbound_webhook_handler.dart` — add an
   optional `SigningSecretCache` interface dep on the handler; thread
   it through `dispatch` so `lookupSigningSecret` is read-through-cache
   with a short TTL (e.g. 60s) keyed on `(operatorId, locationId, vendorId)`.
   Keep the cache a pure interface; production wires an in-memory
   implementation, tests pass a fake. Default to "no cache" so the
   surface stays opt-in for slow rollout.
2. `lib/services/integration/inbound_webhook_signing_secret_cache.dart`
   (new file) — small in-memory cache with bounded entries +
   TTL eviction. Cap entries per operator to bound RAM under multi-tenant
   load (mirrors the `kSyntheticEventIdSoftCap` pattern in
   `repository_inbound_webhook_gateway.dart`).
3. `tool/advisor_proxy/admin_integrations_routes.dart` — replace
   `error.toString()` + `stack_first_frame` in lines 246–250 with a
   sanitized envelope (`error_id` UUID + sanitized
   `message: 'internal_server_error'`); log the full
   `error` + `stack` to the structured logger so operators retain the
   triage breadcrumb. Repeat the substitution for the other 7 leak
   sites in Section 4.
4. `tool/advisor_proxy/admin_integrations_routes.dart` — wrap
   `webhookHandler.dispatch` in `_handleWebhook` (line 553) in its own
   try/catch so a gateway throw is mapped to a sanitized
   `WebhookOutcome.adapterError`-shaped 500 (matches what the handler
   returns for adapter exceptions today; the route wrapper just
   becomes consistent).
5. `tool/advisor_proxy/proxy_bootstrap.dart` — wire the new
   `SigningSecretCache` instance through the binder so production gets
   the read-through-cache.
6. `test/integration/inbound_webhook_handler_test.dart` — add cases:
   (a) cache hit short-circuits the gateway call;
   (b) cache miss falls through and populates;
   (c) gateway exception still surfaces as `signatureInvalid` outcome
       without leaking the underlying message.
7. `test/services/integration/repository_inbound_webhook_gateway_test.dart`
   — already covers the gateway; no change unless cache-eviction tests
   land in the same file.
8. `test/tool/advisor_proxy/admin_integrations_idempotency_test.dart`
   (or a new sibling test) — assert response bodies for forced 500s
   never contain `'42P01'`, `'42703'`,
   `'DependencyTimeoutException'`, `'StackTrace'`, or any Postgres
   `Severity.` text.

Do **not** change verifier signatures or the gateway in this slice.

### Before / after behavior

| Surface | Before | After |
|---|---|---|
| Forged-signature webhook (sig already cached) | Postgres SELECT on every request, 5xx on schema gap, body leaks `relation "public.vendor_credentials" does not exist` | In-process cache hit, HMAC verify fails, sanitized 403 body `{outcome: signatureInvalid, message: 'signature invalid'}` (no DB hit) |
| Forged-signature webhook (cold cache, schema gap) | Same Postgres SELECT, 5xx leak | Postgres SELECT happens once, exception swallowed, sanitized 500 body `{error: 'internal_server_error', error_id: '<uuid>'}`; full detail lands in structured log |
| Valid-signature webhook (cold cache) | Postgres SELECT on every request, 200 | Postgres SELECT happens once per (op,loc,vendor) per TTL, 200 |
| Valid-signature webhook (warm cache) | Postgres SELECT on every request, 200 | Cache hit, HMAC verify passes, 200 (no DB hit on the verify path) |
| Admin route 500 (any leak site in §4) | Body contains exception text + stack frame | Sanitized envelope; correlate via `error_id` in proxy logs |

### Risk assessment

| Risk | Probability | Mitigation |
|---|---|---|
| Cache returns stale secret after rotation, causing valid webhooks to fail signature check until TTL expires | Low (rotation is rare; TTL bounds the window) | Keep TTL short (60s default). Wire a cache-invalidate hook into the credential rotation flow in `proxy_bootstrap.dart` (KMS rotation already audits — bounce the cache there) |
| Cache amortises a stale `null` (no secret provisioned) and causes legitimate webhooks to fail-closed for the TTL window | Low | Cache only successful lookups; nulls always go through to the gateway (cheap if no row) |
| Vendor that "uses the credential during signature derivation" — i.e. needs more than just the signing secret | None observed | Audited every verifier in `lib/integrations/{pos,labor,reservation}/*_webhook_signature_verifier.dart` (16 files): all take `signingSecret` as the HMAC key directly. None reference the operator/location id outside the secret. Risk is zero for the 16 known vendors |
| Sanitized error envelope breaks an existing client that parsed the leaky `message` field | Low (clients are vendor webhooks, they only consume status codes) | Keep the same status codes; only the body wording changes. Confirm via a one-day staging soak before Production1 |
| Cache RAM growth in multi-tenant proxy | Low | Bound entries per operator (mirror `kSyntheticEventIdSoftCap`); LRU evict |

### Rollout plan

1. **Land the slice on master** with the cache disabled by default
   (constructor flag). Run the integration tests + the existing webhook
   harness in `test/integration/inbound_webhook_handler_test.dart`.
2. **Preview deploy** with cache enabled. Re-run the load harness from
   PR #452 (`tool/pressure/p3a_webhook_flood.dart`) and confirm:
   - p95 latency drops below the documented 2000 ms budget for the
     happy-path vendors;
   - forged-signature responses no longer carry `relation`/`column`/
     `Severity` text;
   - 5xx rate falls (the pool-exhaustion finding is partially driven
     by the per-request DB hit; the cache amortises it).
3. **Apply migration
   `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`
   to staging** per
   `runbooks/phase_9_production1_migration_apply_runbook.md`. This is
   pre-existing P0 from `docs/POST_HARDENING_FOLLOWUPS.md`; the
   security-fix slice itself does NOT depend on it being applied first
   (the sanitization closes the leak even with the schema gap), but
   resolving the migration removes the underlying schema-mismatch
   crash and is hygiene.
4. **Shared-staging deploy** with cache enabled; bake for one day.
5. **Production1 deploy** with cache enabled. Apply the pending
   webhook-signing-secret migration in the same window per the P0
   migration runbook (the migration is independent of the code fix
   but resolves the second head of the leak text). Verify with a
   forged-signature curl from a non-operator host that the response
   body contains only the sanitized envelope.
6. **Tracker hygiene** — append a P0 entry pointing at this triage
   doc; flip to "fixed" once the slice merges and the staging soak
   confirms.

---

## 6. Severity recommendation

**P0 — actively exploitable.**

Justification:

- The schema-info leak is reachable from the public internet with no
  authentication (the webhook endpoint is intentionally
  unauthenticated until HMAC verify passes — that's by design — but
  the leak fires BEFORE that gate).
- The leak text reveals table and column names of internal Postgres
  schema (`public.vendor_credentials`, `op.rollover_hour`,
  `Severity.error <pgcode>`), the first stack frame of Dart code, and
  any other `Exception.toString()` text the gateway throws. That is a
  reconnaissance-grade leak — an attacker can probe what migrations
  are/aren't applied, what tables exist, and which routes share which
  pool.
- The DOS amplification lets an attacker tie up the Postgres pool
  with bogus signatures. The PR #452 numbers show 640 / 1000 5xx
  carrying `acquire_connection elapsed_ms: 10000` with only 17
  vendors × 10 ops × 2 events/min — well under what a hostile sender
  could push.
- Production1 is "runtime live" per the 2026-05-06 punchlist;
  `/v1/webhooks/...` is part of the merged framework that has been
  on master since 2026-05-03 and is therefore deployed (operator to
  confirm SHA).
- Both heads close in a single bounded slice (estimate: under 1 day
  of work + 1-day staging soak).

The pre-existing P0 in `docs/POST_HARDENING_FOLLOWUPS.md` ("28
migrations pending Production1 apply", including the webhook-signing-
secret column) is **adjacent but distinct** — applying that migration
removes one specific leak phrase but does not stop the broader
`error.toString()` pattern. The fix slice in §5 must land regardless of
when that migration applies.

---

## Appendix — quick repro recipe (do NOT run against Production1)

The PR #452 harness already reproduces this against preview. To
reproduce manually against any non-production proxy:

```bash
curl -i -X POST \
  https://<preview-or-staging>/v1/webhooks/toast/<operator-uuid>/<location-uuid> \
  -H 'Toast-Hmac-SHA256: PLACEHOLDER-INVALID' \
  -d '{"eventType":"orders.modified","eventId":"forged-test-1"}'
```

Expected today: 500 with `message` field containing `relation
"public.vendor_credentials" does not exist` (preview) or `column
op.rollover_hour does not exist` (preview/staging) or
`DependencyTimeoutException` (under load). Expected after fix:
sanitized 500 body, full detail only in proxy structured logs.
