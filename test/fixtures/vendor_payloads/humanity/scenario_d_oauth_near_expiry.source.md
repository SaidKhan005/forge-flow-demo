# Source

- URL: https://platform.humanity.com/v1.0/oauth2/token (documented in `docs/integrations/humanity/api_consumed.md` table line: "POST /oauth2/token — Legacy password-grant token issuance")
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: POST /v1.0/oauth2/token (`grant_type=password`)
- Notes:
  - Humanity v1 issues OAuth 2.0 RFC-6749 password-grant tokens with `access_token`, `token_type=Bearer`, `expires_in` (seconds), and an optional `refresh_token`.
  - Per `live_verification_checklist.md` "Token refresh" row: production tokens are long-lived; refresh cron is N/A. This near-expiry fixture (`expires_in: 120`) deliberately tests the failsafe path — the framework MUST detect the short window and trigger the proxy refresh closure on the next adapter call rather than allow a 401 mid-poll.
  - Refresh closure binding: `lib/integrations/labor/humanity_credential_bridge.dart` (per the post-wave audit, "OAuth refresh closure wired per audit"). The closure consumes the `refresh_token` and posts back to `/oauth2/token` with `grant_type=refresh_token`.
  - `client_id=forge_and_flow` is the F&F-side identifier the proxy presents per `oauth_shape.md` redirect (file is N/A — auth shape documented in `api_consumed.md`); body uses `application/x-www-form-urlencoded` per the OAuth 2.0 spec.
  - Plaintext password is REDACTED in the fixture (user-supplied at connect time only; never persisted beyond the proxy memory hop per HP #7).
- Outcome: proxy persists access_token + refresh_token in `vendor_credentials` (pgcrypto envelope); next adapter call sees `expires_at` within the 300s window → refresh closure fires before the poll request.
