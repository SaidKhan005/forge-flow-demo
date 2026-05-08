# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#authentication
- Verifier source: `lib/integrations/labor/quickbooks_time_webhook_signature_verifier.dart`
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: (no live webhook surface — `webhookSupport = pollOnly` per
  `api_consumed.md`; verifier exists as documented landing surface for any
  future Intuit webhook release)
- Notes: QuickBooks Time / Intuit does not currently expose a webhook
  delivery surface usable for schedule/punch changes (see
  `docs/integrations/quickbooks_time/webhook_signature.md` — single-line
  N/A). The adapter therefore declares `webhookSupport = pollOnly`. F&F
  ships `QuickBooksTimeWebhookSignatureVerifier` as a defense-in-depth
  surface against future router refactors and as the documented landing
  surface if Intuit ever releases QBT webhooks. The verifier implements
  Intuit's documented webhook signing convention used across other Intuit
  developer surfaces:

  - Algorithm: HMAC-SHA256 over the raw HTTP body bytes
  - Encoding: base64 (standard, with padding)
  - Header: `intuit-signature` (case-insensitive lookup)
  - Optional timestamp header: `intuit-t-hash` (Unix epoch seconds)

  This fixture carries a deliberately-malformed `intuit-signature` value —
  base64 that decodes cleanly but is the digest of a different secret /
  body. The verifier should return `WebhookSignatureVerification(valid:
  false, failureReason: 'HMAC mismatch on intuit-signature header')`. The
  raw_body shape mirrors the `timesheets[]` documented response so the
  adapter would otherwise be willing to accept it; rejection must come
  from the verifier, not the parser.
