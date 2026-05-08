# Clover Pressure Fixtures

Sources:

- F&F integration doc pack: `docs/integrations/clover/`
  - `api_consumed.md` — endpoints + rate limits + 90-day filter cap.
  - `field_mapping.md` — Clover field → canonical fact mapping;
    `covers_field_exposed = false`.
  - `oauth_shape.md` — OAuth 2.0 authorization-code flow + rotating
    refresh token semantics.
  - `webhook_signature.md` — `X-Clover-Auth-Signature` (HMAC-SHA256
    base64), `X-Clover-Auth-Timestamp` (epoch seconds), 24h replay
    ceiling.
  - `live_verification_checklist.md`,
    `partnership_status.md`.
- Clover public developer docs:
  - `https://docs.clover.com/reference/orders`
  - `https://docs.clover.com/reference/orderget`
  - `https://docs.clover.com/reference/merchantget`
  - `https://docs.clover.com/dev/docs/webhooks`
  - `https://docs.clover.com/docs/using-webhooks`
  - `https://docs.clover.com/docs/using-oauth-20`
  - `https://docs.clover.com/docs/oauth-20-tokens`
  - `https://docs.clover.com/docs/working-with-list-endpoints`
  - `https://docs.clover.com/docs/rate-limits`
  - `https://docs.clover.com/docs/api-deprecation-policy`

Adapter: `lib/integrations/pos/clover_pos_adapter.dart`
Sink: tenant-scoped `OperatorScopedRepository` writes via
`CloverTenantFactWriter` (no per-vendor sink file at lifecycle =
`documented`; `clover_pos_postgres_sink.dart` arrives in
`8.CL.live.sandbox`).
Webhook verifier:
`lib/integrations/pos/clover_webhook_signature_verifier.dart`
OAuth credential bridge:
`lib/integrations/pos/clover_credential_bridge.dart`,
`lib/integrations/pos/clover_pos_postgres_credential_store.dart`
Webhook auto-register:
`lib/integrations/pos/clover_pos_webhook_registry.dart`
API version pin: `kCloverApiVersion = 'v3_2026_05_03'`
(see `lib/integrations/pos/clover_pos_adapter.dart`,
`test/integrations/pos/fixtures/clover_orders_fixture.dart`)

## Scenarios

| File | Outcome | Adapter assertion | Sink / framework assertion |
|---|---|---|---|
| `happy_path_order_paid.json` | accept | `_project()` produces 1 fact for `CLV-ORDER-7HXJ-2026-05-02-001`; `actual_sales = 31.40`; `closed_at = modifiedTime` (state=`paid`) | `OperatorScopedRepository.writeSalesFact` writes 1 row; `business_date` set by IANA converter |
| `happy_path_payment_completed.json` | accept | Webhook handler routes `P:` prefix → hydrate parent order via `CloverApiClient.getOrder` | 1 canonical fact written for the parent order |
| `happy_path_refund.json` | accept | `_project()` reads `order.total = 0` (full refund); writes 1 fact with `actual_sales = 0.00` | `OperatorScopedRepository.writeSalesFact` writes 1 row |
| `happy_path_webhook_envelope.json` | accept | Verifier passes; handler iterates 2 entries; calls `getOrder` once per `O:` `objectId` | Idempotency UNIQUE on `(vendor_id, operator_id, vendor_event_id)` collapses re-deliveries |
| `sparse_no_covers.json` | accept | `_project()` writes 1 fact with `covers = null`, `covers_source = 'forecast_fallback'` | `wage_source = app_fallback` downstream; degradation pill in operator chrome |
| `sparse_minimal_required.json` | accept | `_project()` writes 1 fact with `closed_at = null` (state=`open`); subsequent `paid` UPDATE webhook supersedes | `OperatorScopedRepository.writeSalesFact` writes 1 row |
| `scenario_a_forged_signature.json` | reject | `CloverWebhookSignatureVerifier.verify` returns false (constant-time compare) | No `getOrder` call; no DB write; audit row `webhook_signature_mismatch` |
| `scenario_b_malformed_payload.json` | reject | `_project()` returns null (missing `order.id`) | No DB write for that element; page chain continues |
| `scenario_c_future_dated_event.json` | reject | `command.sanityHook` returns false (>24h future) | `dropped` counter increments; no DB write |
| `scenario_d_oauth_near_expiry.json` | refresh path | Refresh cron observes `access_token_expiration < now() + 24h`; calls `POST /oauth/v2/token`; rotates credentials row | New `(access_token, refresh_token, *_expiration)` persisted; old refresh token revoked |
| `scenario_e_ambiguous_timestamp.json` | reject | `_project()` returns null (`createdTime` is string, not int) | No DB write; ambiguous TZ never reaches operator-scoped fact table |
| `scenario_f_cross_vendor_id_collision.json` | accept (with namespace) | Adapter writes 1 fact under `vendor_id = 'clover'` | Idempotency UNIQUE on `(vendor_id, operator_id, vendor_event_id)` allows a same-id Toast row to coexist; flattening to `(operator_id, vendor_event_id)` would regress this |
| `scenario_dst_spring_forward.json` | accept (3 facts) | All three orders `_project` cleanly | Worker IANA converter assigns `business_date` per location `iana_tz`; spring-forward gap (02:00 EST jumps to 03:00 EDT) is the converter's job, not the adapter's |
| `scenario_cross_timezone.json` | accept (2 facts) | Both orders `_project` cleanly | Operator-location tz (`America/Toronto`) drives `business_date`; vendor merchant tz (`America/Los_Angeles`) is irrelevant — regression that picks vendor-local would split a single Toronto service day |

## Filename aliases

The Phase 1 calling prompt named two time-edge fixtures
`dst_spring_forward.json` and
`cross_timezone_operator_toronto_vendor_pacific.json`. These
fixtures are stored under the **README binding filenames**
`scenario_dst_spring_forward.json` and
`scenario_cross_timezone.json` per the
`test/fixtures/vendor_payloads/README.md` "Required Scenario Set Per
Vendor" table that the Phase 2 harness consumes.

## Notes

### OAuth model for scenario D

Clover uses **OAuth 2.0 authorization-code with rotating refresh
tokens**. The fixture body is the documented `POST /oauth/v2/token`
response shape (`access_token`, `refresh_token`,
`access_token_expiration`, `refresh_token_expiration`,
`merchant_id`, `employee_id`, `client_id`, `token_type`). Per
`docs/integrations/clover/oauth_shape.md`, the proactive cron
refreshes when `token_expires_at < now() + 24h`; three failures
flip the connection to `error`.

### Webhook signature for scenario A

Clover's webhook signature is `HMAC-SHA256(rawBody, secret)`
base64-encoded in the `X-Clover-Auth-Signature` header
(lower-cased to `x-clover-auth-signature` by the framework's
`InboundWebhookHandler`). Replay defense is 24h via the
`X-Clover-Auth-Timestamp` header (epoch seconds). The verifier
uses `constantTimeBytesEquals`. The forgery fixture's transport
hint specifies the body was signed with a **different** secret —
the verifier rejects without parsing the envelope.

### Idempotency-key namespace for scenario F

Proxy `proxy_requests` UNIQUE is on
`(vendor_id, operator_id, idempotency_key)` and the canonical
`vendor_event_id` shadow is
`(vendor_id, operator_id, vendor_event_id)`. Cross-vendor `id`
collisions cannot shadow-write because `vendor_id` is part of the
key.

### Covers source for sparse_no_covers

Clover does not expose `guests` / `coverCount` / `partySize` on
`/orders`. Per HP #2 architecture, the adapter writes
`covers = null`, `covers_source = 'forecast_fallback'` on every
row. The operator dashboard surfaces the forecast-fallback
degradation pill per
`docs/contracts/metric_card_honesty_contract.md`.

### Rate limits + 90-day filter cap

`/v3/merchants/{mId}/orders` is capped at **16 req/sec/merchant**
and the `modifiedTime` filter range cannot exceed **90 days**.
Adapter clamps `windowStart` to `now() - 90d`; the V1 lean cut 2
first-connect window of 60 days fits inside.

## Sourcing gaps

- The Clover developer doc paths `docs.clover.com/reference/orderget`,
  `/reference/paymentget`, `/dev/docs/oauth-20-tokens`,
  `/dev/docs/working-with-payments`, `/dev/docs/refunds` returned
  404 / behind-auth at retrieval time 2026-05-08. The order shape
  used in `happy_path_order_paid.json`,
  `happy_path_refund.json`, `sparse_no_covers.json`,
  `sparse_minimal_required.json`,
  `scenario_b_malformed_payload.json`,
  `scenario_c_future_dated_event.json`,
  `scenario_e_ambiguous_timestamp.json`,
  `scenario_f_cross_vendor_id_collision.json`,
  `scenario_dst_spring_forward.json`, and
  `scenario_cross_timezone.json` is the **same shape** the F&F
  team retrieved on 2026-05-03 and pinned at
  `test/integrations/pos/fixtures/clover_orders_fixture.dart`
  (`cloverApiVersion = 'v3_2026_05_03'`). The
  `documented_per_clover_v3_2026_05_03` constant in that file is
  the binding shape contract; these fixtures match it.
- The webhook envelope shape (`appId` + `merchants[<merchantId>][]`
  with `objectId`/`type`/`ts`) is taken verbatim from
  `https://docs.clover.com/dev/docs/webhooks` (retrieved
  2026-05-08), as is the event-type-prefix table (`A`, `C`, `CA`,
  `E`, `I`, `IC`, `IG`, `IM`, `O`, `M`, `P`, `SH`).
- The list-endpoint envelope (`elements` + `href` + `offset` +
  `limit`) is taken from
  `https://docs.clover.com/clover-platform-docs/docs/working-with-list-endpoints`
  (retrieved 2026-05-08).
- The OAuth token response shape used in
  `scenario_d_oauth_near_expiry.json` (`access_token` +
  `refresh_token` + `*_expiration` + `merchant_id` +
  `employee_id` + `client_id` + `token_type`) is the v2 shape
  documented in `docs/integrations/clover/oauth_shape.md` (which
  cites `https://docs.clover.com/docs/using-oauth-20` and
  `https://docs.clover.com/docs/oauth-20-tokens`); the upstream
  doc URL was 404 at 2026-05-08 retrieval, so the F&F doc pack's
  v2 shape is the binding source.
- Refund envelope `payments[].refunds[]` is the order-schema
  nesting documented in
  `docs/integrations/clover/field_mapping.md` "Forbidden fields"
  (refunds out of scope for canonical sales facts at lifecycle =
  `documented`; the fixture exists so Phase 2 harness can confirm
  the adapter's `actual_sales = 0.00` net-of-refund behavior).

## Live-vs-documented

Lifecycle: `documented` (no live HTTP). Fixtures here cite
**public docs only**. Live sandbox / production verification rolls
in `8.CL.live.sandbox` and `8.CL.live.prod`; mismatches between
documented shape and observed shape will be captured in
`docs/integrations/clover/live_verification_checklist.md` per the
contract.

## No real secrets

Every `<<TEST_BEARER>>`, `<<TEST_HMAC_SECRET>>`,
`<<TEST_HMAC_SECRET_DIFFERENT_KEY>>` is a placeholder. No real
Clover API tokens, signing secrets, or operator data appear in any
fixture in this directory.
