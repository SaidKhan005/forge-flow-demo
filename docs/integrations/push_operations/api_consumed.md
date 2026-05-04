# Push Operations — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `push_operations`
**Category**: `labor`
**Source documentation**: <https://developers.pushoperations.com/>
**Retrieval date**: 2026-05-04
**API version pinned**: `v1` (Push Operations REST API at `/api/v1/...`)

---

## Auth method

`bearer_token` (partner-issued static credential) — Push Operations'
documented authentication is HTTP `Authorization: Bearer <token>`
where the token is issued by the Push Operations Partner Approval
program. There is no end-user authorization hop and no refresh-token
rotation: the token is a durable static credential the operator pastes
into the F&F admin connect dialog. Capability profile records this as
`authMode = keyPaste`. See `oauth_shape.md` (N/A line — no OAuth flow
to document).

Cite vendor doc:
<https://developers.pushoperations.com/>
(Push Operations API landing page; per the published "Push Operations
APIs" surface, all calls require an HTTPS Authorization Bearer token
issued only to approved partners.)

> **Partner activation gate.** Sandbox and production credentials are
> issued only after the partner application clears the Push Operations
> Partner Approval program. Engineering can complete the documented
> adapter without credentials; live verification (sandbox / prod)
> requires partnership progress per `partnership_status.md`. Estimated
> lead time at slice ship: **4-6 weeks** (shorter than ADP; longer
> than self-serve OAuth vendors like 7shifts / QuickBooks Time).

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| GET | `/api/v1/company` | Bind the operator's Push Operations company id at connect; verify the bearer token resolves an account | partner-issued; vendor does not document a public number | n/a |
| GET | `/api/v1/employees` | Enumerate employees so role / wage hooks can map per-employee identity for the Push grant scope | partner-issued; subject to standard `page` + `limit` cap | `page` + `limit` (default `limit=100`, max page size; short page = end of listing) |
| GET | `/api/v1/positions` | Pull vendor position list for FOH/BOH role mapping in the admin surface | partner-issued | `page` + `limit` (same shape as `/employees`) |
| GET | `/api/v1/shifts` | Backfill + poll-incremental — paged listing of published schedule shifts since `updated_at >= sinceModified` | partner-issued | `page` + `limit` (same shape as `/employees`); short page = end of listing |
| GET | `/api/v1/labour` | Time-clock / labour entries (clocked-in / clocked-out / breaks); date-range pagination distinct from `page+limit` shape used elsewhere | partner-issued | **date-range with 2-day max window** (vendor-documented; the bridge worker batches across the 60-day backfill in 2-day windows) |

Every endpoint listed here is invoked by the adapter at
`lib/integrations/labor/push_operations_labor_adapter.dart` (live HTTP
wired in `8.S.PU.live.sandbox`); every endpoint invoked by the adapter
is listed here. Codex verifies the diff. The `documented` slice
exercises the `/shifts` endpoint as the primary canonical-fact path;
`/labour` is documented for the `8.S.PU.live.*` slices to wire when
punch-level facts (clocked_in / clocked_out / breaks) become first
class.

> **Webhook delivery.** Push Operations' documented public API exposes
> **no** webhook delivery surface. The adapter is therefore poll-only:
> `webhookSupport = pollOnly` on the capability profile and
> `handleWebhook` throws `UnsupportedError` per
> `docs/contracts/vendor_adapter_slice_contract.md`. See
> `webhook_signature.md` (single-line N/A).

---

## Sandbox / test environment

**Base URL**: `https://<partner-issued sandbox host>.pushoperations.com/api/v1/`
(exact host issued at partner approval; not knowable until sandbox
credentials land)
**Sign-up**: via Push Operations Partner Approval program — see
`partnership_status.md`. Self-serve sandbox is not available.
**Known limitations**:
- Sandbox returns synthetic shift / labour data only; real timestamps
  are not guaranteed. Live verification of timestamp shape happens
  against production (`8.S.PU.live.prod`).
- Sandbox does not exercise webhook delivery (vendor does not document
  webhooks).
- The 2-day max date-range window on `/api/v1/labour` is enforced in
  sandbox per documented shape; the bridge worker batches the 60-day
  backfill in 2-day windows when the live slice wires `/labour`.

---

## Production environment

**Base URL**: `https://app-elb.pushoperations.com/api/v1/`
(public production host published from
<https://app-elb.pushoperations.com/login>; partner-issued bearer
required)
**Partnership requirements**: Push Operations Partner Approval program;
partner approval required. F&F is `not_started` at slice ship per
`partnership_status.md`.
**Rate-limit policy**: <https://developers.pushoperations.com/>
(consult partner portal at activation; vendor does not publish a
single rate-limit document.)
**Quota**: partner-issued; vendor does not publish a public numeric
cap. Partner approval may raise per use case.

---

## Versioning

**Vendor's deprecation policy**: <https://developers.pushoperations.com/>
(consult partner portal release notes section at activation)
**Adapter pinned to**: `v1` (REST API at `/api/v1/...`)
**Vendor's last announced breaking change**: not announced as of
2026-05-04 retrieval.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The
`api_consumed.md` retrieval date drives the CI lint warning.
