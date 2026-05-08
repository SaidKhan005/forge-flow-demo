# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks (OAuth section linked from the developer portal authentication page; same retrieval root)
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: `POST https://authentication.revelup.com/oauth/token` with `grant_type=client_credentials`, `client_id`, `client_secret`, `audience=https://api.revelsystems.com` (form-urlencoded body).
- Notes:
  - Revel uses OAuth `client_credentials` server-to-server. The grant returns a JWT bearer with TTL 86,400s (24h). There is no refresh token. Per `docs/integrations/revel/oauth_shape.md` "Refresh semantics", a "refresh" is a fresh `client_credentials` exchange of the same stored pair via `RevelOAuthRefresher` in `lib/integrations/pos/revel_pos_adapter.dart`.
  - `pg_cron` at 5 minutes past every hour runs `proxy.refresh_expiring_inbound_vendor_tokens()`; rows with `token_expires_at < now() + interval '24 hours'` are selected. Revel tokens enter this window immediately on issue (24h TTL) so a fresh exchange happens every hour during normal operation.
  - The OAuth audit closure is wired per `docs/POST_HARDENING_FOLLOWUPS.md` (2026-05-08 audit-additions item, marked resolved): per-vendor refresher returns `VendorRefreshOutcome.success/failure` and the framework writes `audit_logs` rows on both paths.
  - Phase 2 harness assertion: with `now = 2026-05-08T19:00:00Z` and `token_expires_at = 2026-05-08T19:55:00Z`, the row is inside the horizon. Refresher invokes `_transport.exchangeClientCredentials`, gateway re-encrypts the new access token, `consecutive_refresh_failures` resets to 0, audit row written.
  - Three consecutive failures flip `connector_connection.status = 'error'` per V1 lean cut 2 (no email auto-disable, no advisory lock). `audience` parameter mismatch path is documented in `oauth_shape.md` "Edge cases".
  - JWT body `access_token` value is illustrative — header / payload base64 segments are placeholder JSON; `.REDACTED_SIGNATURE` is the third JWS segment. No real signing key exists for this fixture.
