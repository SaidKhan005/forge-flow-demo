# Source

- Primary URL: <https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html#signing>
- Retrieved: 2026-05-08
- Algorithm: HMAC-SHA256 over raw body, base64-encoded, delivered
  in `Toast-Signature` header (per `webhook_signature.md`).

## Notes

- Body is byte-identical to `happy_path_order_closed.json` minus
  optional fields (kept minimal so test diffs stay focused on the
  signature outcome).
- `toast-signature` is a literal base64 string (`fake-signature-...`)
  that decodes to bytes that cannot match any HMAC of the body
  computed with `<<TEST_HMAC_SECRET>>` (or any secret).
- The framework's `ToastWebhookSignatureVerifier` calls
  `constantTimeBytesEquals` (per `webhook_signature.md`); the
  comparison MUST return false and the framework MUST reject the
  inbound webhook before the adapter's `handleWebhook` method runs.

## Sourcing fallback

Same in-repo curated sources as the happy paths. The signature
algorithm itself is documented in `webhook_signature.md` cited from
`apiWebhooksOverview.html`.

## Expected adapter behavior

- Framework rejects at signature verification step (step 3 of
  `InboundWebhookHandler.dispatch`).
- `handleWebhook` is NEVER invoked.
- No row written via `upsertOrderFact`.
- Audit log records signature-verification failure.
