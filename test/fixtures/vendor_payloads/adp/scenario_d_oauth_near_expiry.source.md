# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
  and <https://www.adp.com/marketplace>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: `POST /auth/oauth/v2/token` (assumed) under mutual TLS
- Notes: this fixture intentionally documents a NON-EVENT for binding
  D. ADP production runs `oauth_2.0_client_credentials + mutual_tls`
  per `docs/integrations/adp/api_consumed.md` and the Phase 8.S
  scheduling-connector plan. The `client_credentials` flow is
  per-call (no rotating refresh token), so the framework's
  `oauth_refresh_cron` (`lib/services/integration/oauth_refresh_cron.dart`)
  has no ADP rows to refresh — there is no broker refresh closure
  for ADP. The auth-method assumption in
  `docs/integrations/adp/oauth_shape.md` (`authorization_code` with
  rotating refresh tokens) is the *engineering-time* assumption for
  the documented slice; the production wiring documented in
  `api_consumed.md` is `client_credentials + mTLS`, and the live
  slice will reconcile the two at `8.S.ADP.live.sandbox` /
  `8.S.ADP.live.prod`.
- mTLS cert rotation is owned by ADP partner ops (out-of-band of
  F&F). When the cert pair nears expiry, partner ops issues a new
  pair and the operator-scoped `VendorCredentialHandle` is updated
  at the proxy. This fixture exists to record that expectation so
  the Phase 2 harness asserts the `oauth_refresh_cron` correctly
  skips ADP rows (no `refresh_token` exists) and the proxy surfaces
  near-expiry as a `connector_connection.status = error` flip with
  the operator copy locked in `oauth_shape.md` "Edge cases". This is
  a partner-portal escalation candidate — the partner doc pins the
  exact rotation cadence and the cert-near-expiry notice channel
  (assumed: ADP partner ops emails the operator's ADP admin; F&F
  surfaces a passive status flip).
