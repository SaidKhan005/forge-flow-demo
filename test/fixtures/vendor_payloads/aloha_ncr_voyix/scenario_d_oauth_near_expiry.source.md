# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: `POST /oauth2/token`, grant `client_credentials`, scope
  set per `oauth_shape.md`.
- Notes: Adversarial scenario D. Aloha (NCR Voyix) IS an OAuth
  vendor (per audit confirmation 2026-05-08). The fixture mirrors
  `oauth_shape.md`:
  - Access-token TTL documented at 1h.
  - No refresh token — `client_credentials` re-mints by replaying
    the credentials envelope.
  - Proactive refresh cron at 5min past every hour, scanning for
    `token_expires_at < now() + 24h`.
  Placeholders are intentionally non-secrets
  (`PLACEHOLDER_CLIENT_ID`, `PLACEHOLDER_CLIENT_SECRET`). Phase 2
  harness asserts the cron's re-mint flow without ever holding a
  real secret.
- Sourcing note: scope strings ARE documented in `oauth_shape.md`
  (`aloha:checks.read`, `aloha:sites.read`,
  `events:subscriptions.write`, `events:subscriptions.delete`)
  rather than retrieved from a public NCR Voyix portal page; the
  scope namespace `aloha:*` is documented at the portal landing
  but per-API exact strings are gated. Marked here for the
  partner-portal escalation list.
