# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: N/A (Agendrix v2 does not document a webhook delivery
  surface — `webhook_signature.md` reads "N/A — vendor does not support
  webhooks per `api_consumed.md`")
- Notes: Defense-in-depth fixture for the documented webhook signature
  verifier at
  `lib/integrations/labor/agendrix_webhook_signature_verifier.dart`
  (Phase 8.gap-1, `documented` lifecycle). Headers + body shape mirror
  the assumed industry-standard SaaS partner convention captured in
  the verifier source: HMAC-SHA256 over raw body, base64-encoded in
  `X-Agendrix-Signature`, optional `X-Agendrix-Timestamp` Unix epoch
  seconds.

  The `_transport.headers["x-agendrix-signature"]` value is a
  base64-encoded random 32-byte digest that does NOT match the HMAC of
  the body under the published signing secret — the verifier MUST
  return `valid = false` with `failureReason` containing "mismatch"
  (per `agendrix_webhook_signature_verifier_test.dart`). Even if a
  future Agendrix release flips webhooks live, the
  `capabilityProfile.webhookSupport = pollOnly` gate in the
  `InboundWebhookHandler.dispatch` router means the framework never
  reaches the adapter — the verifier-level rejection is the
  belt-and-suspenders boundary.
