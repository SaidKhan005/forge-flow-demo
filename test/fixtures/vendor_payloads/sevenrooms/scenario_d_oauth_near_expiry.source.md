# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (auth endpoint shape `POST /2_2/auth`)
- Fallback URL: https://docs.kleene.ai/docs/sevenrooms (Kleene SevenRooms connector — confirms partner client_id + client_secret + venue_id triple)
- Internal contract: docs/integrations/sevenrooms/oauth_shape.md, docs/POST_HARDENING_FOLLOWUPS.md 2026-05-08 confirmed-clean note ("SevenRooms — transport")
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: `POST /2_2/auth` (token re-exchange)
- Notes: SevenRooms is in the six-vendor "no broker refresh closure" set per `test/fixtures/vendor_payloads/README.md` Non-OAuth Vendor Note. The substitute scenario for this vendor is **transport-layer credential re-exchange** — the proxy / transport layer re-issues a bearer by re-exchanging the persisted client_id + client_secret + venue_id at `POST /2_2/auth`. The fixture models a token with 90 seconds of TTL remaining; the adapter's refresh cron at hour:05 (per `oauth_shape.md` Refresh semantics) catches `token_expires_at < now() + 24h` and triggers re-exchange. The only adapter-side state changes are (1) a new `cred-sr-bearer-*` credential id replacing the old one in `vendor_credentials`, (2) a `connector_sync_log` event row with `event_kind = 'token_refresh'`. Phase 2 harness assertions: rotation_inputs ciphertext unchanged; new bearer credential id replaces old; connection status remains `connected`.
