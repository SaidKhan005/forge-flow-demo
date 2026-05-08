# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts (with tampered bearer)
- Notes: Push Operations has **no webhooks** per
  `docs/integrations/push_operations/webhook_signature.md` and
  `api_consumed.md`. The binding A-F set requires Scenario A to
  cover the "forged signature" reject path; this fixture substitutes
  the analogous reject path for a poll-only bearer-token vendor —
  a tampered (non-partner-issued) bearer presented to `/api/v1/shifts`
  must produce a 401 and the adapter's connection-state machine
  must surface `error` after 3 consecutive failures (per
  `live_verification_checklist.md` "Token refresh" row, which also
  covers the revoke path). The bearer string is a clearly-fake
  placeholder (`FORGED_NOT_PARTNER_ISSUED_...`) that no legitimate
  partner credential could match.

  Per `webhook_signature.md` (single-line N/A), the adapter's
  `handleWebhook` throws `UnsupportedError` and the framework
  router never dispatches a webhook to a poll-only adapter — so a
  literal "forged HMAC" payload is not authorable for this vendor.
  The substitution is documented at the per-vendor README's "Notes"
  section so the Phase 2A harness asserts the right behaviour.
