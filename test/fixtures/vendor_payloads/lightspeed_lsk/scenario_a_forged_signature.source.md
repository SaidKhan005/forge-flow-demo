# Source

- URL (algorithm reference, family-wide HMAC pattern):
  - <https://api-docs.lsk.lightspeed.app/operation/operation-apecreatewebhookoo>
  - <https://apidoc.kounta.com/webhooks/>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`) + webhook delivery (raw body
  HMAC-SHA256, hex lowercase) per
  `docs/integrations/lightspeed_lsk/webhook_signature.md`.
- Endpoint: inbound webhook delivery — `POST <fnf-webhook-url>` with
  request body shaped per `order.DELIVERED` event.
- Notes:
  - The `_pressure_envelope` field at the top of the JSON is fixture
    metadata only — it is NOT part of the vendor's wire payload.
    Phase 2 harness strips `_pressure_envelope` before passing the
    bytes to `LightspeedLskWebhookSignatureVerifier`.
  - The `x-lightspeed-signature` header value is 64 hex zeros: a
    forgery. HMAC-SHA256 over the raw body with the documented
    family-wide signing pattern will not produce all zeros for any
    practical signing secret.
  - Body shape mirrors `standardLightspeedLskWebhookPayload(...)` in
    `test/integrations/pos/fixtures/lightspeed_lsk_webhook_fixture.dart`:
    `accountFiscId`, `nbCovers`, `payments[]`, `timeOfOpening`,
    `timeClosed` — the shape `_projectCanonicalRecord` would have
    accepted if the signature passed.
  - Header name `X-Lightspeed-Signature` per
    `lightspeed_lsk_webhook_signature_verifier.dart`
    (`kLightspeedLskSignatureHeader`); lowercased in the framework
    map per `InboundWebhookHandler.dispatch` convention.
- Expected outcome: signature verifier rejects with
  `SignatureMismatch`. Adapter never invoked. No canonical fact row
  written. One audit row in `connector_sync_log` with
  `event_kind = 'signature_reject'`.
