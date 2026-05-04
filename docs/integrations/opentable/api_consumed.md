# OpenTable — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `opentable`
**Category**: `reservation`
**Source documentation**: <https://restaurant.opentable.com/products/opentable-platform/>
(operator-facing platform page only; the OpenTable Partner API
developer reference is not publicly hosted — access is gated by the
partnership program. See `partnership_status.md`.)
**Retrieval date**: 2026-05-04
**API version pinned**: `partner-v1-2026-05-04-assumed`

> **Partnership-only — full doc gated until partnership clears.**
> OpenTable does not maintain a public developer portal. The full
> Partner API reference (endpoints, OAuth shape, webhook signature
> envelope) is only released to partners after the program review
> clears (~6-12 weeks; see `partnership_status.md`). This file
> captures every assumption F&F engineered against the published
> reservation-data field shape (the industry-standard reservation
> envelope shared by the other reservation vendors). EVERY endpoint,
> field, header, and behavior listed below is flagged "verify in
> `8R.OT.live.sandbox`" — the field-mapping diff slice will confirm
> each assumption against an observed sandbox payload and cut a
> bounded fix where any of them differ.

---

## Auth method

`oauth` — assumption: `authorization_code` flow with rotating refresh
tokens (matches the OpenTable platform page's "Sign in to OpenTable"
operator flow). Cite vendor doc:
<https://restaurant.opentable.com/products/opentable-platform/>

See `oauth_shape.md` for flow detail. Every section there is also
flagged for live verification.

> Many endpoint shapes here are **assumptions to verify in
> `8R.OT.live.sandbox`**. The adapter binds to these shapes via the
> `documentedPerOpentableV1FieldMapping` constant in
> `lib/integrations/reservation/opentable_reservation_adapter.dart`;
> the `*.live.sandbox` slice diffs observed responses row-by-row.

---

## Endpoints consumed

| Method | Path (assumed) | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/api/v2/oauth/token` | OAuth `authorization_code` exchange + `refresh_token` rotation | TBD — partnership | n/a |
| POST | `/api/v2/oauth/revoke` | Best-effort revoke on disconnect | TBD — partnership | n/a |
| GET | `/v1/reservations/search` | Backfill + incremental poll (modified-since window) | TBD — partnership | cursor (`nextCursor`) |
| GET | `/v1/reservations/{reservation_id}` | Fall-through fetch when an inbound webhook payload omits a field | TBD — partnership | n/a |
| POST | `/v1/webhooks/subscriptions` | Auto-register the webhook subscription on connect | TBD — partnership | n/a |
| DELETE | `/v1/webhooks/subscriptions/{id}` | Unregister on disconnect | TBD — partnership | n/a |

Every endpoint listed is invoked by the adapter code; every endpoint
the adapter invokes is listed here. Each row is an assumption; the
`*.live.sandbox` slice will verify each path + method + pagination
shape and cut a bounded fix for any drift.

---

## Sandbox / test environment

**Base URL**: TBD — partnership.
**Sign-up**: via partnership; see `partnership_status.md`.
**Known limitations** (assumptions until verified):
- The Partner API sandbox is presumed to mirror production reservation
  shapes (industry standard), but emit synthetic data only.
- Webhook auto-registration may require a one-time portal step that
  the adapter cannot automate. Verified in `8R.OT.live.sandbox`.

If no sandbox exists at partnership-clear time, the workaround is to
run `8R.OT.live.prod` against a single F&F-owned restaurant grant
with read-only scopes; the field-mapping diff still applies.

---

## Production environment

**Base URL**: TBD — partnership.
**Partnership requirements**: Partner application must clear before
production credentials are issued. Lead time 6-12 weeks; tracked in
`partnership_status.md`.
**Rate-limit policy**: TBD — partnership.
**Quota**: TBD — partnership.

---

## Versioning

**Vendor's deprecation policy**: TBD — partnership. The platform
page's overview suggests OpenTable rolls major API changes in
quarterly drops with a 90-day deprecation window, but this is an
assumption that the `8R.OT.live.sandbox` slice will verify when the
partner doc is in hand.
**Adapter pinned to**: `partner-v1-2026-05-04-assumed`
**Vendor's last announced breaking change**: unknown until partnership
clears.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The adapter will
re-pin the API version on the first observed breaking change in
`8R.OT.live.sandbox`.
