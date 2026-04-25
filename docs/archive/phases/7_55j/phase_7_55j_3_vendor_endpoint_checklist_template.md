# Phase 7.55j.3 - Vendor Endpoint Checklist Template

Updated: 2026-04-23
Owner: Codex planning / tracker truth
Status: Complete - reusable template for vendor-specific Phase 8 / 8R profiling

## Purpose

Turn the capability requirements from `7.55j.1`, `7.55j.2`, `7.55j.gate`,
and `7.55k.8` into one fill-in checklist per selected vendor.

This doc does not invent endpoint names. It gives the exact fields to verify
once official Toast, 7shifts, and OpenTable docs are in hand.

## Usage Rules

- Fill this doc only from official vendor docs, partner portals, or approved
  sandbox tooling.
- Record the source URL or document title for every confirmed endpoint,
  webhook, rate limit, and auth rule.
- Use capability language first. Leave the endpoint/path cell blank until the
  official vendor docs confirm it.
- Mark every capability as one of:
  - `confirmed`
  - `partial`
  - `not exposed`
  - `needs clarification`
- Separate "required for clean launch" from "nice-to-have enrichment."

## Universal Vendor Header

Fill this header once per vendor profile.

| Field | What To Record |
| --- | --- |
| Vendor | Company + product module |
| Surface owner | POS / Labor / Reservation |
| Official access path | Public API, partner API, marketplace program, reseller approval, or private approval flow |
| Approval status | not started / applied / approved / blocked |
| Primary doc sources | URLs or document names used for validation |
| Auth mode | OAuth, API key, service account, partner token, webhook signing secret |
| Sandbox status | available / partial / none |
| Sandbox parity notes | what the sandbox does not mirror from production |
| Location binding model | how app restaurant scope maps to vendor location ids |
| Backfill model | full export, date-range pull, pagination, bulk job, or none |
| Incremental sync model | updated-since cursor, page token, sync token, webhook event id, or none |
| Rate-limit model | published request caps, burst limits, retry rules |
| Webhook model | events offered, retry behavior, ordering guarantees, signature verification |
| PII constraints | fields exposed, fields to discard, retention rules |
| Last verified date | exact date this checklist was confirmed |

## Generic Capability-To-Endpoint Table

Use this table format for every vendor capability profile.

| Capability | Needed For | Required Or Degrade | Official endpoint / webhook | Auth scope / permission | Backfill or incremental path | Rate-limit / pagination notes | Sandbox parity | Status | Evidence source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Example: location lookup | routing vendor data into one restaurant scope | required | TBD from docs | TBD | TBD | TBD | TBD | needs clarification | vendor docs |

## Toast Checklist (POS)

### Capability Checklist

| Capability | Why We Need It | Required Or Degrade | Confirm From Toast Docs |
| --- | --- | --- | --- |
| Location list + external location id | bind one Forge & Flow restaurant to the correct Toast location | required | |
| Closed sales backfill by business date | 60-day benchmark, variance, history, learn | required | |
| Closed covers / guest counts | benchmark demand baseline and CPLH/SPLH truth | required | |
| Check / order / ticket ids | idempotency, deduplication, exemplar tracing | degrade if missing | |
| Business date semantics | avoid calendar-date drift around close | required | |
| Opened / closed / paid / updated timestamps | app-owned service-period bucketing and correction tracking | degrade if missing | |
| Live intraday sales | Shift whole-day actuals | required | |
| Live intraday covers | Shift whole-day actuals | required | |
| Finalization / close-of-business signal | distinguish closed truth from live/open context | degrade if missing | |
| Post-close corrections (voids, refunds, edits) | keep variance/history evidence honest after close | degrade if missing | |
| Revenue center / dining option / service mode | optional attribution and better demand context | optional | |
| Employee / server linkage fields | later attribution and coaching joins | optional for initial launch | |

### Endpoint Inventory Shell

| Capability | Official endpoint / webhook | REST / webhook / export job | Notes to Capture |
| --- | --- | --- | --- |
| Location lookup | | | pagination, restaurant-group shape, id field name |
| Closed sales backfill | | | date filters, timezone, business date vs calendar date |
| Closed covers backfill | | | reliability of guest-count field |
| Live sales / covers | | | polling cadence, freshness SLA |
| Corrections after close | | | refund / void / edit semantics |
| Finalization signal | | | daily-close event or status field |

### Toast Validation Questions

- Is "guest count" reliable enough to treat as covers, or does it require a
  fallback policy by order channel?
- Can Toast expose business date directly, or must the app derive it from
  timestamps plus restaurant timing?
- Are intraday sales and covers available from the same path as closed-truth
  sales, or is there a separate live endpoint?
- What is the authoritative close/finalization signal for a business date?
- How are voids, comps, discounts, refunds, and reopened checks represented?

## 7shifts Checklist (Labor)

### Capability Checklist

| Capability | Why We Need It | Required Or Degrade | Confirm From 7shifts Docs |
| --- | --- | --- | --- |
| Location list + external location id | route labor data into one restaurant scope | required | |
| Employee / worker ids | stable user-to-vendor mapping and attribution | required | |
| Role / job / department fields | FOH / BOH / manager mapping | required | |
| Published schedule shifts | optional schedule-vs-vendor comparison | degrade if missing | |
| Actual punches / timecards by business date | variance, history, learn, benchmark truth | required | |
| Current clocked-in labor | Shift live actuals | required | |
| Wage rates or labor dollars | benchmark wage authority and dollar impact | required for clean variance cost truth | |
| Manager tagging | clean exclusion or split rules for manager labor | degrade if missing | |
| Punch edit / correction semantics | keep closed-truth labor honest after close | degrade if missing | |
| Source shift / punch ids | idempotency, correction replay, exemplar tracing | degrade if missing | |
| Time-range granularity | daypart labor evidence from timestamps, not daily totals | degrade if missing | |

### Endpoint Inventory Shell

| Capability | Official endpoint / webhook | REST / webhook / export job | Notes to Capture |
| --- | --- | --- | --- |
| Location lookup | | | group/company hierarchy, store ids |
| Employee roster | | | stable employee id, archived employee behavior |
| Schedule shifts | | | published vs draft distinction |
| Time punches / timecards | | | edited punch semantics, adjusted hours |
| Current clocked-in staff | | | freshness and polling expectations |
| Wage rates / labor dollars | | | which fields are official vs derived |

### 7shifts Validation Questions

- Does 7shifts expose direct labor dollars, only wage rates, or both?
- Can we distinguish manager labor cleanly from FOH / BOH worker labor?
- Are punches tagged to business date directly, or only by timestamps?
- What is the official correction story for edited punches after close?
- Are published schedules and actual punches exposed from separate modules or
  permission scopes?

## OpenTable Checklist (Reservation)

### Capability Checklist

| Capability | Why We Need It | Required Or Degrade | Confirm From OpenTable Docs |
| --- | --- | --- | --- |
| Location / venue list + external id | route reservations into one restaurant scope | required if reservation feed is enabled | |
| Reservation id | idempotency and update tracking | required | |
| Reservation time + business date | Shift and future daypart mapping | required | |
| Party size | "In the books" covers | required | |
| Status vocabulary | filter booked / confirmed / arrived / seated / cancelled / no-show | required | |
| Status timestamps | better live-state and later history context | optional but strongly preferred | |
| Created / updated timestamps | incremental sync and deduplication | required | |
| Area / room / table / VIP metadata | Daily Board enrichment and future staff context | optional | |
| Waitlist / walk-in support | future enhancement, not launch-critical | optional | |
| Webhook or event stream support | lower-latency updates than polling | degrade if missing | |

### Endpoint Inventory Shell

| Capability | Official endpoint / webhook | REST / webhook / export job | Notes to Capture |
| --- | --- | --- | --- |
| Venue lookup | | | venue id field, multi-venue handling |
| Reservation list / backfill | | | date filters, history limits |
| Reservation updates | | | status transitions, updated-since support |
| Webhooks | | | signature verification, retry, ordering |
| VIP / area metadata | | | field names and access restrictions |

### OpenTable Validation Questions

- What status or timestamp best represents "still in the books" versus seated
  or already completed?
- Does OpenTable expose business date directly, or only reservation-local
  timestamps?
- Is historical reservation backfill available, or only near-term windows?
- Are VIP notes, areas, and walk-in / waitlist records officially exposed?
- How reliable are webhook ordering and replay semantics?

## Final Fill-In Checklist

Before a vendor profile is considered ready for Phase 8 / 8R implementation:

- every required capability is marked `confirmed`, `partial`, or
  `not exposed`
- every required capability has an official endpoint or documented reason it
  is unavailable
- auth mode, sandbox status, rate limits, and webhook behavior are recorded
- blocked-vs-degrade judgment is recorded for every missing or partial field
- the exact doc source used for each answer is captured

## Source Material

- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md)
- [phase_7_55j_2_required_capability_matrix.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_2_required_capability_matrix.md)
- [phase_7_55j_gate_integration_readiness_pressure_test.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md)
- [phase_7_55k_8_integration_implications.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55k/phase_7_55k_8_integration_implications.md)
