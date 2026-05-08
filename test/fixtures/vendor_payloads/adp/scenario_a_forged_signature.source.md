# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (ADP Marketplace event-subscription envelope)
- Endpoint: inbound webhook `POST /v1/webhooks/{operator}/{location}/adp`
- Notes: forged-signature scenario for binding A. Header / algorithm /
  encoding follow the assumed shape captured in
  `lib/integrations/labor/adp_webhook_signature_verifier.dart`
  (`HMAC-SHA256` over raw body bytes, base64-encoded in
  `ADP-Signature`). The signature value here is a base64 string of
  the wrong digest (literal "expected-hmac-value-that-is-actually-forged");
  the verifier returns `WebhookSignatureVerification(valid: false,
  failureReason: 'ADP-Signature HMAC mismatch')` and the inbound
  handler refuses to dispatch to the adapter — no DB write. Partner-
  only sourcing; ADP-Signature header / algorithm flagged
  `verify_in_live_sandbox: true` in
  `docs/integrations/adp/webhook_signature.md`.
