# Libro Reserve — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `libro`
**Category**: `reservation`
**Source documentation**: <https://libroreserve.github.io/api-documentation/>
**Retrieval date**: 2026-05-04
**API version pinned**: `v1`

---

## Auth method

`oauth` — OAuth 2.0 authorization code grant with refresh tokens.

Cite vendor doc section: <https://libroreserve.github.io/api-documentation/#section/Authentication>

OAuth flow shape lives in `oauth_shape.md`.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| GET | `/v1/reservations` | Backfill + poll. Filter via `venue_id`, `updated_since`, `updated_before`, `cursor`, `page_size`. | Documented as 60 req/min per token (vendor docs); adapter respects `Retry-After` on 429. | Cursor in `next_cursor` envelope field. |
| POST | `/v1/webhooks/subscriptions` | Auto-register webhook URL on first connect. | Shared with above. | n/a |
| DELETE | `/v1/webhooks/subscriptions/{id}` | Unregister on operator-initiated disconnect. | Shared. | n/a |
| POST | `/v1/oauth/token` | Token issuance (auth code) and refresh. Called by `oauth_refresh_cron.dart`, not the adapter directly. | n/a | n/a |
| POST | `/v1/oauth/revoke` | Revoke refresh token on operator-initiated disconnect. | n/a | n/a |

Codex check: every endpoint above MUST be invoked by the adapter
(directly via `LibroHttpClient` or indirectly via the framework's
OAuth cron). Every endpoint invoked by the adapter MUST be listed
here.

---

## Sandbox / test environment

**Base URL**: `https://sandbox.libroreserve.com` (per vendor docs;
verify in `8R.LB.live.sandbox`).
**Sign-up**: public — operator creates a sandbox venue from the
Libro developer console; no partnership required.
**Known limitations** (pre-`8R.LB.live.sandbox`; verify on first
sandbox run):
- Sandbox webhooks may emit synthetic timestamps in venue-local
  wall-clock with no tz hint (per
  `vendorTimestampPolicy['libro']`).
- Sandbox does not always emit `arrived_at` / `seated_at` for the
  same reservation; the adapter MUST tolerate sparse status-transition
  timestamps (verified by fixture
  `libroReservationPagePayloadFirstOfTwo`).

If no sandbox exists at runtime: the engineering slice is fixture-
based only; the `8R.LB.live.sandbox` slice will document and resolve
any missing sandbox features as bounded fixes.

---

## Production environment

**Base URL**: `https://api.libroreserve.com`
**Partnership requirements**: none — public OAuth.
**Rate-limit policy**: <https://libroreserve.github.io/api-documentation/#section/RateLimits>
**Quota**: 60 req/min per token (per vendor docs at retrieval).

---

## Versioning

**Vendor's deprecation policy**: <https://libroreserve.github.io/api-documentation/#section/Versioning>
**Adapter pinned to**: `v1`
**Vendor's last announced breaking change**: none at retrieval (2026-05-04).
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner.
