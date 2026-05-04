# QuickBooks Time — OAuth Shape

**Vendor ID**: `quickbooks_time`
**Source documentation**:
<https://tsheetsteam.github.io/api_docs/?javascript#authentication>
plus Intuit's OAuth 2.0 reference at
<https://developer.intuit.com/app/developer/qbo/docs/develop/authentication-and-authorization/oauth-2.0>
**Retrieval date**: 2026-05-04

---

## Flow type

`authorization_code`

The operator clicks Connect in F&F's admin Vendor connections widget
→ F&F redirects to Intuit's authorization page → operator approves
→ Intuit redirects back to F&F's callback URL with an
`authorization_code` → adapter exchanges it for an access + refresh
token via Intuit's bearer token endpoint.

Cite vendor doc:
<https://developer.intuit.com/app/developer/qbo/docs/develop/authentication-and-authorization/oauth-2.0#step-3-exchange-authorization-code-for-access-token>

---

## Scopes requested

Exact scope strings (Intuit OpenID Connect format):

| Scope | Unlocks | Required for |
|---|---|---|
| `com.intuit.quickbooks.payroll.time.access` | Read timesheets, jobcodes, users, groups | Backfill + polling |
| `openid` | OpenID identity claim (operator's Intuit account) | Connect-flow operator binding |
| `profile` | Operator's display name (admin-surface only) | Connect-flow display |

Minimum-privilege subset chosen. Extra scopes the vendor offers but
the adapter does NOT request:

- `com.intuit.quickbooks.payroll.time.write` — F&F is read-only at V1
  per Hard Promise #1 (pure transport). No write-back.
- `com.intuit.quickbooks.accounting` — different module (see
  Module disambiguation below; refused by `connect`).
- `com.intuit.quickbooks.payroll` — different module (see Module
  disambiguation below; refused by `connect`).

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token | 1h | Refresh proactively at `expires_at - 1h` via `oauth_refresh_cron.dart` |
| Refresh token | 100 days, rotating | Each refresh issues a new refresh token; old token revoked |

Source: Intuit OAuth 2.0 reference, "Token lifetimes" section.

---

## Refresh semantics

- **Proactive refresh**: cron at 5min past every hour scans
  `vendor_credentials` for tokens with `token_expires_at < now() +
  24h` and refreshes. See
  `lib/services/integration/oauth_refresh_cron.dart`.
- **Reactive refresh on 401**: adapter retries once after refreshing.
- **3 consecutive failures**: `connector_connection.status` flips to
  `error`; audit row written. Email notification deferred to
  `9.8.email` follow-up per V1 lean cut 2.
- **Rotating vs sliding**: rotating (each refresh issues a new
  refresh token; old is revoked).
- **Revocation**: vendor exposes
  `https://developer.api.intuit.com/v2/oauth2/tokens/revoke`; adapter
  calls it best-effort on disconnect. Vendor outage MUST NOT block
  disconnect.

---

## Per-location vs operator-wide grant

`operatorWide`. One Intuit OAuth realm covers all of the operator's
QBT locations. F&F maps each vendor location (returned by
`GET /api/v1/groups`) to one F&F `location_id` at connect time
through the `connector_location_binding` table.

Matches `VendorCapabilityProfile.grantScope = VendorGrantScope.operatorWide`.

---

## Module disambiguation

**Required for QuickBooks** (alongside ADP). The "QuickBooks" brand
spans three Intuit products; only QuickBooks Time is supported by
this adapter. The admin Vendor connections widget renders a pre-card
sub-dialog when `VendorCapabilityProfile.modules` is non-empty (per
`docs/phases/phase_8/vendor_connections_admin_surface.md`).

| Module | Detection | Outcome |
|---|---|---|
| `time` (QuickBooks Time) | Operator-supplied module hint `time` from sub-dialog OR OAuth scope contains `com.intuit.quickbooks.payroll.time.access` | INTEGRATE — proceed with the standard authorization_code exchange; persist `connector_connection.metadata.module = 'time'`. |
| `accounting` (QuickBooks Online — Accounting) | Operator-supplied module hint `accounting` from sub-dialog | **Refused with redirect.** `ModuleRefusalException(module: 'accounting')` is raised before any OAuth exchange. The admin surface renders the operator-facing copy: "QuickBooks Online (Accounting) is an outbound integration. Please connect it from the Outbound Integrations section." Accounting is the Phase 8.5 outbound surface; connect lane lives there. |
| `payroll` (QuickBooks Payroll) | Operator-supplied module hint `payroll` from sub-dialog | **Refused (not supported).** `ModuleRefusalException(module: 'payroll')` is raised before any OAuth exchange. The admin surface renders the operator-facing copy: "QuickBooks Payroll is not supported as a standalone connector. Connect QuickBooks Time for scheduling and punches; payroll runs separately." |

**Detection precedence.** The operator's module pick from the
sub-dialog is the source of truth. If the operator skipped the
sub-dialog (legacy reconnect flows), the adapter falls back to
detecting from the access-token scope; if neither is present, the
adapter defaults to `time` and proceeds — but the admin surface
always renders the sub-dialog at first connect, so the fallback is
never the V1 production path.

**Module persistence.** The chosen module is recorded in
`connector_connection.metadata.module`. Subsequent reconnect flows
skip the sub-dialog and reuse the persisted module so reconnections
are frictionless.

---

## Edge cases

- **Refresh token expiry** (100 days unused): connection flips to
  `error` with operator-facing copy "Please reconnect QuickBooks Time
  and sign in again."
- **Account deletion** (vendor returns 404 on token introspection):
  connection flips to `error` with copy "Your QuickBooks Time account
  no longer exists. Please connect a different account or check with
  Intuit support."
- **Scope downgrade by vendor**: vendor returns access token with
  fewer scopes than requested → adapter rejects, surfaces error
  "QuickBooks denied required permissions; please reconnect and
  approve all requested permissions."
- **Operator picks wrong module by mistake**: sub-dialog shows the
  three QuickBooks products with brief inline explainers per
  `memory/project_ux_writing_standard.md`; if the operator changes
  their mind mid-flow, the dialog Cancel button drops the operator
  back to the vendor picker without persisting any state.
- **Unknown errors**: log + retry once; on second failure, flip to
  `error`.
