# Source

- URL: https://developers.7shifts.com/reference/webhooks
- URL (verifier contract): see
  `docs/integrations/seven_shifts/webhook_signature.md`
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: inbound webhook delivery (`POST <f&f webhook url>`)
- Notes: adversarial Scenario A. Body itself is a documented
  `time_punch.edited` shape; the only thing wrong is the signature.
  The `_fixture_envelope` block carries the raw body string,
  signing secret, and provided base64 signature so the Phase 2
  adapter harness can call
  `SevenShiftsWebhookSignatureVerifier.verify` with the documented
  inputs. Verifier returns `valid=false`, `failureReason="X-7Shifts-Hmac-SHA256 HMAC mismatch"` per the verifier file's
  `constantTimeBytesEquals` check (line ~83). No DB write — the
  framework's inbound handler aborts before the adapter is invoked.
