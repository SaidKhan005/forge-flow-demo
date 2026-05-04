# Aloha (NCR Voyix) — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `aloha_ncr_voyix`
**Category**: `pos`
**Source documentation**: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
**Retrieval date**: 2026-05-04
**API version pinned**: `aloha-v1-2026-05`

> **Per-API access request gate.** NCR Voyix Developer Program
> applicants get a developer-portal account on enrollment, but each
> Aloha-module API surface (orders/checks, OAuth, webhook events bus,
> sites) requires a separate per-API access request. Sandbox
> credentials are not issued until both the program intake and the
> per-API access request clear. The engineering slice (`8.AL`)
> targets the documented shape only — no live HTTP runs from this
> slice. The `8.AL.live.sandbox` slice fires when the per-API access
> requests clear; `8.AL.live.prod` fires when production credentials
> are issued. Lead time tracked in `partnership_status.md`.

---

## Auth method

`oauth` (OAuth 2.0 — `client_credentials` flow)

Cite vendor doc section: <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>
(Authentication / Authorization landing; full grant-flow detail
verified live in `8.AL.live.sandbox`).

OAuth flow detail captured in `oauth_shape.md`.

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/oauth2/token` | Mint / refresh access token (`client_credentials`) | per-tenant policy; verified live | n/a |
| GET | `/aloha/v1/sites` | Site/location enumeration; binds Aloha `siteId` to `connector_connection.metadata.site_id` | shared with module quota | cursor (`nextCursor`) |
| GET | `/aloha/v1/sites/{siteId}/checks` | Backfill + poll — list checks within `[modifiedAfter, modifiedBefore]` | shared with module quota | cursor (`nextCursor`) |
| GET | `/aloha/v1/sites/{siteId}/checks/{checkId}` | Webhook id-only lookup (Aloha events emit id-only on `aloha.check.modified`) | shared with module quota | n/a |
| POST | `/events/v1/subscriptions` | Auto-register the F&F webhook URL with the NCR Voyix events bus for the Aloha module | 10/min | n/a |
| DELETE | `/events/v1/subscriptions/{subscriptionId}` | Unregister webhook on operator disconnect | 10/min | n/a |
| GET | `/aloha/v1/sites/{siteId}/checks/sample` | Heavy sample pull for the operator-facing test-connection modal (returns one recent check) | shared with module quota | n/a |

Every endpoint listed here is invoked by the adapter
(`lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart`); every
endpoint invoked by the adapter is listed here. Codex verifies the
diff.

**Ambiguity calls** (verified in `8.AL.live.sandbox`):

- Exact path shape (`/aloha/v1/...` vs `/restaurant/v1/aloha/...`).
  The documented portal landing names the Aloha module surface as a
  first-class group; the path prefix verified live.
- Exact pagination shape (`nextCursor` token vs `next_url` linkable).
  The adapter's `AlohaNcrVoyixChecksPage.nextCursor` accepts either;
  the live diff fix is bounded.
- Sample-check endpoint may be a query parameter on the list endpoint
  rather than a separate path. The adapter's `fetchSampleCheck`
  abstracts this and the live wiring stitches the right shape.

---

## Sandbox / test environment

**Base URL**: `<https://api.ncrvoyix.com/sandbox>` (placeholder; live
URL captured in `8.AL.live.sandbox` once issued)
**Sign-up**: via NCR Voyix Developer Program intake + per-API access
request — see `partnership_status.md`. Sandbox credentials gated on
both clearing.
**Known limitations** (verified live):

- NCR Voyix sandbox surfaces are sometimes data-shaped without
  matching production rate limits. Verified in `8.AL.live.sandbox`.
- The events bus may emit synthetic events during sandbox testing
  rather than driving from real check activity; F&F's test-connection
  + sanity hook + idempotency UNIQUE handle either case.
- Aloha module sandbox does not currently document whether voided
  checks emit a webhook event; verified live.

If sandbox behavior diverges from documented production shape, the
divergence is captured row-by-row in
`live_verification_checklist.md`. Bounded fixes only — slice rebuilds
are reserved for vendor shape changes.

---

## Production environment

**Base URL**: `<https://api.ncrvoyix.com>` (placeholder; live URL
captured in `8.AL.live.prod` once partnership clears)
**Partnership requirements**: NCR Voyix Developer Program intake +
per-API access request per Aloha-module surface. Estimated lead time
8-16 weeks (`partnership_status.md`).
**Rate-limit policy**: per-tenant; documented in the developer portal
landing on per-API request approval.
**Quota**: TBD on issuance.

---

## Versioning

**Vendor's deprecation policy**: NCR Voyix Developer Program
versioning policy (verified at `8.AL.live.sandbox`).
**Adapter pinned to**: `aloha-v1-2026-05`
**Vendor's last announced breaking change**: n/a — first engineering
slice.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. CI lint warns when
the retrieval date in this file ages beyond 180 days without a
`8.AL.live.sandbox` re-verification entry in
`live_verification_checklist.md`.
