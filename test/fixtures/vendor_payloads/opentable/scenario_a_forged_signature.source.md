# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified`; signature shape per
  `docs/integrations/opentable/webhook_signature.md` (header
  `X-OpenTable-Signature`, algorithm `HMAC-SHA256`, encoding
  `hex_lower`, signed payload = raw body bytes — every section
  flagged "verify in `8R.OT.live.sandbox`").
- Notes: Adversarial scenario A tests the verifier
  (`lib/integrations/reservation/opentable_webhook_signature_verifier.dart`)
  rejection path. The `_fixture_meta.headers["X-OpenTable-Signature"]`
  value is a fabricated 64-character hex string that will not match
  the HMAC-SHA256(`signing_secret`, `raw_body`) digest the verifier
  computes. Phase 2 harness recomputes the expected digest from
  `_fixture_meta.signing_secret` + `_fixture_meta.raw_body` and asserts
  the supplied `X-OpenTable-Signature` differs → verifier rejects via
  `WebhookSignatureVerification.invalid`. The reservation body itself
  is valid (matches `happy_path_reservation_booked` modulo id) so the
  test isolates the signature-verification failure from canonicalizer
  failure.
- Adapter assertion (Phase 2): `OpenTableWebhookSignatureVerifier`
  returns mismatch; framework's `InboundWebhookHandler` rejects at
  step 1 (signature) and never reaches the adapter. Sink assertion:
  no DB write to `reservation_facts` or
  `inbound_webhook_idempotency`.
