# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Authentication
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: `POST /v1/oauth/token` (refresh)
- Notes: Adversarial scenario D. Libro's adapter has the OAuth refresh
  closure wired (per Phase 8R audit and `docs/integrations/libro/oauth_shape.md`).
  The fixture is not a vendor wire payload — it represents the
  pressure-test starting state of a `vendor_credentials` row whose
  `token_expires_at` is 55 minutes from issuance (i.e. inside the 1h
  access-token TTL). The shared cron at
  `lib/services/integration/oauth_refresh_cron.dart` MUST refresh
  proactively when `token_expires_at < now() + 24h`. Refresh issues a
  new access + refresh token via `POST /v1/oauth/token`; the new
  refresh token rotates the old one (rotating semantics per the OAuth
  shape doc). The harness's expected `vendor_credentials` row after
  refresh:
  - `token_expires_at` advanced by `expires_in` seconds.
  - `refresh_token` updated to the rotated value.
  - `consecutive_refresh_failures` reset to 0.
