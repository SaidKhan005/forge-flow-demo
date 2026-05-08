# Source

- URL: https://docs.clover.com/docs/using-oauth-20
- URL: https://docs.clover.com/docs/oauth-20-tokens
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `POST /oauth/v2/token` — token response shape returned
  to the proxy at the OAuth refresh closure.
  `access_token_expiration` is Unix-epoch seconds.
- Notes: this fixture represents a token with **`access_token_expiration
  = 1777750980` (2026-05-02T19:43:00Z)**, i.e. the access token
  expires inside the cron's `< now() + 24h` window relative to the
  reference clock. The refresh token is still valid for 30 days
  (`1780339380` = 2026-06-01T19:43:00Z). Per
  `docs/integrations/clover/oauth_shape.md`:
    - "Proactive refresh: cron at 5min past every hour scans
      `vendor_credentials` for tokens with `token_expires_at < now()
      + 24h` and refreshes via `POST /oauth/v2/token` with
      `grant_type=refresh_token`."
    - "Rotating per documented intent — each refresh issues a new
      refresh token; the old one is revoked."
- Adapter / framework cite:
  `lib/services/integration/oauth_refresh_cron.dart` (handler);
  `lib/integrations/pos/clover_credential_bridge.dart` (token swap);
  `lib/integrations/pos/clover_pos_postgres_credential_store.dart`
  (post-refresh persistence).
- Outcome: **Refresh path triggers**. Cron observes
  `token_expires_at < now() + 24h`, calls `POST /oauth/v2/token`,
  receives a new `(access_token, refresh_token, *_expiration)` tuple,
  rotates the credentials row, and revokes the old refresh token.
  Three consecutive refresh failures flip the connection to `error`
  per the documented edge case.
- Placeholder values: every secret is `<<TEST_BEARER>>` — no real
  Clover access tokens or refresh tokens present.
