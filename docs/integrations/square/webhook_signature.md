# Square — Webhook Signature

**Vendor ID**: `square`
**Source documentation**: https://developer.squareup.com/docs/webhooks/step3validate
**Retrieval date**: 2026-05-03

---

## Algorithm

`HMAC-SHA256`

Cite vendor doc: https://developer.squareup.com/docs/webhooks/step3validate

---

## Signed payload

`notification_url + raw_request_body`

Square computes HMAC-SHA256 over the concatenation of the F&F
notification URL (the URL Square posts to — registered via
`POST /v2/webhooks/subscriptions`) and the raw request body bytes.
The adapter MUST preserve the raw bytes through the request pipeline:
JSON re-serialization breaks the digest because Square's body is not
canonicalized.

The proxy stamps the registered notification URL into the
`x-ff-notification-url` header (read from
`connector_connection.metadata.notification_url`) before invoking the
verifier, so the verifier never has to call back into the gateway.

---

## Encoding

`base64`

Case sensitivity: yes (base64 alphabet only — no transformation
applied).

---

## Header name

`x-square-hmacsha256-signature`

(Lower-cased — `InboundWebhookHandler` lowercases all headers before
dispatch, so the verifier reads the lowercase form.)

---

## Timestamp header

- **Header name**: `square-initial-delivery-timestamp`
- **Format**: ISO 8601, UTC (e.g., `2026-05-03T18:45:01Z`).
- **Replay tolerance**: 24h per V1 lean cut 2 (matches
  `kInboundWebhookReplayCeiling` in
  `lib/services/integration/inbound_webhook_handler.dart`). Square
  retries can extend hours during outages; tighter-than-24h windows
  misclassify legitimate retries as replays.

The verifier parses this header and surfaces it on
`WebhookSignatureVerification.timestamp`. The framework then applies
the 24h ceiling — events whose initial delivery timestamp exceeds 24h
of age return `WebhookOutcome.replayTooOld` (HTTP 403). The
idempotency UNIQUE on
`inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`
is the backstop against any double-write of legitimate retries.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles.

Verifier file: `lib/integrations/pos/square_webhook_signature_verifier.dart`

---

## Auto-register endpoint

The adapter calls Square's webhook subscription API on connect:

- **Method + path**: `POST /v2/webhooks/subscriptions`
- **Body** (shape):
  ```
  {
    "subscription": {
      "name": "Forge & Flow",
      "notification_url": "<f&f webhook url>",
      "event_types": ["order.created", "order.updated"]
    }
  }
  ```
- **Returns**: subscription object including `id`; adapter stores
  this id in `connector_connection.metadata.webhook_subscription_id`
  so disconnect can `DELETE /v2/webhooks/subscriptions/{id}`.

Doc: https://developer.squareup.com/reference/square/webhook-subscriptions-api/create-webhook-subscription

Events the adapter subscribes to (mirrors `kSquareWebhookEvents` in
the adapter source):

- `order.created` — a new POS check / order opened. Adapter ingests
  the order body to seed `opened_at` on the canonical fact.
- `order.updated` — any field on the order changed, including
  `closed_at` being set, `total_money.amount` updating, or `state`
  transitioning to `COMPLETED`/`CANCELED`. Adapter upserts the
  canonical fact (idempotent on
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).

---

## Manual paste instructions

N/A — Square webhook registration is auto-register via the
subscription API. Operators do not paste anything in the Square
portal.
