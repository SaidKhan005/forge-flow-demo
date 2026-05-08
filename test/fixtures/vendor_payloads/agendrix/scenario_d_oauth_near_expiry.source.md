# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: POST /v2/oauth/token
- Notes:

  **Sourcing discrepancy disclosed up-front.** The `pressure.preview.v1`
  Phase 1 README's non-OAuth vendor list (line 84-94 of
  `test/fixtures/vendor_payloads/README.md`) labels Agendrix
  "static key", and the prompt mirrors that. The per-vendor doc pack
  ships in this repo says **OAuth 2.0 authorization-code with sliding
  refresh** —
    * `docs/integrations/agendrix/api_consumed.md` line 16-31:
      `authMode = oauth`, `POST /v2/oauth/token`.
    * `docs/integrations/agendrix/oauth_shape.md` (entire file):
      authorization-code grant, sliding-refresh rotation, ~1h access
      TTL, proactive refresh `pg_cron` 5 minutes past the hour.
    * `lib/integrations/labor/agendrix_labor_adapter.dart` line 26-28:
      "Auth: OAuth 2.0 authorization code".
    * `agendrix_punches_fixture.dart` `documented_per_agendrix_v2`
      `auth_mode = 'oauth (authorization code; bearer access token)'`.

  This fixture honors the doc-pack source-of-truth (OAuth) over the
  Phase 1 README's stale-as-of-today line. If the README is correct
  and the doc-pack drifts, Phase 1 closeout should flag it back to
  the integrations lane — the binding is `field_mapping.md` +
  `oauth_shape.md` per the per-vendor doc pack contract, not the
  README's vendor list.

  **Documented refresh shape captured.** OAuth 2.0 standard
  `application/x-www-form-urlencoded` body to `POST /v2/oauth/token`
  with `grant_type = refresh_token`. Response includes a fresh
  `access_token` and a fresh `refresh_token` (sliding rotation per
  `oauth_shape.md`); the prior refresh token is invalidated server-side.

  **Trigger.** `_credential_state.expires_at_utc` is 44 minutes after
  `now_utc`, which is inside the documented "refresh proactively at
  `expires_at - 1h`" window from `oauth_shape.md`. Phase 2 OAuth-refresh
  storm harness (3C) replays this fixture against the proxy refresh
  closure to prove the new tokens land in `vendor_credentials` and
  the prior refresh token is invalidated.

  **Static-key rotation analog (if discrepancy resolves the other
  way).** If a future audit confirms Agendrix is in fact static-key,
  this fixture's `_credential_state` block is replaced with a
  vendor-portal API-key-rotation event payload — out-of-band rotation,
  no refresh closure on F&F's side, the operator pastes the new key
  into the admin widget. The poll loop then reads from the rotated
  key on the next tick. Recorded here for completeness.
