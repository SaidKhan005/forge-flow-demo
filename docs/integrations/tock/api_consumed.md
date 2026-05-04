# Tock — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `tock`
**Category**: `reservation`
**Source documentation**:
<https://api.exploretock.com/docs/latest/reservation.html>
**Retrieval date**: 2026-05-04
**API version pinned**: `reservation_2026_05_03` (Tock does not publish
a numeric API version on its public reservation reference; the slug
combines the doc retrieval date so a future shape change is detectable
from the diff between the adapter constants + observed sandbox
responses)

---

## Auth method

`keyPaste` — Tock issues a per-`businessId` API key via
`integrate@tockhq.com`. The key is sent on every request as a bearer
token in the `Authorization` header (the exact header shape is
documented on the gated Premium-tier developer portal; engineering
treats it as bearer-style and `*.live.sandbox` diffs the observed
shape).

Cite vendor doc:
<https://api.exploretock.com/docs/latest/reservation.html>

OAuth shape (none — see [oauth_shape.md](oauth_shape.md)).

---

## Premium-tier gate (binding)

Tock gates BOTH the reservation API and webhook delivery to **Premium
or Premium Unlimited** customers. Production credentials cannot be
issued before the operator's commercial relationship with Tock reaches
that tier. Engineering closes Wave B at lifecycle = `documented`
without that lane started; the `8R.TC.live.prod` slice cites
[partnership_status.md](partnership_status.md) and waits on the
commercial cleanance.

The lead time on Tock Premium-tier negotiation is **4-8 weeks** per
ops research (2026-05-04). Engineering does NOT block on this; the
adapter is fixture-tested and the per-vendor doc pack is the contract
the `*.live.sandbox` slice grades observed responses against.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| GET | `/businesses/{businessId}` | Resolve grant scope (per-location id, timezone) on connect | per documented Tock quota; tier-dependent | n/a |
| GET | `/reservations/search` | 60-day backfill + incremental polling. The adapter passes `windowStart` / `windowEnd` parameters; Tock returns a cursor-paginated page of reservations. | per documented Tock quota; tier-dependent | cursor + `nextPageToken`; window-stitched by adapter |
| GET | `/reservations/{reservationId}` | Single-id resume when a vendor-side rate cap forces a stitched single-id resume; the webhook path does NOT use this endpoint (Tock payloads are documented as full-shape) | shared with above | n/a |

Every endpoint listed here MUST be invoked by the adapter code; every
endpoint invoked by the adapter code MUST be listed here. Codex
verifies the diff against
[lib/integrations/reservation/tock_reservation_adapter.dart](../../../lib/integrations/reservation/tock_reservation_adapter.dart)
and the `TockApiClient` interface declared there.

Webhook receiver is described in
[webhook_signature.md](webhook_signature.md). Tock requires manual
paste of the F&F webhook URL + signing secret in the Premium-tier
dashboard — there is NO `POST /webhooks` endpoint listed here because
the adapter does NOT auto-register.

---

## Sandbox / test environment

**Base URL**: `https://api.exploretock.com` (Tock does not publicly
document a separate sandbox host on the public reservation reference;
the Premium-tier developer portal exposes a sandbox sub-domain to
credentialed accounts).
**Sign-up**: see [partnership_status.md](partnership_status.md). Tock
gates sandbox issuance behind the Premium-tier intake; documented
engineering does not require sandbox credentials. The
`8R.TC.live.sandbox` slice fires once Tock issues sandbox credentials.
**Known limitations** (per Tock public reference, retrieval
2026-05-04):

- Per-status transition timestamps (`arrived_at`, `seated_at`,
  `left_at`, `canceled_at`) are NOT documented on the public
  reservation reference. The `*.live.sandbox` slice diffs observed
  payload shape against this gap and adopts any fields present as a
  bounded fix (not a slice rebuild).
- Premium-tier sandbox availability is gated on the commercial intake
  with Tock; engineering does NOT consume that lane.

---

## Production environment

**Base URL**: `https://api.exploretock.com`
**Partnership requirements**: Tock Premium / Premium Unlimited tier
(see [partnership_status.md](partnership_status.md)). Production
credentials are issued only after the commercial lane clears.
**Rate-limit policy**: per-business; tier-dependent. The adapter does
not own quota negotiation — that is the partnership lane.

---

## Versioning

**Vendor's deprecation policy**: Tock does not publish a versioning or
deprecation policy on the public reservation reference. The
Premium-tier developer portal documents version pin / deprecation
detail to credentialed accounts; engineering does NOT consume that
detail at lifecycle = `documented`.
**Adapter pinned to**: `reservation_2026_05_03` (slug derived from doc
retrieval date — see top of this file).
**Vendor's last announced breaking change**: none observed in the
2026-05-04 retrieval window.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint on
`docs/integrations/tock/api_consumed.md` enforces the 180-day window.

---

## Tier table (Premium vs Premium Unlimited)

| Tier | API + webhooks | Production | Quota | Used by F&F |
|---|---|---|---|---|
| Standard / Premium-Lite | Not gated for API access | n/a | n/a | Out of scope (no API) |
| Premium | Reservation API + webhooks | Per-business prod | Documented | Default (this adapter) |
| Premium Unlimited | Reservation API + webhooks; higher quotas | Per-business prod | Higher / negotiated | Optional upgrade post-V1 |
