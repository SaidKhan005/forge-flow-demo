# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Webhooks
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: Adversarial scenario A. The body itself is a valid documented
  payload; the attached `X-Libro-Signature` header carries a hex
  candidate that does NOT match `HMAC-SHA256(signingSecret, "<t>.<body>")`.
  `LibroWebhookSignatureVerifier.verify` MUST return
  `WebhookSignatureVerification(valid: false, failureReason: 'signature mismatch')`
  per the `constantTimeBytesEquals` branch (line 81 of
  `lib/integrations/reservation/libro_webhook_signature_verifier.dart`).
  The framework's inbound webhook handler MUST short-circuit before any
  canonical write — no row in `reservation_facts`, no
  `connector_sync_log` success, just a `webhook_inbound_log.failure`
  row with `failure_reason = 'signature_mismatch'`.
