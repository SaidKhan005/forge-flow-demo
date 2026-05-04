# Libro Reserve — Webhook Signature

**Vendor ID**: `libro`
**Source documentation**: <https://libroreserve.github.io/api-documentation/#section/Webhooks>
**Retrieval date**: 2026-05-04

---

## Algorithm

`HMAC-SHA256`

Cite vendor doc: <https://libroreserve.github.io/api-documentation/#section/Webhooks>

---

## Signed payload

`<timestamp>.<raw body>` — UTF-8 concatenation of the timestamp from
the `t=` segment of the signature header, a literal `.`, and the
exact raw request bytes.

The adapter MUST preserve the raw bytes through the request pipeline
(no JSON re-serialization before HMAC). The framework's inbound
webhook handler hands the verifier the original `rawBody: Uint8List`.

---

## Encoding

`hex (lowercase)` — case-sensitive: uppercase hex is rejected by the
verifier (matches the documented Libro shape; verify on sandbox).

---

## Header name

Exact header the signature arrives in:

- `X-Libro-Signature`

Header value shape:

```
X-Libro-Signature: t=<unix_epoch_seconds>,v1=<hex_lowercase_hmac_sha256>
```

Multiple `v1=` segments (signing-key rotation) are NOT honored at
V1 — webhook key rotation UI is a banned item per V1 lean cut 2.
The verifier reads the first `v1=` segment only.

---

## Timestamp header

Combined into the same header (`t=` segment).

- **Format**: Unix epoch seconds (integer).
- **Replay tolerance**: 24 hours per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`). The strict 5-minute Stripe-style
  window from iter1 was deleted because vendor retries commonly
  exceed 5 minutes; the framework's idempotency UNIQUE on
  `(vendor_id, operator_id, vendor_event_id)` prevents double-write
  of legitimate retries.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart`.

Verifier file:
`lib/integrations/reservation/libro_webhook_signature_verifier.dart`.

---

## Auto-register endpoint

`POST /v1/webhooks/subscriptions`

Called by `LibroReservationAdapter.connect` via
`LibroHttpClient.registerWebhook`. Body:

```json
{
  "venue_id": "<libro venue id>",
  "url": "<f&f webhook url>",
  "events": [
    "reservation.created",
    "reservation.updated",
    "reservation.confirmed",
    "reservation.seated",
    "reservation.completed",
    "reservation.canceled"
  ]
}
```

Returns the subscription id — stored in
`connector_connection.metadata.webhook_subscription_id`. Used by the
adapter to call `DELETE /v1/webhooks/subscriptions/{id}` on
operator-initiated disconnect.

The subscribed event list is kept in code as
`kLibroSubscribedEvents` in
`lib/integrations/reservation/libro_reservation_adapter.dart`; any
change here MUST land in the same PR as the constant.

---

## Manual paste instructions

N/A — `webhookSupport == autoRegister`. The framework drives the
register/unregister round-trip during `connect` / `disconnect`.
