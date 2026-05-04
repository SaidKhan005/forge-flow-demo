# SevenRooms — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `sevenrooms`
**Category**: `reservation`
**Source documentation**:
- Marketing overview: <https://sevenrooms.com/platform/integrations-apis/>
- Partner API portal (account-rep gated):
  <https://api-docs.sevenrooms.com/>
- Partner integration confirmations (publicly published):
  - Airship API credentials guide:
    <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms>
  - Kleene SevenRooms connector: <https://docs.kleene.ai/docs/sevenrooms>
  - Tenzo Reservations + Reviews guide:
    <https://tenzo.zendesk.com/hc/en-gb/articles/6117444553619>
- ApiTracker registry: <https://apitracker.io/a/sevenrooms>

**Retrieval date**: 2026-05-04
**API version pinned**: `v2_2_2026_05` (partner API `2_2`; pinned to
the shape captured below)

---

## Auth method

`oauthOrKeyPaste`. SevenRooms issues a partner credential pack via
account-rep onboarding consisting of `client_id` + `client_secret` +
`venue_id`; the adapter exchanges the keypaste pair for an access
token via `POST /2_2/auth`. The capability profile sets
`authMode = oauthOrKeyPaste` so the connect-flow UI can render either
surface.

OAuth flow detail in `oauth_shape.md`.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| `POST` | `/2_2/auth` | Token exchange (client_id + client_secret + venue_id → bearer access token) | not documented; treat as low (≤ 60/min) | n/a |
| `GET` | `/2_2/reservations` | Incremental polling (`updated_since={cursor}`) | not documented | cursor-style (`next_page_token`); `pageSize` 1-100, default 100 |
| `GET` | `/2_2/reservations/export` | 60-day backfill source (`updated_since={start_date}`) | not documented | cursor-style (`next_page_token`) |

The adapter does NOT consume:
- `/2_2/clients/{client_id}` — guest profile detail; refused at the
  adapter boundary per privacy. See `field_mapping.md` Forbidden
  fields.
- Any auto-register webhook endpoint — SevenRooms uses `manualPaste`;
  the operator pastes the F&F webhook URL into the SevenRooms admin
  portal manually. See `webhook_signature.md` Manual paste
  instructions.

Every endpoint listed here is invoked by
`lib/integrations/reservation/sevenrooms_reservation_adapter.dart`
(via `SevenRoomsAuthClient` / `SevenRoomsReservationsClient`); every
endpoint invoked by the adapter is listed here. Codex grades the diff
against the source.

---

## Sandbox / test environment

**Base URL**: `https://api.sevenrooms.com` (partner sandbox is a
separate venue scoped on the same host; no public sandbox host is
documented).
**Sign-up**: account-rep onboarding via the SevenRooms partnership
form (linked from <https://sevenrooms.com/platform/integrations-apis/>).
Sandbox credentials arrive in the partner credential pack.
**Known limitations** (to be confirmed by `8R.SR.live.sandbox`):
- Sandbox webhook deliveries are emitted only after the operator
  pastes the F&F webhook URL into the sandbox venue's portal.
- Per-status transition timestamps (`arrived_time`, `seated_time`,
  `departed_time`, `cancellation_time`) presence in the reservation
  payload is not enumerated in the publicly fetched docs; verify on
  live.

The sandbox requires partnership — see `partnership_status.md`.

---

## Production environment

**Base URL**: `https://api.sevenrooms.com`
**Partnership requirements**: account-rep-issued client_id +
client_secret + venue_id. 4-8 week lead time per
`partnership_status.md`.
**Rate-limit policy**: vendor does not publicly enumerate per-endpoint
rate caps; the adapter throttles per-tick at 100 records / page and
budgets backfill at no more than 6 pages/min on the production
worker.
**Quota**: not documented; treat as soft cap.

---

## Versioning

**Vendor's API version**: `2_2` (per the documented endpoints in the
Airship guide).
**Adapter pinned to**: `v2_2_2026_05` — see fixture
`documented_per_sevenrooms_v2_2_2026_05` constant.
**Vendor's deprecation policy**: not publicly documented; the partner
portal announcements channel is the canonical source. The adapter
re-verifies via `8R.SR.live.sandbox` on any vendor announcement or
every 180 days, whichever is sooner.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint warns when
the retrieval date above falls behind that window.
