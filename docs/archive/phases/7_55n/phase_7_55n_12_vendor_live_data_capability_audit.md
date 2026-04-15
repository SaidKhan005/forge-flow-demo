# Phase 7.55n.12 - Vendor Live-Data Capability Audit

Updated: 2026-04-13
Owner: Claude research
Status: Landed

## Goal

Research the real live-data capabilities of candidate vendors so we can
answer honestly how close to live Forge & Flow can get for Shift and
other current-state surfaces.

## Scope

- In: official-doc-backed vendor capability research for Toast, Square,
  Clover (POS) and 7shifts (labor); freshness SLA implications per vendor;
  side-by-side capability matrix; honest product implication analysis
- Out: actual connector implementation, vendor selection decision, Phase 8
  adapter code, polling/webhook plumbing

## Audited Vendors

| Vendor | Type | Official Docs |
|---|---|---|
| Toast | POS | https://doc.toasttab.com |
| Square | POS | https://developer.squareup.com/docs |
| Clover | POS | https://docs.clover.com |
| 7shifts | Labor | https://developers.7shifts.com |

## What This Audit Establishes

### 1. Shift can be near-live with Toast + 7shifts

Toast is the strongest POS candidate for the manager-live Shift use case:

- **Covers**: Toast exposes `numberOfGuests` on the Order object. This is
  the only POS candidate with confirmed guest-count availability. CPLH
  calculation depends on covers.
- **Intraday orders**: `/ordersBulk` with `startDate`/`endDate` returns
  current-day orders including amounts, checks, items, and timestamps.
- **Webhooks**: Order webhooks fire on order events with 3 delivery
  attempts. Combined with intraday polling at 5 req/s per location,
  Shift freshness of 1-5 minutes is achievable.
- **Timestamps**: `openedDate`, `closedDate`, `modifiedDate`, `paidDate`
  support app-owned service-period bucketing.
- **Labor**: Toast also has its own labor API with time entries, wages,
  hours, and shift schedules. However, 7shifts is the stronger labor
  candidate for depth (see below).

7shifts is the strongest labor candidate:

- **Punches with wages**: `clocked_in`, `clocked_out`, `hourly_wage`,
  breaks, and `approved` boolean directly on punch objects.
- **Finalization signal**: `approved` boolean + `payroll_period.closed`
  webhook provide an explicit finalized-hours signal that no other
  candidate matches.
- **Cursor + modified_since**: Real incremental sync support for both
  shifts and punches.
- **Roles/departments**: Location > Department > Role hierarchy enables
  FOH/BOH classification by mapping role names.

**Best-case Shift freshness with Toast + 7shifts:**
Near-live (1-5 minutes) for sales and covers via Toast webhook + polling.
Near-live for labor punches via 7shifts `time_punch` webhooks (Gourmet
plan required). The app's freshness contract would show `Live` when data
is within the 5-minute window and `Updated X min ago` otherwise.

### 2. Square is viable but weaker for restaurant-specific Shift

Square is a strong general POS platform with good webhook and Labor API
support, but:

- **No confirmed covers/guest count**: The Order object does not document
  a `guestCount` or `covers` field. Square is not restaurant-first.
  Without covers, CPLH calculation degrades to check-count estimation or
  forecast-covers fallback.
- **No explicit close/finalization**: No business-day close signal
  documented.
- **Labor API is capable**: Timecards with start/end, breaks, wages,
  tips, and status (OPEN/CLOSED). ScheduledShifts for scheduling. Team
  API for member profiles and jobs.
- **Good webhook support**: 24-hour retry with exponential backoff is
  more resilient than Toast's 3-attempt policy.

**Shift freshness with Square:**
Refreshed but not restaurant-live. Sales polling is feasible. Covers
gap is a product-level degradation — CPLH becomes estimation-based.

### 3. Clover has the most significant gaps

- **No covers/guest count**: Confirmed absent from the Order schema.
- **No business-day close signal**: Only payment-batch closeout exists.
- **No schedule endpoints**: No documented schedule management API.
- **90-day filter window cap**: Historical queries require windowed
  iteration for the 60-day backfill.
- **No break tracking on shifts**: Employee shift data has clock in/out
  but no documented break fields.

**Shift freshness with Clover:**
Refreshed via polling (16 req/s per token is adequate), but missing
covers and close signals force the most degradation among POS candidates.

### 4. Vendor selection is still not decided, but evidence points clearly

| Criterion | Toast | Square | Clover |
|---|---|---|---|
| Covers for CPLH | Yes | Unclear | No |
| Intraday sales | Yes | Yes | Yes |
| Order timestamps for daypart | Strong | Adequate | Limited |
| Webhooks for near-live | Yes (3 attempts) | Yes (24-hr retry) | Yes |
| Close/finalization | Limited | Unclear | Limited |
| Built-in labor | Yes | Yes | Limited |
| Partner gating | Requires review | Open | Requires approval |

**Plainest answer**: Toast + 7shifts is the strongest pairing for the
manager-live Shift use case because Toast is the only POS candidate
with confirmed covers and the richest order timestamps, and 7shifts is
the only labor candidate with an explicit finalization signal and
per-punch wage data.

If covers are not critical for the first integration (forecast-covers
fallback is acceptable), Square becomes viable as a POS alternative
with the advantage of lower access barriers and stronger webhook
delivery guarantees.

Clover requires the most app-side degradation and should be considered
only if the restaurant is already on Clover and migration is not
practical.

## Degradation Paths

These are the specific product degradation paths the app must support
regardless of vendor choice:

| Gap | Which vendors | App degradation |
|---|---|---|
| No reliable covers | Square (unclear), Clover (confirmed absent) | Fall back to check count or forecast covers; CPLH becomes estimation-based; document accuracy trade-off |
| No close/finalization signal | Toast (limited), Square (unclear), Clover (limited) | App's existing close-policy evaluation path handles this; `ShiftBoundaryResolver` uses `appLocalCutoffFallback` when vendor finalization is unavailable |
| No timestamp depth for daypart | Clover (limited) | Whole-day Shift works; daypart-level evidence (History benchmarks, Learn wins) degrades or stays hidden via interim visibility rules |
| No approved/finalized hours | Toast (no explicit), Square (CLOSED status only), Clover (no) | Only 7shifts provides explicit `approved` + `payroll_period.closed`; without this, app treats closed-status punches as finalized (less precise) |
| No schedule endpoints | Clover | Schedule comparison unavailable; Shift loses scheduled-hours context |
| Webhook not guaranteed | All (varying retry policies) | Polling fallback required for all vendors; boundary monitor (7.55n.10) + resume refresh (7.55n.9) provide additional catch-up |

## App-Side Readiness

The app's freshness architecture is ready to consume vendor live data:

| Seam | Status | Slice |
|---|---|---|
| Shared freshness model (`CurrentStateFreshness`) | Landed | 7.55n.7 |
| Shift freshness UI (`Live` / `Updated X min ago`) | Landed | 7.55n.8 |
| App resume refresh | Landed | 7.55n.9 |
| Boundary invalidation (business-date rollover) | Landed | 7.55n.10 |
| Write/import propagation contract | Landed | 7.55n.11 |
| `notifyImportCompletionPersisted()` entrypoint | Landed | 7.55n.11 |

A Phase 8 connector would:
1. Persist imported data to the canonical SQLite store
2. Call `AppRuntimeInvalidationBus.instance.notifyImportCompletionPersisted()`
3. The existing coordinator refreshes Shift and Variance surfaces
4. The freshness model evaluates whether the data is within the live window

## Remaining Gaps

- **Vendor selection**: Still TBD. This audit provides evidence but does
  not force a decision.
- **Actual account access**: Official docs describe capabilities, but
  actual behavior may differ behind partner/partner-gated tiers. Toast
  sandbox requires Partner access.
- **Webhook reliability under load**: Official docs describe retry
  policies but not real-world delivery rates under restaurant peak load.
- **Proof and blocker cleanup** (7.55n.13): Pre-existing
  `snapshot_blended_wage` schema gap still blocks SQLite-backed tests.
- **Full timezone conversion**: Business-date resolution still assumes
  device timezone matches restaurant timezone (documented in 7.55n.10).
