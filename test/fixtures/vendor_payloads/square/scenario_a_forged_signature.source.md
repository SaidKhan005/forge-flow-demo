# Source

- URL: https://developer.squareup.com/docs/webhooks/step3validate
- URL (envelope): https://developer.squareup.com/docs/webhooks/build-with-webhooks
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated` (signature forgery scenario).

## Adversarial scenario

Same body bytes as `happy_path_order_completed.json` (line items
trimmed for fixture compactness; the body shape itself is valid),
but the adversary signs with the WRONG secret OR flips a byte in
the signature header. The framework's webhook verifier MUST reject
before the adapter sees the payload.

## Required HTTP request shape (for Phase 2 harness)

```
POST /v1/integrations/square/webhook/{operatorId}/{locationId}
Content-Type: application/json
x-square-hmacsha256-signature: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
square-initial-delivery-timestamp: 2026-05-08T18:45:01Z
x-ff-notification-url: https://api.forgeflow.app/v1/integrations/square/webhook/op_001/loc_001

<<body bytes from scenario_a_forged_signature.json>>
```

The `x-square-hmacsha256-signature` value above is a 32-byte
all-zero HMAC base64-encoded. It will NEVER match
`HMAC-SHA256(notification_url || raw_body, signing_secret)` for any
non-trivial secret and body. Phase 2 harnesses MAY also test with
a signature computed using a different secret than the one bound to
the Square connection — same outcome.

## Adapter assertions

1. `SquareWebhookSignatureVerifier.verify(...)` returns
   `WebhookSignatureVerification.invalidSignature`.
2. `InboundWebhookHandler` returns HTTP 401 (signature mismatch),
   and writes an audit row with `actor_kind = 'sp:square'`,
   `outcome = 'rejected_signature_mismatch'`.
3. `factWriter.upsertSalesFact` is NEVER called (zero DB writes).
4. `inbound_webhook_idempotency` UNIQUE row is NEVER inserted —
   verification precedes idempotency persistence.

## Field-level edits

The body is a trimmed variant of the happy-path order. Only the
HTTP signature header is forged; the JSON itself is structurally
valid Square Order shape.

Field paths verbatim per Square's published Order object reference.
