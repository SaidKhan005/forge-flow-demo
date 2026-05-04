# Lightspeed Restaurant K-Series — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `lightspeed_lsk`
**Category**: `pos`
**Source documentation**: <https://api-docs.lsk.lightspeed.app/>
**Retrieval date**: 2026-05-03
**API version pinned**: `f-v2-2026-05` (Financial API v2 + Staff API
v1 endpoints; pinned to the shape captured below)

---

## Auth method

`oauth` (authorization-code grant flow).

Cite vendor doc:
<https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>

OAuth flow detail in `oauth_shape.md`.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| `GET` | `/oauth/authorize` | Authorization-code start (browser redirect) | n/a | n/a |
| `POST` | `/oauth/token` | Token exchange + refresh (`grant_type=authorization_code` / `refresh_token`) | not documented; treat as low (≤ 60/min) | n/a |
| `POST` | `/oauth/revoke` | Disconnect-side revoke (best-effort) | not documented | n/a |
| `GET` | `/f/v2/business-location/{businessLocationId}/sales` | 60-day backfill + incremental polling source | not documented; sandbox returns synthetic data | cursor (`nextPageToken`); `pageSize` 1-100, default 50 |
| `GET` | `/f/v2/business-location/{businessLocationId}/business-day-sales` | Heavy sample-pull for `testConnection` | shared with above | cursor |
| `PUT` | `/o/wh/1/webhook` | Auto-register webhook subscription on connect | not documented | n/a |

Every endpoint listed here is invoked by
`lib/integrations/pos/lightspeed_lsk_pos_adapter.dart` (or its OAuth
/ webhook client surfaces); every endpoint invoked by the adapter is
listed here. Codex grades the diff against the source.

---

## Sandbox / test environment

**Base URL**: `https://api.trial.lsk.lightspeed.app`
**Sign-up**: <https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview>
**Known limitations** (to be confirmed by `8.LSK.live.sandbox`):
- Sandbox returns synthetic order data only; timestamps may not reflect
  real restaurant hours.
- Webhook signing-secret rotation through the trial portal has not been
  observed end-to-end (V1 lean cut 2 deletes webhook key rotation UI;
  this slice does not depend on the behavior).

The trial environment requires only public OAuth registration — no
partnership review. See `partnership_status.md`.

---

## Production environment

**Base URL**: `https://api.lsk.lightspeed.app`
**Partnership requirements**: none (public OAuth).
**Rate-limit policy**: vendor does not publicly enumerate per-endpoint
rate caps; the adapter throttles per-tick at 100 records / page
(K-Series default) and budgets backfill at no more than 6 pages/min
on the production worker.
**Quota**: not documented; treat as soft cap.

---

## Versioning

**Vendor's deprecation policy**: <https://api-portal.lsk.lightspeed.app/quick-start/authentication/v2-authentication/v2-migration-guides/v2-migration-faq>
**Adapter pinned to**: Financial API v2 (`f-v2`) + Staff API v1 — see
fixture `documented_per_lightspeed_lsk_f_v2_2026_05` constant.
**Vendor's last announced breaking change**: V2 OAuth migration
(`api-portal.lsk.lightspeed.app/.../v2-migration-faq`). The adapter
ships against V2 from day one; legacy V1 clients are out of scope.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint warns when
the retrieval date above falls behind that window.
