# Aloha (NCR Voyix) — Webhook Signature

**Vendor ID**: `aloha_ncr_voyix`
**Source documentation**: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
**Retrieval date**: 2026-05-04

---

## Algorithm

`HMAC-SHA256`

Cite vendor doc: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
(Events bus / webhook signing landing — exact byte-sequence and
header detail verified live in `8.AL.live.sandbox`).

---

## Signed payload

`raw body` — request body bytes verbatim.

Adapter MUST preserve the raw bytes through the request pipeline (no
JSON re-serialization before HMAC). The framework's
`InboundWebhookHandler.dispatch` passes the original `Uint8List`
straight to
`AlohaNcrVoyixWebhookSignatureVerifier.verify`.

**Ambiguity call** (verified in `8.AL.live.sandbox`):

- Whether the signature is computed over the raw body alone or over
  `<timestamp>.<body>` (Stripe-style). The verifier assumes
  raw-body-only per the documented portal landing; live diff fix is
  bounded — flip `verify` to concatenate
  `<timestamp_header>.<rawBody>` before HMAC if vendor uses Stripe
  shape.

---

## Encoding

`base64` (standard, with padding)

Case sensitivity: yes (signature comparison is byte-level via
`constantTimeBytesEquals`).

---

## Header name

Exact header the signature arrives in:

- `NCR-Webhook-Signature` (lower-cased to `ncr-webhook-signature`
  by the framework before dispatch)

**Ambiguity call** (verified in `8.AL.live.sandbox`):

- Exact header name (`NCR-Webhook-Signature` vs an Aloha-module-
  specific variant such as `NCR-Aloha-Signature`). The verifier
  treats the documented header as canonical; if the live shape
  differs, the bounded fix is a constant rename in
  `aloha_ncr_voyix_webhook_signature_verifier.dart`.

---

## Timestamp header

Header that carries the signing timestamp:

- **Header name**: `NCR-Webhook-Timestamp` (lower-cased to
  `ncr-webhook-timestamp` by the framework before dispatch)
- **Format**: Unix epoch (seconds)
- **Replay tolerance**: 24h per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

The timestamp header is optional per the documented subscription
shape. When absent, the framework skips replay defense for the event;
the
`(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE on
`inbound_webhook_idempotency` still prevents double-write.

---

## Constant-time compare

Adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles.

Verifier file:
`lib/integrations/pos/aloha_ncr_voyix_webhook_signature_verifier.dart`

---

## Auto-register endpoint

The vendor API endpoint the adapter calls to register the F&F webhook
URL:

- **Method + path**: `POST /events/v1/subscriptions`
- **Body** (documented shape; verified live):
  ```json
  {
    "url": "<f&f webhook url>",
    "events": ["aloha.check.opened", "aloha.check.modified"],
    "siteId": "<aloha site id>"
  }
  ```
- **Returns**: subscription ID (stored in
  `connector_connection.metadata.webhook_subscription_id`)

Events the adapter subscribes to:

- `aloha.check.opened` — operator opens a new check (covers,
  opened_at, siteId set; closedAt/totalAmount may be empty until
  close).
- `aloha.check.modified` — check is closed, voided, or otherwise
  updated (full canonical shape).

**Ambiguity call** (verified in `8.AL.live.sandbox`):

- Exact event-type strings. If vendor uses different names (e.g.,
  `aloha.order.opened`), the bounded fix is to update the `events`
  array; no code path change.
- Whether `aloha.check.modified` body is full or id-only. The adapter
  handles both via `fetchCheckById` for id-only payloads.

---

## Manual paste instructions

N/A — `webhookSupport = autoRegister`. The adapter registers the
subscription automatically on connect; operators do not paste a URL.

If `8.AL.live.sandbox` discovers the events bus does not deliver
Aloha check events, the bounded fix is to flip
`VendorCapabilityProfile.webhookSupport` to `pollOnly` and surface
"poll-only" copy in the picker chrome. The adapter's polling path is
already wired and tested (Test 1 + Test 6).
