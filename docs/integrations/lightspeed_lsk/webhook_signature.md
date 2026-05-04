# Lightspeed Restaurant K-Series — Webhook Signature

**Vendor ID**: `lightspeed_lsk`
**Source documentation**:
- Create Webhook (orders/payments): <https://api-docs.lsk.lightspeed.app/operation/operation-apecreatewebhookoo>
- Create Webhook (staff): <https://api-docs.lsk.lightspeed.app/operation/operation-staff-apicreatewebhook>
- Family-wide HMAC pattern (X-Series, Kounta, O-Series): see
  <https://o-series-support.lightspeedhq.com/hc/en-us/articles/31329267751707-HMAC-Tips-for-Webhooks>
  and <https://apidoc.kounta.com/webhooks/>
**Retrieval date**: 2026-05-03

The K-Series public Create-Webhook reference does not enumerate the
signature mechanism in the publicly fetched portion of the docs as
of the retrieval date. The verifier is built against the documented
pattern shared by the Lightspeed family (HMAC-SHA256 over raw body,
hex-encoded). The exact header name + encoding live in the Ambiguity
calls below; the `8.LSK.live.sandbox` slice will diff observed vs
documented and adjust if needed.

---

## Algorithm

`HMAC-SHA256`.

Cite family-wide doc:
<https://o-series-support.lightspeedhq.com/hc/en-us/articles/31329267751707-HMAC-Tips-for-Webhooks>
(O-Series declares HMAC-SHA256 over raw body; the K-Series and
Kounta family follow the same pattern per
<https://apidoc.kounta.com/webhooks/>).

---

## Signed payload

`raw body`. The verifier computes the digest over the request body
bytes verbatim. The framework's
`InboundWebhookHandler.dispatch` preserves the raw bytes through the
request pipeline (no JSON re-serialization before HMAC).

---

## Encoding

`hex (lowercase)`.

Case sensitivity: yes — uppercase hex is rejected. The verifier
documents the contract strictly; `8.LSK.live.sandbox` will confirm
casing on real webhook deliveries.

---

## Header name

`X-Lightspeed-Signature` (case-insensitive on the wire; the framework
lowercases all incoming headers before lookup).

The verifier reads `headers['x-lightspeed-signature']` per the
framework's lowercase-key convention.

---

## Timestamp header

Header that carries the signing timestamp:

- **Header name**: `X-Lightspeed-Timestamp`
- **Format**: Unix epoch (seconds)
- **Replay tolerance**: 24 hours per V1 lean cut 2 (see
  `lib/services/integration/inbound_webhook_handler.dart`
  `kInboundWebhookReplayCeiling`).

If the vendor delivery does not include this header, the verifier
returns valid without a timestamp; the framework's replay defense
becomes a no-op for that delivery (idempotency UNIQUE on
`(vendor_id, operator_id, vendor_event_id)` still prevents
double-write).

---

## Constant-time compare

The adapter uses `constantTimeBytesEquals` from
`lib/services/integration/inbound_webhook_handler.dart` to avoid
timing oracles. The implementation lives in
`lib/integrations/pos/lightspeed_lsk_webhook_signature_verifier.dart`
(class `LightspeedLskWebhookSignatureVerifier`). Tests:
- Tampered HMAC rejection: `test/integrations/pos/lightspeed_lsk_pos_adapter_test.dart`
  group `LightspeedLskPosAdapter` test "signature reject".
- Replay window 24h: `test/integrations/pos/lightspeed_lsk_pos_adapter_test.dart`
  group `LightspeedLskPosAdapter` test "replay window".
- Header / encoding edges: `test/integrations/pos/lightspeed_lsk_pos_adapter_test.dart`
  group `LightspeedLskWebhookSignatureVerifier`.

---

## Auto-register endpoint

The adapter auto-registers the webhook on connect via
`PUT /o/wh/1/webhook`:

- **Method + path**: `PUT https://api.lsk.lightspeed.app/o/wh/1/webhook`
- **Body**:
  ```json
  {
    "endpointId": "forge-flow-lsk",
    "url": "<f&f webhook url>",
    "subscribeTo": [
      { "resource": "order", "events": ["DELIVERED", "FAILURE", "READY_FOR_PICKUP", "CANCELLED"] },
      { "resource": "payment", "events": ["SUCCESS", "FAILURE"] },
      { "resource": "account", "events": ["CLOSED", "CHECK_WAS_UPDATED"] }
    ],
    "expandPayments": true
  }
  ```
- **Returns**: subscription id (stored in
  `connector_connection.metadata.webhook_subscription_id`) plus a
  signing-secret credential reference (handled opaquely by the
  gateway; the adapter never sees the plaintext secret).

Events the adapter subscribes to:

- `order.DELIVERED` / `order.FAILURE` / `order.READY_FOR_PICKUP` /
  `order.CANCELLED` — close + invalidate canonical sale rows.
- `payment.SUCCESS` / `payment.FAILURE` — refresh sale `actual_sales`
  on payment events.
- `account.CLOSED` / `account.CHECK_WAS_UPDATED` — capture
  account-close events for `vendor_modified_at` updates.

---

## Manual paste instructions

N/A — Lightspeed K-Series supports auto-registration; the operator
never pastes a URL or signing secret.

---

## Ambiguity calls

The `8.LSK.live.sandbox` slice MUST verify these first:

- **Exact header name**: documented as `X-Lightspeed-Signature` based
  on the family pattern; sandbox-observed value may differ slightly
  (Kounta uses `X-Kounta-Signature`; the K-Series brand-renamed
  header may use a different casing). If observed differs, the fix
  is a one-line constant change in
  `lightspeed_lsk_webhook_signature_verifier.dart`
  (`kLightspeedLskSignatureHeader`).
- **Whether timestamp is part of the signed payload**: documented as
  raw-body-only HMAC. If sandbox shows the family-wide pattern of
  `<timestamp>.<body>` concatenation, the verifier needs a small
  patch to prepend the timestamp before HMAC.
- **Encoding casing**: documented as lowercase hex; if observed value
  is uppercase, relax the parser.
