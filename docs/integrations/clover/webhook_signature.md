# Clover — Webhook Signature

**Vendor ID**: `clover`
**Source documentation**: <https://docs.clover.com/docs/using-webhooks>
**Retrieval date**: 2026-05-03

---

## Algorithm

`HMAC-SHA256`.

Cite vendor doc:
<https://docs.clover.com/docs/webhooks#verifying-the-webhook>

---

## Signed payload

`raw body` — request body bytes verbatim.

The adapter preserves raw bytes from the proxy route through HMAC
verification (no JSON re-serialization before
`CloverWebhookSignatureVerifier.verify`). Re-serialization breaks
vendor signatures because key ordering and whitespace differ.

---

## Encoding

`base64` (case-sensitive).

The verifier base64-decodes the header value before comparing bytes.
Tampering with a single base64 character (last-char swap fixture)
flips the byte sequence and the constant-time compare returns
`false`.

---

## Header name

Exact header the signature arrives in:

- `X-Clover-Auth-Signature` (lower-cased to `x-clover-auth-signature`
  by `InboundWebhookHandler` before dispatch).

The constant is exported as
`kCloverSignatureHeader = 'x-clover-auth-signature'` in
`lib/integrations/pos/clover_webhook_signature_verifier.dart`.

---

## Timestamp header

- **Header name**: `X-Clover-Auth-Timestamp`
  (lower-cased to `x-clover-auth-timestamp`).
- **Format**: Unix epoch (seconds).
- **Replay tolerance**: 24h via `kInboundWebhookReplayCeiling` in
  `lib/services/integration/inbound_webhook_handler.dart` (V1 lean
  cut 2 — strict 5-min window deleted).

The verifier extracts the timestamp; the framework's inbound webhook
handler enforces the 24h ceiling. When Clover omits the timestamp
header (some payload types don't carry one per docs), the framework
skips replay defense and relies on idempotency UNIQUE on
`(vendor_id, operator_id, vendor_event_id)` to absorb the retry.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles.

Verifier file:
`lib/integrations/pos/clover_webhook_signature_verifier.dart`.

---

## Auto-register endpoint

The adapter calls Clover to register the F&F webhook URL at connect
time:

- **Method + path**: `POST /v3/apps/{aId}/webhooks` (proxy resolves
  `{aId}` from the Cloud Run env config — the F&F App-Market app id).
- **Body**:
  ```json
  {
    "url": "<f&f webhook url>",
    "eventTypes": ["ORDER_CREATED", "ORDER_UPDATED"]
  }
  ```
- **Returns**: subscription id (string). Persisted in
  `connector_connection.metadata.webhook_subscription_id` (key
  `kCloverMetadataWebhookSubscriptionIdKey`).

Events the adapter subscribes to:

- `ORDER_CREATED` — fires when a new order is opened. Adapter
  re-fetches the order via `/v3/merchants/{mId}/orders/{orderId}` to
  hydrate canonical fields (Clover webhook envelopes carry the
  object id, not the full body).
- `ORDER_UPDATED` — fires on state transitions including paid /
  voided / locked. Same hydration pattern.

At disconnect the adapter calls
`DELETE /v3/apps/{aId}/webhooks/{subscriptionId}` best-effort; a
404 is treated as success (subscription was already removed by the
operator in the Clover dashboard).

---

## Manual paste instructions

N/A — `webhookSupport = autoRegister`.
