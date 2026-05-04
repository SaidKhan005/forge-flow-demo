# Agendrix — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `agendrix`
**Category**: `labor`
**Source documentation**: <https://developers.agendrix.com/en/documentation>
(Agendrix Public REST API; self-serve developer portal with API
Playground)
**Retrieval date**: 2026-05-04
**API version pinned**: `v2`

---

## Auth method

`oauth` — OAuth 2.0, `authorization_code` grant. The operator
authorizes F&F at the Agendrix developer portal's consent screen; the
callback delivers an authorization code which the proxy exchanges for
an access + refresh token pair. Operator-wide grant scope: a single
OAuth grant covers every Agendrix location bound to the operator
organization. See `oauth_shape.md`.

Cite vendor doc:
<https://developers.agendrix.com/en/documentation>
(OAuth section of the public dev portal — accessible after sign-in to
the Playground)

> **Self-serve activation.** Agendrix exposes a public OAuth flow with
> no partnership review. F&F's developer registration only needs a
> published `redirect_uri` and an app name; production credentials are
> issued automatically. Estimated lead time at slice ship: **none**
> (self-serve dev portal).

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/v2/oauth/token` | Token issuance (`authorization_code` grant) + refresh (`refresh_token` grant) | shared with org cap | n/a |
| GET  | `/v2/companies/{company_id}/time_entries` | Backfill + poll-incremental — paged listing of time entries (punches) since `updated_after` | ~120 req/min/org (vendor-soft; production caps confirmed at `*.live`) | server-issued cursor token; empty cursor = end of listing |
| GET  | `/v2/companies/{company_id}/time_entries/{id}` | Optional reconciliation lookup for a single time entry | shared with above | n/a |
| GET  | `/v2/companies/{company_id}/positions` | Enumerate the org's positions so the connect flow can map vendor `position.name` to a F&F FOH/BOH classification | low cadence | n/a |
| GET  | `/v2/companies/{company_id}/users` | Enumerate the org's employees for `user_id` → person mapping (within-vendor namespace only; cross-vendor mapping is an explicit non-goal at V1) | low cadence | n/a |
| GET  | `/v2/companies/{company_id}` | Bind the OAuth grant's company claim to one F&F operator | low cadence | n/a |

Every endpoint listed here is invoked by the adapter at
`lib/integrations/labor/agendrix_labor_adapter.dart`; every endpoint
invoked by the adapter is listed here. Codex verifies the diff.

> **Subset of 75+ endpoints.** Agendrix's documented public API exposes
> 75+ endpoints across shifts, time-clock, positions, teams, leave
> requests, availability, payroll exports, and notifications. The
> adapter consumes the **minimum-privilege subset** required for V1
> labor ingestion (punches + roles + employees + company binding).
> Additional surfaces (published shifts, leave, availability) land as
> bounded follow-ups when operator demand justifies them.

> **Webhook delivery.** Agendrix's documented public API exposes **no**
> webhook delivery surface as of the 2026-05-04 retrieval. The
> adapter is therefore poll-only: `webhookSupport = pollOnly` on the
> capability profile and `handleWebhook` throws `UnsupportedError`
> per `docs/contracts/vendor_adapter_slice_contract.md`. See
> `webhook_signature.md` (single-line N/A).

---

## Sandbox / test environment

**Base URL**: `https://api.agendrix.com/v2/` (Agendrix exposes a
single REST host; sandbox vs production is differentiated by the
developer-portal app credentials — sandbox apps use a sandbox
organization seeded with synthetic data via the API Playground).
**Sign-up**: <https://developers.agendrix.com/> — register a
developer account, create an app, publish a `redirect_uri`. No
partnership review.
**Known limitations**:
- Sandbox returns synthetic time entries seeded from the Playground;
  real timestamps are not guaranteed. Live verification of timestamp
  shape happens against production (`8.S.AG.live.prod`).
- Sandbox does not exercise webhook delivery (vendor does not document
  webhooks).

---

## Production environment

**Base URL**: `https://api.agendrix.com/v2/`
**Partnership requirements**: none — public OAuth.
**Rate-limit policy**:
<https://developers.agendrix.com/en/documentation> (consult the
Rate Limits section after sign-in).
**Quota**: ~120 req/min/org documented soft cap; production caps are
confirmed at `8.S.AG.live.prod`.

---

## Versioning

**Vendor's deprecation policy**:
<https://developers.agendrix.com/en/documentation> (consult the
Changelog section after sign-in).
**Adapter pinned to**: `v2` (current public REST API).
**Vendor's last announced breaking change**: not announced as of
2026-05-04 retrieval.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The
`api_consumed.md` retrieval date drives the CI lint warning.
