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

**Status (2026-05-09)**: NOT wired — architectural gap. The 2026-05-09
re-investigation verified that the surface is genuinely unreachable
from the broker today and refined the no-closure reason from
`sevenrooms_transport_cron_hour05` to
`sevenrooms_client_secret_not_persisted` to reflect the actual gap.

### Why the broker cannot drive SevenRooms refresh today

SevenRooms uses the `client_credentials` grant — there is no rotating
`refresh_token`. To mint a fresh bearer, the broker must POST
`{client_id, client_secret, venue_id, grant_type: client_credentials}`
to `/2_2/auth`. Of those three fields:

- `client_id` — persisted on `vendor_credentials.metadata.client_id`
  by `SevenRoomsBrokerCredentialStore.persistIssuedBearerToken` in
  `lib/integrations/reservation/sevenrooms_credential_bridge.dart:67-71`.
- `venue_id` — persisted on `connector_connection.metadata.venue_id`
  per `kSevenRoomsConnectionMetadataVenueId`.
- `client_secret` — **NOT persisted anywhere**. The connect-time
  `SevenRoomsAuthClient.authenticate(clientId:, clientSecret:,
  venueId:)` consumes the secret to mint the initial bearer
  (`lib/integrations/reservation/sevenrooms_reservation_production_api_client.dart:367-419`),
  but `persistIssuedBearerToken` (line 410) writes only the bearer +
  `client_id`; the `client_secret` falls out of memory and is never
  ciphertext-stored.

Without `client_secret` on the credential row, the worker has no way
to call `/2_2/auth`. PR #455's "transport-layer cron at hour:05" claim
is also inaccurate: there is no cron, scheduler, or in-process
refresh loop anywhere in the codebase that calls
`SevenRoomsAuthClient.authenticate(...)` after connect-time (verified
2026-05-09 via `grep -r 'sevenrooms.*scheduler\|authenticate.*scheduler\|hour:05'`
returning only doc fixtures + this file). The "transport cron" was an
aspirational description in `Refresh semantics` below; no code
implements it.

### Behavior at runtime

- When the cross-tenant OAuth refresh worker claims a near-expiry
  SevenRooms row, it log-and-skips with the structured reason
  `sevenrooms_client_secret_not_persisted` (see
  `kVendorsWithoutRefreshClosureReason` in
  `tool/oauth_refresh_worker/main.dart`). No failure-count increment.
- When the bearer expires before the operator reconnects, the next
  outbound SevenRooms call returns 401 → adapter surfaces a connection
  error → operator is prompted to reconnect (paste credentials again
  through the keypaste flow).

### Follow-up slice spec (architectural change required to wire)

To bring SevenRooms into the broker-driven registry, a follow-up slice
must:

1. Modify `SevenRoomsBrokerCredentialStore.persistIssuedBearerToken`
   to accept and persist `clientSecret` ciphertext into
   `vendor_credentials.metadata.client_secret` (the `metadata` JSONB
   already round-trips through pgcrypto via the same envelope key the
   bearer uses).
2. Modify the SevenRooms connect-flow to thread `clientSecret` through
   to the persist call (it currently passes through
   `authClient.authenticate(...)` and is dropped).
3. Modify `connector_connection.metadata` writers to ensure `venue_id`
   is reliably set for legacy rows.
4. Add `makeSevenRoomsOauthExchangeClosure` to
   `lib/integrations/_common/production_oauth_refresh_closures.dart`
   that POSTs the four-field body to `/2_2/auth` and threads the new
   bearer + lifetime back via `TokenRefreshResult` (no `refreshToken`
   field — `client_credentials` returns no rotating refresh token).
5. Migrate existing SevenRooms rows: persist a one-shot reconnect
   prompt operator-facing so each operator pastes credentials once to
   populate the new `client_secret` ciphertext column. Without the
   migration, existing rows continue to skip until the operator
   reconnects.

The follow-up slice is OUT OF SCOPE for the 2026-05-09 wiring PR; the
current PR keeps SevenRooms on `kVendorsWithoutRefreshClosureReason`
with the refined reason so a deploy review can match the row to the
documented architectural gap.

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
