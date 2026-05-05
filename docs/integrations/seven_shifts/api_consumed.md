# 7shifts — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `seven_shifts`
**Category**: `labor`
**Source documentation**: <https://developers.7shifts.com>
**Retrieval date**: 2026-05-04
**API version pinned**: `v2-2026-05-04`

7shifts is the highest-share scheduling vendor in F&F's INTEGRATE set
(35% per `docs/phases/phase_8/vendor_master_list.md`). It is also the
**only** scheduling vendor with autoRegister webhooks for
schedule + punch + payroll-period events — and the only vendor that
emits the `payroll_period.closed` event the Phase 7.58 Primary Driver
audit binds against. Webhooks require the Gourmet pricing tier per
<https://www.7shifts.com/pricing>; the adapter detects the operator's
tier at connect time and falls back to polling-only with an explicit
operator-facing note when not on Gourmet.

The adapter binds every assumption it makes about vendor shape via
the `documentedPerSevenShiftsV2FieldMapping` constant in
`lib/integrations/labor/seven_shifts_labor_adapter.dart`; the
`8.S.7S.live.sandbox` slice diffs observed sandbox responses against
that constant row by row.

---

## Auth method

`oauth` — `authorization_code` flow with rotating refresh tokens per
the developer reference. See `oauth_shape.md` for flow detail.

Cite vendor doc: <https://developers.7shifts.com/reference/oauth>

---

## Endpoints consumed

| Method | Path | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|
| POST | `/v2/oauth/token` | OAuth `authorization_code` exchange + `refresh_token` rotation | per <https://developers.7shifts.com/reference/oauth> | n/a |
| GET | `/v2/company/{company_id}` | Read company metadata + plan tier (gates webhook auto-register) | shared | n/a |
| GET | `/v2/company/{company_id}/locations` | Operator-wide grant — list every 7shifts location under the company | shared | cursor (`next_cursor`) |
| GET | `/v2/company/{company_id}/time_punches` | Backfill + incremental poll (modified-since window) | shared | cursor (`next_cursor`) |
| GET | `/v2/company/{company_id}/shifts` | Schedule (planned) shifts; reads alongside punches | shared | cursor (`next_cursor`) |
| GET | `/v2/company/{company_id}/users` | Per-employee wage rates + role assignments | shared | cursor |
| GET | `/v2/company/{company_id}/roles` | Role hierarchy → FOH/BOH/manager/excluded mapping | shared | cursor |
| GET | `/v2/company/{company_id}/payroll_periods?status=closed` | Latest closed payroll-period instant (Primary Driver binding) | shared | cursor |
| GET | `/v2/company/{company_id}/reports/hours_and_wages` | Per-shift gross wage totals (Gourmet tier only — perEmployeeWithDollars wage class) | shared | cursor (`next_cursor`) |
| POST | `/v2/company/{company_id}/webhooks` | Auto-register webhook subscription (Gourmet only) | shared | n/a |
| DELETE | `/v2/company/{company_id}/webhooks/{webhook_id}` | Unregister on disconnect | shared | n/a |

Every endpoint listed is invoked by the adapter code; every endpoint
the adapter invokes is listed here. Codex verifies the diff. Per
`docs/contracts/vendor_adapter_slice_contract.md` rate-limit headers
are honored at the bridge-worker level (token-bucket throttle); the
adapter does not enforce per-call ceilings.

---

## Sandbox / test environment

**Base URL**: `https://api.7shifts.com` (single environment — 7shifts
does not maintain a separate sandbox host; sandbox vs production
distinction is per-credential, not per-endpoint).
**Sign-up**: <https://developers.7shifts.com/reference/getting-started>
(self-serve dev portal — no partnership review required for sandbox
credentials; Gourmet-tier webhooks require a paying customer account).
**Known limitations**:
- The sandbox account 7shifts issues at developer signup is a single
  fixed company with synthetic data; webhooks fire only when the
  developer toggles the test event in the portal.
- Plan-tier detection on the sandbox returns whatever tier the
  developer configured for their dev company — the adapter's
  Gourmet-fallback path is verified by toggling between Gourmet and
  a lower tier on the sandbox dev account.

---

## Production environment

**Base URL**: `https://api.7shifts.com`
**Partnership requirements**: None — public OAuth. The operator
signs in to their own 7shifts account; F&F never holds production
client credentials beyond the standard OAuth client_id /
client_secret pair held server-side per Hard Promise #7.
**Rate-limit policy**: <https://developers.7shifts.com/reference/rate-limits>
**Quota**: Per the developer reference; bridge-worker token-bucket
throttle smooths bursty backfill traffic.

---

## Versioning

**Vendor's deprecation policy**: 7shifts publishes deprecations on
the developer reference's changelog page; operator notice is
typically 90+ days.
**Adapter pinned to**: `v2-2026-05-04` — every URL above is the v2
shape captured 2026-05-04. The
`documentedPerSevenShiftsV2FieldMapping` constant carries the
api_version string; bumping it is a slice in itself when 7shifts
ships a v3 (rare).
**Vendor's last announced breaking change**: none observed at the
2026-05-04 retrieval date.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The adapter will
re-pin the API version on the first observed breaking change in
`8.S.7S.live.sandbox` or a future re-verification slice.

---

## Webhook gating (Gourmet plan)

`POST /v2/company/{company_id}/webhooks` returns `402 Payment
Required` (or equivalent per the developer reference) when the
operator is not on the Gourmet pricing tier. The adapter's
`connect()` flow detects the tier via
`fetchCompanyInfo() → SevenShiftsCompanyInfo.planTier` BEFORE invoking
the webhook endpoint:

- `planTier == kSevenShiftsGourmetPlanTier` → adapter calls
  `registerWebhook` with every event in
  `kSevenShiftsSubscribedWebhookEvents` (including `payroll_period.closed`).
- `planTier != kSevenShiftsGourmetPlanTier` → adapter skips the
  webhook call entirely; `ConnectResult.metadata` omits the
  `webhook_id` key; `TestConnectionResult.note` carries the explicit
  operator-facing copy `kSevenShiftsNonGourmetNote`. The adapter
  continues polling for both punches AND the latest closed payroll
  period (via `fetchLatestPayrollPeriodClosedAt`) so Phase 7.58
  Primary Driver finalization still lands in canonical facts on
  every polling tick.

This shape is verified by the slice's plan-tier fallback test
(`Test 9`) and walked through in `docs/_walkthroughs/8.S.7S.md`.

---

## Hours & Wages report (Gourmet tier)

The `/v2/company/{company_id}/reports/hours_and_wages` endpoint
exposes `total_pay` per shift (plus `regular_pay` and `overtime_pay`)
and is Gourmet-tier-gated — lower plan tiers return HTTP 403 (or 404,
per the developer reference's ambiguous gating doc). Lane
`8.spine-bridge.7S.upgrade` (2026-05-05) added the report consumption
so 7shifts qualifies as `LaborWageSourceClass.perEmployeeWithDollars`
— the highest-fidelity wage class — per
`docs/contracts/integration_spine_architecture_contract.md` 2026-05-05
falsehood corrections #7. The adapter calls
`fetchHoursAndWagesReport` alongside `listTimePunches` on every
poll/backfill tick and merges by (employee_id, shift_id). On 403/404
the adapter catches `SevenShiftsHoursAndWagesReportGatedException` and
falls through to `/time_punches`-only emission with wage_provenance =
`vendor_seven_shifts_dollars_unavailable_target_wage_substituted` so
non-Gourmet operators still land canonical facts (sans dollars). On
success, wage_provenance =
`vendor_seven_shifts_per_employee_actual_dollars`. The behavior is
verified by the `Hours & Wages report` test group in
`test/integrations/labor/seven_shifts_labor_adapter_test.dart`.

Cite vendor doc: <https://developers.7shifts.com/reference/get_reports-hours-and-wages>
