# Source

- URL: https://developers.7shifts.com/reference/oauth
- URL (oauth-scopes): https://developers.7shifts.com/reference/oauth-scopes
- URL (refresh-cron): see
  `lib/services/integration/oauth_refresh_cron.dart`
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `POST /v2/oauth/token` with
  `grant_type=refresh_token` (rotating refresh per
  `docs/integrations/seven_shifts/oauth_shape.md` "Refresh
  semantics")
- Notes: adversarial Scenario D. 7shifts is an OAuth vendor so the
  refresh path is the credential-rotation path under test (per
  `docs/POST_HARDENING_FOLLOWUPS.md` 2026-05-08 confirmed-clean note).
  The fixture body is the documented token-refresh response (new
  `access_token` + new rotating `refresh_token` + 1h `expires_in`);
  the `_fixture_envelope` block describes the credential state that
  triggers the refresh (`token_expires_at` 7h ahead of `now` < the
  cron's 24h scan horizon). After refresh, the framework rotates
  ciphertext atomically (per OAuth refresh closure audit) — old
  refresh token revoked, new pair persisted under the SAME
  `connector_connection.id`. The full set of scopes mirrors
  `oauth_shape.md`'s Scopes table.
