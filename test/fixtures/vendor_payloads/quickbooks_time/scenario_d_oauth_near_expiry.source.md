# Source

- URL: https://developer.intuit.com/app/developer/qbo/docs/develop/authentication-and-authorization/oauth-2.0#step-3-exchange-authorization-code-for-access-token
- Auxiliary URL: https://tsheetsteam.github.io/api_docs/?javascript#authentication
- Retrieved: 2026-05-08
- API version: Intuit OAuth 2.0 (used by QuickBooks Time)
- Endpoint: POST https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer
- Notes: Documented Intuit OAuth 2.0 bearer-token response shape — fields
  `access_token`, `refresh_token`, `expires_in` (seconds), `token_type`,
  `x_refresh_token_expires_in`, `scope`, and `realm_id`. Intuit's
  documented token lifetimes are 1h for the access token and 100 days
  (rotating) for the refresh token; this fixture sets both very low
  (`expires_in = 300`, `x_refresh_token_expires_in = 360`) to model the
  near-expiry path that `oauth_refresh_cron.dart` triggers when
  `token_expires_at < now() + 24h`. On rotation a NEW refresh token is
  issued and the old one is revoked. The `realm_id` is the operator-wide
  Intuit realm; per `oauth_shape.md` it is persisted on
  `connector_connection.metadata.intuit_realm_id`. Wave 1 launch vendor —
  this is the credential rotation surface that `8.S.QBT.live.sandbox`
  exercises end-to-end.
