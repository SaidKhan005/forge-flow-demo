# QuickBooks Time — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `quickbooks_time`
**Category**: `labor`
**Source documentation**: <https://tsheetsteam.github.io/api_docs/>
(QuickBooks Time / TSheets developer API; brand was renamed from
TSheets to QuickBooks Time after Intuit's acquisition.)
**Retrieval date**: 2026-05-04
**API version pinned**: `v1`

---

## Auth method

`oauth` — OAuth 2.0, `authorization_code` grant via Intuit's OAuth
service. **Public, self-serve** at <https://developer.intuit.com> — no
partnership program; no commercial gate. Bearer access token returned
from the token endpoint with a short TTL (approx. 1 hour) and
proactive refresh. One Intuit OAuth realm covers all of the
operator's QBT locations (operator-wide grant). See `oauth_shape.md`.

Cite vendor doc:
<https://tsheetsteam.github.io/api_docs/?javascript#authentication>

> **No partnership gate.** Engineering can complete the documented
> adapter without partner negotiation; live verification (sandbox /
> prod) only requires the operator (or F&F) to register an Intuit
> developer app and complete the OAuth handshake. See
> `partnership_status.md` (program: "n/a — public OAuth").

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer` | Token issuance (`authorization_code` grant) and rotating refresh | Intuit-imposed; vendor does not document a public number | n/a |
| POST | `https://developer.api.intuit.com/v2/oauth2/tokens/revoke` | Best-effort revoke on disconnect | shared with above | n/a |
| GET | `https://rest.tsheets.com/api/v1/timesheets` | Backfill (60-day window) + poll-incremental — paged listing of timesheets since `modified_since` | ~20 req/sec per account (vendor-documented soft cap) | page-numbered (`?page=N`) with `more` boolean flag in `results.more` |
| GET | `https://rest.tsheets.com/api/v1/timesheets/{id}` | Optional reconciliation lookup for a single timesheet | shared with above | n/a |
| GET | `https://rest.tsheets.com/api/v1/jobcodes` | Role catalog (joined to `timesheets[].jobcode_id` for `role_name`) | shared with above | page-numbered |
| GET | `https://rest.tsheets.com/api/v1/users` | Employee catalog (joined to `timesheets[].user_id` for `employee_id` plus pay-rate when scope grants it) | shared with above | page-numbered |
| GET | `https://rest.tsheets.com/api/v1/groups` | Optional grant-scope mapping (vendor groups → admin-surface FOH/BOH classification) | shared with above | page-numbered |

Every endpoint listed here is invoked by the adapter at
`lib/integrations/labor/quickbooks_time_labor_adapter.dart`; every
endpoint invoked by the adapter is listed here. Codex verifies the
diff.

> **Webhook delivery.** F&F's documented review of the QuickBooks
> Time API exposes **no** webhook delivery surface usable for
> schedule / punch changes. The adapter is therefore poll-only:
> `webhookSupport = pollOnly` on the capability profile and
> `handleWebhook` throws `UnsupportedError` per
> `docs/contracts/vendor_adapter_slice_contract.md`. See
> `webhook_signature.md` (single-line N/A). Polling cadence (5 minutes
> default per `docs/archive/phases/phase_8S/phase_8S_scheduling_connector_plan.md`)
> is the only live-update path.

---

## Sandbox / test environment

**Base URL**: `https://rest.tsheets.com/api/v1/`
(Intuit / QBT does not run a separate sandbox host; instead the
developer registers an Intuit developer app which can be pointed at
a free trial QBT account for sandbox verification. Verified at
`8.S.QBT.live.sandbox`.)

**Sign-up**:
1. Create an Intuit developer account at <https://developer.intuit.com>.
2. Register a new app; pick the QuickBooks Time scope.
3. Use the issued `client_id` / `client_secret` against a free QBT
   trial company for sandbox round-trip.

**Known limitations**:
- No discrete sandbox host; sandbox + prod target the same base URL.
  Live-sandbox verification gates against a free-trial QBT account.
- No webhook surface; polling-only path is exercised end-to-end at
  `*.live.sandbox`.

---

## Production environment

**Base URL**: `https://rest.tsheets.com/api/v1/`
**Partnership requirements**: none. Public Intuit OAuth.
**Rate-limit policy**:
<https://tsheetsteam.github.io/api_docs/?javascript#rate_limits>
**Quota**: ~20 req/sec per account documented soft cap; bursts above
that are throttled with `429`. The bridge worker token-bucket-throttles
per vendor.

---

## Versioning

**Vendor's deprecation policy**:
<https://tsheetsteam.github.io/api_docs/?javascript#changelog>
**Adapter pinned to**: `v1` (the only version Intuit / QBT documents
for the public API; future versions arrive via the changelog page.)
**Vendor's last announced breaking change**: not announced as of
2026-05-04 retrieval.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The `api_consumed.md`
retrieval date drives the CI lint warning.
