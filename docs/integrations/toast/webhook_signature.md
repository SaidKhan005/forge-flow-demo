# Toast — Webhook Signature

**Vendor ID**: `toast`
**Source documentation**:
<https://doc.toasttab.com/openapi/webhooks/webhook-management>
+ <https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html>
**Retrieval date**: 2026-05-03

---

## Algorithm

`HMAC-SHA256`

Cite vendor doc:
<https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html#signing>

---

## Signed payload

`raw body`

The HMAC is computed over the raw HTTP body bytes verbatim. JSON
re-serialization breaks the signature; the framework's webhook route
preserves the raw bytes through to the verifier — see
`InboundWebhookHandler.dispatch` in
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart).

The adapter MUST NOT call `jsonEncode` on the parsed payload before
re-running HMAC verification (the verifier already runs upstream of
the adapter; this note is for the framework rather than the adapter
itself).

---

## Encoding

`base64` (standard, with padding). Case sensitivity: yes.

The verifier base64-decodes the `Toast-Signature` header value and
compares the bytes against the locally-computed HMAC bytes via
`constantTimeBytesEquals` from
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart).

---

## Header name

`Toast-Signature` (case-insensitive lookup at the framework layer;
the verifier uses the lower-cased key `toast-signature` per the
framework convention).

---

## Timestamp header

- **Header name**: `Toast-Webhook-Timestamp`
- **Format**: Unix epoch seconds.
- **Replay tolerance**: 24h per V1 lean cut 2 (the framework's
  `kInboundWebhookReplayCeiling` in
  [lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart)).
  The strict 5-minute Stripe-style window is explicitly NOT used —
  vendor retry windows commonly exceed 5 minutes and the idempotency
  UNIQUE on
  `(vendor_id, operator_id, vendor_event_id)` already prevents
  double-write of legitimate retries.

When the timestamp header is absent (Toast configures it per
subscription; some early-tier subscriptions do not include it), the
verifier returns `null` for the timestamp and the framework skips
replay defense for that event. Idempotency UNIQUE remains the
backstop.

---

## Constant-time compare

The verifier uses `constantTimeBytesEquals` from
[lib/services/integration/inbound_webhook_handler.dart](../../../lib/services/integration/inbound_webhook_handler.dart)
to avoid timing oracles.

Verifier file:
[lib/integrations/pos/toast_webhook_signature_verifier.dart](../../../lib/integrations/pos/toast_webhook_signature_verifier.dart)

---

## Auto-register endpoint

Toast supports `webhookSupport = autoRegister`. The adapter calls:

- **Method + path**: `POST /webhooks-config/v1/webhook`
- **Body**:
  ```json
  {
    "url": "<f&f webhook url>",
    "subscribedEvents": [
      "orders.opened",
      "orders.modified"
    ]
  }
  ```
- **Returns**: `subscriptionId` (stored in
  `connector_connection.metadata.webhook_subscription_id`).

Events the adapter subscribes to:

- `orders.opened` — fires when a new order opens; payload includes
  the full order shape so backfill / poll do not need to re-fetch.
- `orders.modified` — fires when an existing order's covers, totals,
  or close state changes; payload may be id-only, in which case the
  adapter calls `GET /orders/v2/orders/{guid}` to resolve the canonical
  fields.

Disconnect calls
`DELETE /webhooks-config/v1/webhook/{subscriptionId}` (best-effort).

---

## Manual paste instructions

N/A — Toast supports auto-register per the previous section.
