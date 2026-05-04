# Square — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `square`
**Category**: `pos`
**Source documentation**: https://developer.squareup.com/docs
**Retrieval date**: 2026-05-03
**API version pinned**: `2024-01-18`

---

## Auth method

`oauth` (Authorization Code grant).

Cite vendor doc section: https://developer.squareup.com/docs/oauth-api/overview

OAuth flow detail lives in `oauth_shape.md`.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/v2/orders/search` | 60-day backfill + incremental polling | Standard tier limits — Square does not publish a public per-route ceiling; 429s carry `Retry-After` headers | Cursor token (`cursor` in request, `cursor` in response) |
| GET  | `/v2/orders/{order_id}` | Webhook hydration when payload is "thin" (data.id only) | shared with above | n/a |
| POST | `/oauth2/token` | Initial code exchange + refresh-token rotation | shared OAuth quota | n/a |
| POST | `/oauth2/revoke` | Disconnect — revoke OAuth grant | shared OAuth quota | n/a |
| POST | `/v2/webhooks/subscriptions` | Auto-register the F&F notification URL on first connect | shared admin quota | n/a |
| DELETE | `/v2/webhooks/subscriptions/{id}` | Unregister on disconnect | shared admin quota | n/a |
| GET  | `/v2/locations` | Map merchant locations onto F&F locations during connect + test-connection sample | shared admin quota | none — flat list |

Source URLs (one per row):
- SearchOrders — https://developer.squareup.com/reference/square/orders-api/search-orders
- RetrieveOrder — https://developer.squareup.com/reference/square/orders-api/retrieve-order
- OAuth Token / Revoke — https://developer.squareup.com/reference/square/oauth-api/obtain-token / https://developer.squareup.com/reference/square/oauth-api/revoke-token
- Webhook Subscriptions — https://developer.squareup.com/reference/square/webhook-subscriptions-api
- Locations — https://developer.squareup.com/reference/square/locations-api

Every endpoint listed here MUST be invoked by the adapter code; every
endpoint invoked by the adapter code MUST be listed here.

---

## Sandbox / test environment

**Base URL**: `https://connect.squareupsandbox.com`
**Sign-up**: https://developer.squareup.com/apps — public OAuth, no
partnership program required.
**Known limitations**:
- Sandbox does not emit live customer traffic; orders must be seeded
  via the Square Sandbox Test Helpers.
- Refresh tokens in sandbox have shorter TTLs than production
  (24h vs 30 days).

---

## Production environment

**Base URL**: `https://connect.squareup.com`
**Partnership requirements**: none — Square's developer program is
self-serve. See `partnership_status.md` (program: "n/a — public OAuth").
**Rate-limit policy**: https://developer.squareup.com/docs/build-basics/api-faqs#what-is-the-rate-limit
- Standard tier: per-application quotas, 429 with `Retry-After` on
  exceed. F&F adapter retries once after the supplied delay; on
  second 429 the polling worker backs off exponentially.

**Quota**: not publicly published; Square scales quota with merchant
volume and contacts apps that approach the ceiling.

---

## Versioning

**Vendor's deprecation policy**: https://developer.squareup.com/docs/build-basics/api-lifecycle
- Square versions APIs by date (e.g., `2024-01-18`).
- Versions are supported for 1 year minimum after release.
- Adapter sends `Square-Version: 2024-01-18` on every request so a
  Square-side change cannot silently shift the response shape.

**Adapter pinned to**: `2024-01-18`
**Vendor's last announced breaking change**: none affecting the
endpoints above as of 2026-05-03.
**Re-verification cadence**: every 180 days OR on any Square
deprecation announcement, whichever is sooner.
