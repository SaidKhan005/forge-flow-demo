# OpenTable — Webhook Signature

**Vendor ID**: `opentable`
**Source documentation**: <https://restaurant.opentable.com/products/opentable-platform/>
(operator-facing only — partner doc gated; see `api_consumed.md`)
**Retrieval date**: 2026-05-04

> **Every section in this file is an assumption to verify in
> `8R.OT.live.sandbox`.** OpenTable's webhook signature algorithm,
> header name, encoding, and signed-payload byte sequence are released
> to partners after the partnership program clears (see
> `partnership_status.md`). The verifier is engineered against the
> industry-standard reservation-webhook envelope (HMAC-SHA256 over the
> raw request body, hex-encoded lowercase, in `X-OpenTable-Signature`).
> The `*.live.sandbox` slice will diff observed inbound signatures
> against this shape and cut a bounded fix for any drift.

---

## Algorithm

`HMAC-SHA256` — assumption.

The verifier
(`lib/integrations/reservation/opentable_webhook_signature_verifier.dart`)
computes the digest with `Hmac(sha256, utf8.encode(signingSecret))`
over the raw body bytes.

Cite vendor doc:
<https://restaurant.opentable.com/products/opentable-platform/>

---

## Signed payload

What bytes is the HMAC computed over? **Raw body** — assumption.

Adapter MUST preserve the raw bytes through the request pipeline (no
JSON re-serialization before HMAC). The framework's inbound webhook
route hands the verifier the verbatim request bytes; the adapter does
not re-encode.

The `*.live.sandbox` slice may discover OpenTable signs over
`<timestamp>.<body>` (Stripe-style) instead. If so, the verifier
gains a `concatTimestampPrefix` parameter — bounded fix, not a slice
rebuild.

---

## Encoding

`hex (lowercase)` — assumption. Case sensitivity: yes (the verifier
rejects uppercase hex to keep the contract strict; the doc pack
documents lowercase only). Mirrors the Lightspeed K-Series + Revel
verifiers.

---

## Header name

Exact header the signature arrives in: `X-OpenTable-Signature` —
assumption. Constant declared as `kOpenTableSignatureHeader` in the
verifier file (lower-cased per the framework's header normalization).

---

## Timestamp header

Header that carries the signing timestamp — assumption.

- **Header name**: `X-OpenTable-Timestamp`
- **Format**: Unix epoch seconds (assumption — Stripe / Toast style).
- **Replay tolerance**: 24h per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

When the vendor does NOT include a timestamp in the signed payload
(verifier returns `WebhookSignatureVerification.timestamp == null`),
the framework's 24h ceiling is bypassed for that event and the
duplicate-write defense rests on the idempotency UNIQUE on
`inbound_webhook_idempotency(vendor_id, operator_id,
vendor_event_id)`.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles.

Verifier file:
`lib/integrations/reservation/opentable_webhook_signature_verifier.dart`

---

## Auto-register endpoint

(For `webhookSupport = autoRegister` vendors only — assumed.)

The vendor API endpoint the adapter calls to register the F&F webhook
URL (assumption — verify in `*.live.sandbox`):

- **Method + path**: `POST /v1/webhooks/subscriptions`
- **Body**: `{"url": "<f&f webhook url>", "events": ["reservation.modified"], "restaurant_id": "<rid>"}`
- **Returns**: subscription ID (stored in
  `connector_connection.metadata.webhook_subscription_id`)

Events the adapter subscribes to (assumed envelope — single roll-up
event per industry standard):

- `reservation.modified` — covers booked, modified, seated, completed,
  cancelled, and no-show transitions. Per-status events
  (`reservation.seated`, `reservation.cancelled`, etc.) may exist
  separately; the `*.live.sandbox` slice will confirm and switch the
  subscription if so.

---

## Manual paste instructions

N/A — assumed `autoRegister`. If the `*.live.sandbox` slice discovers
the vendor requires manual portal pasting (e.g., the partner UI does
not expose a subscription API), this section is rewritten with the
operator-facing copy:

```
1. In the OpenTable Restaurant Center, go to Integrations → Webhooks.
2. Click "Add webhook URL."
3. Paste: <f&f webhook url>
4. Set event filter: reservation.modified
5. Copy the signing secret OpenTable shows you, then paste it back
   in F&F to confirm.
```

The framework supports `manualPaste` natively; only the capability
profile (`VendorCapabilityProfile.webhookSupport`) and this section
change.
