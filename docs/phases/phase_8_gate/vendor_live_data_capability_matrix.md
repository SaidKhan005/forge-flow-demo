# Vendor Live-Data Capability Matrix

Updated: 2026-04-13
Owner: Claude research (7.55n.12)
Status: Official-doc-backed audit

## Purpose

Side-by-side comparison of candidate vendor live-data capabilities as they
relate to Forge & Flow's freshness contract and Shift-as-live-surface goal.

All findings are backed by official vendor developer documentation.
Where official docs are unclear or capability is gated behind partner access,
that is stated plainly.

## POS Vendors

### Toast

| Capability | Status | Evidence |
|---|---|---|
| Auth model | OAuth 2 client-credentials (JWT) | [Authentication](https://doc.toasttab.com/doc/devguide/authentication.html) |
| Partner gating | Yes - Partner/Custom tiers require Toast review; Standard tier is self-service | [Authentication](https://doc.toasttab.com/doc/devguide/authentication.html) |
| Sandbox | Yes (Partner/Custom only; 9 AM-6 PM ET) | [Environments](https://doc.toasttab.com/doc/devguide/apiEnvironments.html) |
| Webhooks | **Supported** - 8 event categories incl. Orders; 3 delivery attempts (5-min, 10-min retry); dropped after 3 failures | [Webhooks Reference](https://doc.toasttab.com/doc/devguide/apiWebhooksReference.html), [Retry Support](https://doc.toasttab.com/doc/devguide/apiRetrySupport.html) |
| Polling / incremental sync | **Supported** - `/ordersBulk` with `startDate`/`endDate` timestamp filters; page-based pagination (max 100); `/timeEntries` with `modifiedStartDate`/`modifiedEndDate` | [Getting Multiple Orders](https://doc.toasttab.com/doc/devguide/apiOrdersGetDetailedInfoAboutMultipleOrders.html) |
| Rate limits | 20 req/s global, 10,000 req/15 min; `/ordersBulk` = 5 req/s per location | [Rate Limiting](https://doc.toasttab.com/doc/devguide/apiRateLimiting.html) |
| Intraday sales/orders | **Supported** - `/ordersBulk` returns current-day orders with `createdDate`, `closedDate`, `modifiedDate`, `amount`, `totalAmount`, checks, payments, items | [Order Object Summary](https://doc.toasttab.com/doc/devguide/apiOrdersOrderObjectSummary.html) |
| Covers / guest count | **Supported** - `numberOfGuests` field on Order object | [Order Type Details](https://doc.toasttab.com/doc/devguide/apiOrderTypeDetails.html) |
| Order timestamps | **Supported** - `createdDate`, `openedDate`, `closedDate`, `modifiedDate`, `paidDate`, `voidDate` | [Order Object Summary](https://doc.toasttab.com/doc/devguide/apiOrdersOrderObjectSummary.html) |
| Close/finalization signal | **Limited** - No explicit business-day close API; `closeoutHour` in restaurant config; cash management API exposes `businessDate`; platform has "Close Out Day" UI but no API event | [Cash Deposits](https://doc.toasttab.com/doc/devguide/apiCalculatingExpectedCashDeposits.html), [Close Out Day](https://doc.toasttab.com/doc/platformguide/platformCloseOutDayOverview.html) |
| Labor / time entries | **Supported** - `/timeEntries` with `regularHours`, `overtimeHours`, `hourlyWage`, breaks (paid/unpaid); `/employees` and `/jobs` for role data; requires `labor:read` scope | [Building Labor Reports](https://doc.toasttab.com/doc/cookbook/apiIntegrationChecklistPayroll.html) |
| Schedule / shifts | **Supported** - `/labor/v1/shifts` with `inDate`, `outDate`, `jobReference`, `employeeReference`; filterable by date range | [Get Shifts](https://doc.toasttab.com/openapi/labor/operation/shiftsGet/), [Shift Schema](https://doc.toasttab.com/openapi/labor/tag/Data-definitions/schema/Shift/) |

### Square

| Capability | Status | Evidence |
|---|---|---|
| Auth model | OAuth 2.0 (Code flow and PKCE); also personal access tokens for dev use | [OAuth Overview](https://developer.squareup.com/docs/oauth-api/overview) |
| Partner gating | No mandatory partner program; any developer can create an app | [OAuth Overview](https://developer.squareup.com/docs/oauth-api/overview) |
| Sandbox | Yes - free, unlimited calls, separate base URL; Note: Square for Restaurants features not available in sandbox | [Sandbox Overview](https://developer.squareup.com/docs/devtools/sandbox/overview) |
| Webhooks | **Supported** - Order, Payment, and other event types; retries for up to 24 hours with exponential backoff; `event_id` for idempotency | [Webhooks Overview](https://developer.squareup.com/docs/webhooks/overview) |
| Polling / incremental sync | **Supported** - `SearchOrders` endpoint with query filters; cursor-based pagination documented on other endpoints | [Orders API](https://developer.squareup.com/docs/orders-api/manage-orders) |
| Rate limits | Per-endpoint limits (exact numbers not confirmed from fetched docs; Square documents them per API) | [Square Docs](https://developer.squareup.com/docs) |
| Intraday sales/orders | **Supported** - `SearchOrders` and `RetrieveOrder`; fields include line items, taxes, discounts, service charges, fulfillments, customer refs | [Orders API](https://developer.squareup.com/docs/orders-api/manage-orders) |
| Covers / guest count | **Unclear from docs** - No `guestCount` or `covers` field documented on the Order object; Square is not restaurant-first POS | [Orders API](https://developer.squareup.com/docs/orders-api/manage-orders) |
| Order timestamps | **Supported** - `created_at`, `updated_at`, `closed_at` on Order object | [Orders API](https://developer.squareup.com/docs/orders-api/manage-orders) |
| Close/finalization signal | **Unclear from docs** - No explicit business-day close endpoint documented | [Square Docs](https://developer.squareup.com/docs) |
| Labor / time cards | **Supported** - Labor API exposes Timecards with start/end, breaks (paid/unpaid), wage info (title, hourly rate), tips, status (OPEN/CLOSED); Team API for member profiles and jobs | [Labor API](https://developer.squareup.com/docs/labor-api/what-it-does) |
| Schedule / shifts | **Supported** - Labor API exposes `ScheduledShifts` resource for team scheduling | [Labor API](https://developer.squareup.com/docs/labor-api/what-it-does) |

### Clover

| Capability | Status | Evidence |
|---|---|---|
| Auth model | OAuth 2.0 authorization code flow via Clover App Market | [OAuth 2.0](https://docs.clover.com/docs/using-oauth-20) |
| Partner gating | Yes - apps must go through Clover approval process for marketplace | [App Approval](https://docs.clover.com/docs/clover-app-approval-process) |
| Sandbox | Yes - full sandbox with configurable test merchants | [Test Merchants](https://docs.clover.com/dev/docs/use-test-merchants-dashboard) |
| Webhooks | **Supported** - 12 event types incl. Orders (O), Payments (P), Employees (E); payloads include objectId, type (CREATE/UPDATE/DELETE), timestamp; HTTPS required | [Webhooks](https://docs.clover.com/dev/docs/webhooks) |
| Polling / incremental sync | **Supported** - Offset-based pagination (max 1000); `modifiedTime` filtering with comparison operators; **90-day filter window cap** | [Filters](https://docs.clover.com/dev/docs/applying-filters), [Pagination](https://docs.clover.com/dev/docs/paginating-elements) |
| Rate limits | Per-app: 50 req/s, 10 concurrent; per-token: 16 req/s, 5 concurrent | [Rate Limits](https://docs.clover.com/dev/docs/api-usage-rate-limits) |
| Intraday sales/orders | **Supported** - `/v3/merchants/{mId}/orders` with `createdTime` filter; fields include total, state, lineItems, payments, discounts, taxes, tips | [Working with Orders](https://docs.clover.com/dev/docs/working-with-orders), [Orders API](https://docs.clover.com/dev/reference/ordergetorders) |
| Covers / guest count | **Unavailable** - Order schema has no guestCount, covers, or partySize field | [Order Schema](https://docs.clover.com/dev/reference/ordercreateorder) |
| Order timestamps | **Supported** - `createdTime`, `modifiedTime` on orders | [Orders API](https://docs.clover.com/dev/reference/ordergetorders) |
| Close/finalization signal | **Limited** - `closeout()` in SDK is payment-batch closeout, not business-day close; no daily reconciliation API | [Closeout](https://docs.clover.com/dev/docs/closeout) |
| Labor / shifts | **Supported** - Employee shift endpoints with `inTime`, `outTime`, override times, `cashTipsCollected`; CSV export available; **no break tracking fields documented** | [Employee Shifts](https://docs.clover.com/dev/reference/employeegetemployeeshifts) |
| Schedule | **Unavailable** - No schedule management endpoints documented | [Clover Docs](https://docs.clover.com) |

## Labor Vendor

### 7shifts

| Capability | Status | Evidence |
|---|---|---|
| Auth model | OAuth 2.0 client credentials for partners; scoped tokens (e.g., `shifts:read`, `time_punches:write`); 1-hour token expiry | [Authentication](https://developers.7shifts.com/reference/authentication), [OAuth](https://developers.7shifts.com/docs/oauth-authentication) |
| Partner gating | Yes - contact `partnerships@7shifts.com` for OAuth client | [Overview](https://developers.7shifts.com/docs/overview-1) |
| Sandbox | Limited - test/sandbox via test 7shifts account; no public self-service sandbox | [Overview](https://developers.7shifts.com/docs/overview-1) |
| Webhooks | **Supported** (Gourmet plan required) - `time_punch.created/edited/deleted`, `schedule.published`, `payroll_period.closed`, user/dept/location/role CRUD events | [Webhooks](https://developers.7shifts.com/reference/webhooks-introduction) |
| Polling / incremental sync | **Supported** - Cursor-based pagination + `modified_since` (ISO8601) on shifts; cursor pagination + `clocked_in[gte/lte]` on punches | [List Shifts](https://developers.7shifts.com/reference/listshift) |
| Rate limits | 10 req/s per access token | [Overview](https://developers.7shifts.com/docs/overview-1) |
| Scheduled shifts | **Supported** - `GET /v2/company/{id}/shifts` with start/end datetime, location_id, department_id, role_id, user_id, draft/open status; cursor pagination (limit 1-500) | [List Shifts](https://developers.7shifts.com/reference/listshift) |
| Time punches / clock data | **Supported** - `clocked_in`, `clocked_out` (UTC), `approved` boolean, `hourly_wage`, `tips`, breaks array (paid/in/out) | [Time Punch Data](https://developers.7shifts.com/docs/read-time-punch-data) |
| Approved/finalized hours | **Supported** - `approved` boolean on punches; docs state "only include for payroll when approved is true"; `payroll_period.closed` webhook for period finalization | [Time Punch Data](https://developers.7shifts.com/docs/read-time-punch-data), [Webhooks](https://developers.7shifts.com/reference/webhooks-introduction) |
| Wages / labor dollars | **Supported** - Per-employee `wage_cents`, `wage_type`, `effective_date`, `role_id` via wages endpoint; `hourly_wage` on punch objects; aggregate hours/wages report available | [Wage Data](https://developers.7shifts.com/docs/read-employee-wage-data), [Hours & Wages Report](https://developers.7shifts.com/reference/gethoursandwages) |
| Roles / departments | **Supported** - Location > Department > Role hierarchy; CRUD webhooks; suitable for FOH/BOH classification by role/department mapping | [Mapping](https://developers.7shifts.com/docs/mapping) |

## Freshness SLA Summary

| Vendor | Best-case foreground freshness | Webhook-driven freshness | Polling fallback freshness |
|---|---|---|---|
| **Toast** | Near-live via webhook + intraday polling (1-5 min) | Order webhooks fire on order events; 3 delivery attempts then dropped | `/ordersBulk` with timestamp filters; 5 req/s per location allows ~1-min polling cycles |
| **Square** | Near-live via webhook + search polling | Order/payment webhooks with 24-hr retry; exponential backoff | `SearchOrders` with date filters; per-endpoint rate limits |
| **Clover** | Refreshed (not truly live) via polling | Order/payment webhooks fire on CREATE/UPDATE/DELETE | Offset pagination + `modifiedTime` filters; 16 req/s per token; 90-day window cap on filters |
| **7shifts** | Near-live for punches via webhook (Gourmet plan) | `time_punch.created/edited/deleted` + `payroll_period.closed` | Cursor + `modified_since` on shifts; cursor + date filters on punches; 10 req/s |

## Covers/Guest Count Availability

This is a critical field for Forge & Flow's CPLH calculation.

| Vendor | Covers available? | Notes |
|---|---|---|
| Toast | **Yes** - `numberOfGuests` on Order | Strongest covers support among POS candidates |
| Square | **Unclear** | Not restaurant-first POS; no guest count field documented on Order object |
| Clover | **No** | Order schema confirmed with no guest count / covers / party size field |
| 7shifts | N/A | Labor vendor; does not own covers |

## Close/Finalization Signal Availability

| Vendor | Signal available? | Notes |
|---|---|---|
| Toast | **Limited** | `closeoutHour` config exists; cash management references `businessDate`; no explicit API finalization event |
| Square | **Unclear** | No business-day close endpoint found in docs |
| Clover | **Limited** | Payment-batch `closeout()` only; no business-day close API |
| 7shifts | **Supported** (for labor) | `payroll_period.closed` webhook; `approved` boolean on punches |

## Timestamp Quality for Service-Period Bucketing

| Vendor | Usable for app-owned service-period mapping? | Notes |
|---|---|---|
| Toast | **Yes** | `openedDate`, `closedDate`, `paidDate` on orders; `inTime`/`outTime` on shifts/punches |
| Square | **Likely yes** | `created_at`, `updated_at`, `closed_at` on orders; start/end on timecards |
| Clover | **Limited** | `createdTime`, `modifiedTime` on orders but no `closedTime` documented; `inTime`/`outTime` on shifts |
| 7shifts | **Yes** | `clocked_in`, `clocked_out` (UTC) on punches; start/end datetime on scheduled shifts |
