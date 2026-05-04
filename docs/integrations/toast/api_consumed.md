# Toast — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `toast`
**Category**: `pos`
**Source documentation**: <https://doc.toasttab.com>
**Retrieval date**: 2026-05-03
**API version pinned**: `orders/v2` + `authentication/v1` +
`webhooks-config/v1` + `restaurants/v1`

---

## Auth method

`oauth` — OAuth 2.0 client_credentials grant.

Cite vendor doc section:
<https://doc.toasttab.com/doc/devguide/apiAuthenticationOverview.html>

Detail in [oauth_shape.md](oauth_shape.md).

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/authentication/v1/authentication/login` | Mint access token (client_credentials) | shared with all auth | n/a |
| GET | `/orders/v2/ordersBulk` | 60-day backfill + incremental polling. 1-hour window cap per call; adapter stitches consecutive hours. | per documented quota; per-restaurant tier-dependent | cursor + `pageToken`; window-stitched by adapter |
| GET | `/orders/v2/orders/{orderGuid}` | Webhook `orders.modified` lookup when payload is id-only | shared with above | n/a |
| POST | `/webhooks-config/v1/webhook` | Register the F&F webhook URL on connect | low (admin tier) | n/a |
| DELETE | `/webhooks-config/v1/webhook/{subscriptionId}` | Unregister webhook on disconnect (best-effort) | low (admin tier) | n/a |
| GET | `/restaurants/v1/restaurants/{restaurantGuid}` | Resolve grant scope (per-location id, timezone, business-day rollover) on connect | low | n/a |

Every endpoint listed here MUST be invoked by the adapter code; every
endpoint invoked by the adapter code MUST be listed here. Codex
verifies the diff against
[lib/integrations/pos/toast_pos_adapter.dart](../../../lib/integrations/pos/toast_pos_adapter.dart)
and the `ToastApiClient` interface declared there.

---

## Sandbox / test environment

**Base URL**: `https://ws-sandbox-api.eng.toasttab.com`
**Sign-up**: see [partnership_status.md](partnership_status.md). Toast
gates sandbox issuance behind the Standard / Partner tier intake;
documented engineering does not require sandbox credentials. The
`*.live.sandbox` slice fires once Toast issues the credentials.
**Known limitations** (per Toast docs, retrieval 2026-05-03):
- Sandbox `ordersBulk` returns synthetic data only; live timestamps
  are simulated.
- Webhook deliveries from sandbox are not guaranteed in near-real-
  time; the `*.live.sandbox` slice tolerates a 60-second jitter on
  the inbound webhook latency check.

If no sandbox is reachable for a given operator, Toast accepts a
short-lived production-credential lane via the Partner program.
Engineering does not consume that lane — the `*.live.prod` slice
does, after partnership clearance per
[partnership_status.md](partnership_status.md).

---

## Production environment

**Base URL**: `https://ws-api.toasttab.com`
**Partnership requirements**: Toast Partner Program — Standard Tier
(see [partnership_status.md](partnership_status.md)). Production
credentials are issued only after the commercial lane clears.
**Rate-limit policy**:
<https://doc.toasttab.com/doc/devguide/apiRateLimitsErrorMessages.html>
**Quota**: per-restaurant; tier-dependent. The adapter does not own
quota negotiation — that is the partnership lane.

---

## Versioning

**Vendor's deprecation policy**:
<https://doc.toasttab.com/doc/devguide/apiVersioning.html>
**Adapter pinned to**:
- `orders/v2` (current Toast `orders` major).
- `authentication/v1` (current Toast `authentication` major).
- `webhooks-config/v1` (current Toast `webhooks-config` major).
- `restaurants/v1` (current Toast `restaurants` major).

**Vendor's last announced breaking change**: none observed in the
2026-05-03 retrieval window.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint on
`docs/integrations/toast/api_consumed.md` enforces the 180-day window.

---

## Tier table (Standard vs Partner vs Custom)

Toast exposes three API access tiers. The engineering slice targets
Standard; Partner is identical-shape with higher quotas; Custom is
account-scoped beyond the documented surface.

| Tier | Sandbox | Production | Quota | Used by F&F |
|---|---|---|---|---|
| Standard | Standard sandbox | Per-restaurant prod | Documented | Default (this adapter) |
| Partner | Partner sandbox | Per-restaurant prod | Higher / negotiated | Optional upgrade after first cohort |
| Custom | n/a | Account-scoped | Custom | Not in V1 scope |
