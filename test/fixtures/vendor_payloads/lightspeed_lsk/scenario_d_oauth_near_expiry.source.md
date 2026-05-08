# Source

- URL: <https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>
- Retrieved: 2026-05-08
- API version: V2 OAuth (Lightspeed K-Series).
- Endpoint: `POST /oauth/token` with
  `grant_type=refresh_token` (Authorization: Basic
  base64(client_id:client_secret)).
- Notes:
  - Body shape carried verbatim from the Authorization Overview
    page's documented token response: `access_token`, `expires_in`,
    `refresh_expires_in`, `refresh_token`, `token_type`,
    `not-before-policy`, `session_state`, `scope`.
  - `expires_in = 1500` (25 minutes) per the documented access-token
    TTL.
  - `refresh_expires_in = 3456000` seconds (40 days) — documented
    refresh TTL when `offline_access` scope is granted.
  - `scope = "orders-api financial-api offline_access"` — the three
    scopes the adapter requests per
    `docs/integrations/lightspeed_lsk/oauth_shape.md`.
  - All token values are placeholder strings (`placeholder.*`)
    matching the documented JWT-ish prefix shape (`eyJhbGciOi...`)
    but truncated. No real bearer is reproduced.
- Closure expectation:
  - `oauth_refresh_cron` (5 min past every hour) selects every
    `vendor_credentials` row where
    `token_expires_at < now() + 24h`.
  - `LightspeedLskOAuthClient.refresh()` POSTs the request shape
    above; on 200, the response decodes to
    `LightspeedLskTokenExchangeResult`.
  - **Rotating refresh**: the response's `refresh_token` REPLACES
    the prior ciphertext atomically; the old refresh token is
    invalidated by the vendor.
  - **3-strike gate**: 3 consecutive refresh failures flip
    `connector_connection.status` to `error`. Email notification
    deferred to `9.8.email`.
- Expected harness assertion: refresh request body matches the
  documented `grant_type=refresh_token` form; the gateway writes a
  new envelope with the new ciphertext IDs; `connector_sync_log`
  records `event_kind = 'token_refresh'`.
