# Clover — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `clover`
**Category**: `pos`
**Source documentation**: <https://docs.clover.com/reference/orders>
**Retrieval date**: 2026-05-03
**API version pinned**: `v3` (REST API), pinned at retrieval-date shape
`v3_2026_05_03` per fixture constants.

---

## Auth method

`oauth` — Clover App Market authorization-code flow.

Cite vendor doc:
- OAuth 2.0 overview: <https://docs.clover.com/docs/using-oauth-20>
- Token endpoint:     <https://docs.clover.com/docs/oauth-20-tokens>

See `oauth_shape.md` for flow detail.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| GET    | `/v3/merchants/{mId}/orders`              | Backfill + polling — list orders modified in `[modifiedTime>=N, modifiedTime<=M]` | 16 req/sec/merchant per docs | `offset` + `limit` (max 1000; adapter pages at 100) |
| GET    | `/v3/merchants/{mId}/orders/{orderId}`    | Webhook hydration — fetch single order detail | shared with above | n/a |
| GET    | `/v3/merchants/{mId}`                     | Connect-time merchant profile + grant scope | shared with above | n/a |
| POST   | `/oauth/v2/token`                         | OAuth code-for-token + refresh | per OAuth docs | n/a |
| POST   | `/v3/apps/{aId}/webhooks`                 | Auto-register webhook subscription on connect | 10/min documented | n/a |
| DELETE | `/v3/apps/{aId}/webhooks/{subscriptionId}`| Unregister at disconnect | shared | n/a |

Every endpoint listed here is invoked by the adapter code; every
adapter call goes through the `CloverApiClient` seam. Codex verifies
the diff against `lib/integrations/pos/clover_pos_adapter.dart`.

The `modifiedTime` filter on `/v3/merchants/{mId}/orders` is **capped
at 90 days** per Clover's documented list-endpoint constraint — see
<https://docs.clover.com/docs/working-with-list-endpoints>. The
adapter clamps `windowStart` to `now() - 90 days` whenever the
operator-scheduled backfill window asks for older data; the V1 lean
cut 2 first-connect window of 60 days fits inside the cap.

---

## Sandbox / test environment

**Base URL**: `https://apisandbox.dev.clover.com`
**Sign-up**: <https://www.clover.com/developers> — App Market
developer account; sandbox tier issued on signup, no partnership
required for sandbox keys.

**Known limitations** (carried as ambiguity calls until
`8.CL.live.sandbox` confirms):
- Sandbox order seeding is operator-driven; no synthetic-order data
  is auto-populated. The `8.CL.live.sandbox` slice scripts a
  fixture-payment to seed the backfill assertion.
- Webhook delivery in sandbox sometimes lags the documented latency
  (>10s). The `8.CL.live.sandbox` slice's idempotency assertion
  tolerates this by running over a 60s window.

---

## Production environment

**Base URL**: `https://api.clover.com`
**Partnership requirements**: Clover App Market approval —
program "Clover App Market", lead time 1-3 weeks. Lighter than Toast
/ Aloha / Oracle MICROS gating but still a hard gate before the
adapter can issue production OAuth grants. See
`partnership_status.md`.
**Rate-limit policy**: <https://docs.clover.com/docs/rate-limits>
**Quota**: 16 requests / second / merchant; daily caps documented as
"reasonable use" without a hard ceiling.

---

## Versioning

**Vendor's deprecation policy**:
<https://docs.clover.com/docs/api-deprecation-policy>
**Adapter pinned to**: REST API v3 (`v3_2026_05_03` shape).
**Vendor's last announced breaking change**: none since 2024-09 per
their changelog at <https://docs.clover.com/docs/changelog> (verified
2026-05-03).
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner.
