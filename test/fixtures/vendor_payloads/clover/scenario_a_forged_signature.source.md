# Source

- URL: https://docs.clover.com/dev/docs/webhooks
- URL: https://docs.clover.com/docs/using-webhooks
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: Inbound webhook delivery — body is a valid
  documented-shape Clover envelope, BUT the
  `X-Clover-Auth-Signature` header has been swapped to a base64
  signature computed with a different HMAC secret.
- Adapter cite:
  `lib/integrations/pos/clover_webhook_signature_verifier.dart`
  → `kCloverSignatureHeader = 'x-clover-auth-signature'`,
  `constantTimeBytesEquals` from
  `lib/services/integration/inbound_webhook_handler.dart`.
- Outcome: **Reject**. Signature verification fails before the
  envelope is parsed; no `CloverApiClient.getOrder` call, no DB
  write, no idempotency row claimed. Audit log records the
  rejection with `audit_logs.actor_kind = 'sp:vendor_clover'` and
  `event = 'webhook_signature_mismatch'`.
- Notes: the `_transport.raw_body_signed_with` field is a fixture-only
  hint to the Phase 2 harness; the harness uses it to construct the
  forgery deterministically. The fixture body keys above the
  `_transport` block are otherwise valid documented shape so the test
  proves the verifier rejects on signature alone (not on body shape).
- Placeholder values: `<<TEST_HMAC_SECRET>>` and
  `<<TEST_HMAC_SECRET_DIFFERENT_KEY>>` — no real Clover signing
  secrets present.
