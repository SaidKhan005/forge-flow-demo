# SevenRooms — OAuth Shape

**Vendor ID**: `sevenrooms`
**Source documentation**:
- Auth endpoint confirmation (Airship guide):
  <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms>
- Partner API portal (account-rep gated):
  <https://api-docs.sevenrooms.com/>

**Retrieval date**: 2026-05-04

---

## Flow type

`client_credentials` (partner-issued client_id + client_secret +
venue_id; exchanged at `POST /2_2/auth` for a bearer access token).

The capability profile sets `authMode = oauthOrKeyPaste` so the
connect-flow UI can render either an OAuth surface (browser-driven)
or a keypaste surface (operator pastes credentials directly). At V1
the keypaste surface is the only path SevenRooms exposes — no
authorization-code redirect flow is documented.

The adapter never uses an interactive authorization-code flow for
SevenRooms; every grant is a partner-credential exchange.

---

## Scopes requested

SevenRooms partner credentials are scoped at the venue level by the
account rep at issuance time (not via runtime scope strings). The
operator's credential pack carries:

| Field | Source | Purpose |
|---|---|---|
| `client_id` | account-rep onboarding | Partner identity |
| `client_secret` | account-rep onboarding | Bearer-token issuance |
| `venue_id` | account-rep onboarding | Per-venue scope; matches `connector_connection.metadata.venue_id` |

Scope downgrade is not a runtime concern at V1 because scopes are
provisioned at credential issuance. The `8R.SR.live.sandbox` slice
will confirm whether `POST /2_2/auth` echoes a `scopes` claim in the
response (some partner APIs do; SevenRooms' shape is not publicly
documented).

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token (bearer) | not publicly documented | Treat as short-lived (≤ 1h); refresh proactively at every poll if `expires_at` claim absent |
| Refresh token | n/a — partner client-credentials flow re-exchanges client_id + client_secret on expiry |

The `8R.SR.live.sandbox` slice will measure observed TTL and update
this row.

---

## Refresh semantics

- **Proactive refresh**: cron at 5 minutes past every hour scans
  `vendor_credentials` for tokens with
  `token_expires_at < now() + 24h` and refreshes via `POST /2_2/auth`
  (re-exchanging the persisted client_id + client_secret + venue_id
  triple). See `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: connection status flips to `error`;
  audit row written. Email notification is deferred to the
  `9.8.email` follow-up per V1 lean cut 2.
- **Rotating vs sliding**: client-credentials flow has no rotating
  refresh token; the persisted client_id + client_secret stays in
  `vendor_credentials` ciphertext and re-issues a fresh bearer on
  each refresh.
- **Revocation**: SevenRooms does not document a revoke endpoint in
  the publicly fetched portion of the docs. The
  `SevenRoomsAuthClient.revoke` seam exists so the production impl
  can call one if it emerges from the partner portal; the default
  no-op revoke is adequate for sandbox / V1 because operator-side
  removal of the F&F integration in the SevenRooms admin portal
  invalidates the credentials upstream.

---

## Refresh handling (broker delegation)

**Status (2026-05-09 — P1 closeout)**: WIRED via
`makeSevenRoomsOauthRefreshClosure` in
`lib/integrations/_common/production_oauth_refresh_closures.dart`.

### What changed

The follow-up slice that the prior version of this section flagged as
out-of-scope (persist `client_secret` + `venue_id` on metadata + wire
a `client_credentials` closure) has now landed. Specifically:

- `SevenRoomsBrokerCredentialStore.persistIssuedBearerToken`
  (`lib/integrations/reservation/sevenrooms_credential_bridge.dart`)
  now writes `client_id`, `client_secret`, AND `venue_id` to
  `vendor_credentials.metadata` via `metadataPatch`. The pgcrypto
  envelope already protects the metadata column at rest.
- `SevenRoomsCredentialStore.persistIssuedBearerToken` interface
  (`sevenrooms_reservation_production_api_client.dart`) gained a
  `clientSecret` parameter.
- `SevenRoomsAuthProductionApiClient.authenticate(...)` now threads
  `clientSecret` into the persist call.
- `makeSevenRoomsOauthRefreshClosure` POSTs
  `{client_id, client_secret, venue_id, grant_type: client_credentials}`
  to `/2_2/auth` and returns the freshly-minted bearer in
  `TokenRefreshResult.accessToken`. `refreshToken` is left null
  because `client_credentials` does not rotate a refresh token.
- `tool/oauth_refresh_worker/main.dart` removed SevenRooms from
  `kVendorsWithoutRefreshClosureReason` and added it to the
  unconditionally-wired set in `buildProductionRefreshClosures`
  (mirrors the ADP / OpenTable pattern — no app-wide secrets, all
  per-tenant on metadata).

### Behavior at runtime

- **New connections (post 2026-05-09)**: connect-flow persists all
  three credential fields. Worker refreshes the bearer broker-side
  via `makeSevenRoomsOauthRefreshClosure`. Standard atomic-rotation +
  per-tenant Future-lock + `consecutive_refresh_failures` counter
  contracts apply (same as ADP / OpenTable).
- **Legacy rows (pre 2026-05-09)**: persisted only `client_id`. The
  closure's `_requireMetadataString` throws
  `missing_credential: bundle has no \`client_secret\`; operator must
  reconnect`, which the broker's failure-handling path surfaces to the
  operator as a reconnect prompt — same UX as every other
  missing-credential case. Operator reconnects through the keypaste
  modal once; the new persist path populates `client_secret` +
  `venue_id` and broker-driven refresh takes over.
- **Disconnect**: SevenRooms publishes no revoke endpoint per the
  earlier note. `SevenRoomsAuthClient.revoke` no-ops; operator
  removing the F&F integration in SevenRooms invalidates upstream.

### Earlier reasoning (retained for context)

PR #455 (2026-05-09 morning) initially placed SevenRooms on
`kVendorsWithoutRefreshClosureReason` under
`sevenrooms_transport_cron_hour05` (assumed a transport-layer cron
existed). PR #465 (2026-05-09 afternoon) re-investigated and refined
the reason to `sevenrooms_client_secret_not_persisted` (verified no
cron existed; the real gap was the bridge dropping `client_secret`).
This commit closes that architectural gap.

---

## Per-location vs operator-wide grant

`perLocation`.

Match `VendorCapabilityProfile.grantScope`. Each F&F location
requires its own `venue_id` from SevenRooms. The
`POST /2_2/auth` exchange returns a token scoped to that venue. F&F
records the `venue_id` in `connector_connection.metadata.venue_id` so
the inbound webhook binding cross-check (step 2 of
`InboundWebhookHandler.dispatch`) can refuse cross-tenant misroutes
with 403.

---

## Module disambiguation

N/A — single module. SevenRooms does not fork its API by product
line the way ADP / QuickBooks do.

---

## Edge cases

- **Account-rep-issued credentials revoked upstream**: connection
  flips to `error` with operator-facing copy "Your SevenRooms partner
  credentials are no longer valid. Please contact your SevenRooms
  account rep, then reconnect with the new credentials."
- **`venue_id` typo at connect time**: `POST /2_2/auth` returns 401;
  the connect flow surfaces operator-facing copy "SevenRooms refused
  the venue ID. Double-check the venue ID from your SevenRooms admin
  portal and try again."
- **Sandbox-only credentials used in production**: same 401 path; the
  operator must request production credentials from their account
  rep.
- **Unknown errors during refresh**: log + retry once; on second
  failure, increment `consecutive_refresh_failures`; on third, flip
  to `error`.
