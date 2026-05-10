# Source

- URL (auth doc): https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html
- URL (api consumed): docs/integrations/oracle_micros_simphony/api_consumed.md
- URL (webhook policy): docs/integrations/oracle_micros_simphony/webhook_signature.md
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Endpoint: POST `/sim/api/v2/posData/getGuestChecks` (auth-failure response)

## Sourcing gap (this fixture is a substitute, not a forged-signature payload)

Oracle MICROS Simphony's documented public API does **not** expose a webhook
delivery surface — see `webhook_signature.md` (single line: "N/A — vendor
does not support webhooks"). The F&F adapter is `webhookSupport = pollOnly`
and `handleWebhook` throws `UnsupportedError` (verified at
`lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart:411-419`).

There is no body-signature verifier in the adapter to forge against. The
binding A-F set's "Scenario A — forged signature" therefore has no
literal analogue for this vendor. This fixture documents the closest
analogous failure: a poll-side response body that arrives with auth
credentials whose bearer access token has been revoked at the Simphony
partner portal.

The fixture marks `_sourcing_gap` so the harness knows the substitution.

- Adapter assertion at this fixture (Phase 2 harness):
  - Adapter's `pollIncremental` poll path treats HTTP 401 with
    `error: "invalid_token"` as an auth failure (not zero rows).
  - First failure triggers a token refresh via the documented
    `client_credentials` flow against `POST /sim/api/v2/oauth/token`.
  - On continued 401 (partner-portal revocation, secret rotated),
    after 3 consecutive failures the framework's OAuth refresh cron
    flips `connector_connection.status = error` and writes an audit
    row. See `docs/integrations/oracle_micros_simphony/oauth_shape.md`
    "Refresh semantics".
- **No canonical fact write occurs** at any 401 response — the empty
  `items[]` is what the adapter parses if it (incorrectly) treats 401 as
  empty page; the harness must catch that mistake.
- Phase 5 escalation: partner-portal access required to obtain a real
  webhook contract if Simphony adds one in a future Gen2 revision; track
  in `partnership_status.md` "Application status" updates.
