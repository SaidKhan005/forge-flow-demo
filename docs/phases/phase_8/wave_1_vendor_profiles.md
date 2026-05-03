# Wave 1 Vendor Capability Profiles

Updated: 2026-05-03
Status: Locked for Wave 1 reference adapters
Owner: Phase 8 framework lane

These are the per-vendor capability profiles for the three Wave 1 reference adapters (Lightspeed K-Series, Libro, QuickBooks Time). Format follows `docs/archive/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md`.

The remaining 14 INTEGRATE vendors get their own capability profiles when their adapter slice spawns.

---

## Lightspeed Restaurant K-Series (POS reference adapter — `8.LSK`)

| Field | Value |
| --- | --- |
| Vendor | Lightspeed Commerce — Restaurant K-Series module |
| Product module | K-Series (formerly Kounta; restaurant-specific) |
| Official access path | Public Developer Portal (Standard tier self-serve); Partner tier requires sales contact |
| Approval status | self-serve via developer.lightspeedhq.com — operator action required pre-spawn |
| Primary doc sources | https://api-docs.lsk.lightspeed.app/ + https://api-docs.sbx.lsk.lightspeed.app/ |
| Auth mode | OAuth 2.0 (authorization code flow) |
| Sandbox status | available — `api.trial.lsk.lightspeed.app` (trial) and `api-docs.sbx.lsk.lightspeed.app` (sandbox) |
| Sandbox parity notes | sandbox does not exercise high-volume rate limits; intraday burst behavior must be re-verified against trial-tier production after partnership |
| Location binding model | one OAuth grant per `business_id`; multi-location operators get one grant covering all locations under that business |
| Backfill model | `/financials` daily summary endpoints + `/transactions` with date filters; max 60-day window per request, paginate for longer |
| Incremental sync model | `modified_since` polling on `/transactions`; webhooks for live (`Order: CHECK_WAS_UPDATED`, `Account: CLOSED`, `Payment: ...`) |
| Rate-limit model | Published per-token rate limits; specific values vary by tier — verify in dev portal at provisioning time |
| Webhook model | Order / Account / Payment event categories; HTTPS endpoint registration via API; signature verification via shared secret |
| PII constraints | customer email/name on order objects (when captured); operator-owned PII fields, F&F discards or stores per operator privacy preferences |
| Last verified date | 2026-05-03 |

### Capability checklist (Lightspeed K-Series)

| Capability | Status | Notes |
|---|---|---|
| Location list + external location ID | confirmed | `/business/{id}/locations` |
| Closed sales backfill by business date | confirmed | `/financials/business-day-sales` |
| Closed covers / guest counts | **confirmed** | `covers` field on `/transactions` |
| Check / order / ticket IDs | confirmed | Stable IDs across `/transactions` and `/checks` |
| Business date semantics | confirmed | Aligned with restaurant-configured business-day cutoff |
| Opened / closed / paid timestamps | confirmed | All four present on transaction objects |
| Live intraday sales | confirmed | `/checks/open` + polling cadence supports 5-min freshness |
| Live intraday covers | confirmed | Same source |
| Finalization signal | confirmed | `Account: CLOSED` webhook fires when business day closes |
| Post-close corrections | confirmed | `CHECK_WAS_UPDATED` webhook + modified_since polling catches refunds/voids |
| Revenue center / dining option | confirmed | `service_id` and `course_id` on transactions |

### Validation questions answered at engineering start

- Confirm trial-tier rate limits for the operator's actual scale.
- Confirm webhook signature header format (HMAC-SHA256 expected).
- Confirm whether bulk historical backfill needs partner-tier pagination tooling.

### Implementation notes for `8.LSK`

- This is the **reference adapter** that proves the framework. Build first; other POS adapters mirror this shape.
- Webhook URL: `https://api.forgeflow.app/v1/webhooks/lightspeed_lsk/{operator_id}/{location_id}`.
- Wage data: not exposed by Lightspeed K-Series — labor lives in scheduling adapters.

---

## Libro (Reservations reference adapter — `8R.LB`)

| Field | Value |
| --- | --- |
| Vendor | Libro Reserve (libroreserve.com) |
| Product module | Reservation Management System |
| Official access path | Public OAuth + REST docs at https://libroreserve.github.io/api-documentation/ |
| Approval status | self-serve — no formal partnership program required |
| Primary doc sources | https://libroreserve.github.io/api-documentation/, https://github.com/libroreserve |
| Auth mode | OAuth 2.0 (authorization code + client credentials); bearer tokens with refresh |
| Sandbox status | URLs documented but not labeled as sandbox; engineering action required to confirm test-environment provisioning at start |
| Sandbox parity notes | TBD at engineering start — likely use a Libro test account on production with throttled volumes |
| Location binding model | venue-scoped tokens; one OAuth grant per Libro venue (= one F&F location) |
| Backfill model | `/reservations` with date-range filters; cursor pagination |
| Incremental sync model | webhook-driven (HMAC-SHA256 signed) for live; date-filter polling for catch-up |
| Rate-limit model | not publicly documented — engineering action: confirm at provisioning |
| Webhook model | reservation lifecycle events with HMAC-SHA256 signature; per-status webhook events including `arrived`, `seated`, `completed`, `canceled` |
| PII constraints | guest name/email/phone on reservation objects; F&F stores aggregated party-size only at V1 (no guest-level PII surfacing per HP #6 / Phase 8R aggregate-first scope) |
| Last verified date | 2026-05-03 |

### Capability checklist (Libro)

| Capability | Status | Notes |
|---|---|---|
| Location/venue ID + external mapping | confirmed | venue-scoped tokens |
| Reservation list with stable ID | confirmed | `/reservations` with cursor pagination |
| Party size + status fields | confirmed | `size` and `status` enum |
| Status vocabulary | confirmed | `approved`, `seated`, `confirmed`, `canceled`, `arrived`, `completed` |
| Status transition timestamps | **confirmed (richest of the 4 reservation vendors)** | `created-at`, `arrived-at`, `confirmed-at`, `seated-at`, `completed-at`, `canceled-at` |
| Created/updated timestamps | confirmed | both present |
| Webhook signature verification | confirmed | HMAC-SHA256, documented |
| Updated-since polling | confirmed | date filters on list endpoint |

### Validation questions answered at engineering start

- Confirm sandbox / test-environment provisioning approach (separate URL or test account on production).
- Confirm rate limits.
- Confirm webhook retry policy (delivery attempts, backoff).

### Implementation notes for `8R.LB`

- This is the **reference reservation adapter**. Build first; OpenTable / SevenRooms / Tock mirror the shape but with vendor-specific differences.
- Webhook URL: `https://api.forgeflow.app/v1/webhooks/libro/{operator_id}/{location_id}`.
- HMAC verification: per Libro docs, use shared secret to compute SHA-256 over raw payload; compare against `X-Libro-Signature` header (verify exact header name at engineering start).

---

## QuickBooks Time (Scheduling reference adapter — `8.S.QBT`)

| Field | Value |
| --- | --- |
| Vendor | Intuit — QuickBooks Time (formerly TSheets) |
| Product module | QuickBooks Time (time tracking + scheduling); NOT QuickBooks Online Accounting (different product, Phase 8.5 outbound) |
| Official access path | Public OAuth via Intuit Developer Portal |
| Approval status | self-serve via developer.intuit.com — operator action required pre-spawn |
| Primary doc sources | https://tsheetsteam.github.io/api_docs/ |
| Auth mode | OAuth 2.0 Bearer |
| Sandbox status | Intuit Developer sandbox app — self-serve |
| Sandbox parity notes | sandbox provides full schedule_events / timesheets / jobcodes / users data shape; rate limits same as production |
| Location binding model | company-wide OAuth grant; multi-location operators may map QBT `groups` to F&F locations (configurable in admin UI) |
| Backfill model | `/timesheets`, `/schedule_events` with `modified_since` and date filters; cursor pagination |
| Incremental sync model | `modified_since` + `last_modified_timestamps` polling (5-min default cadence); no webhooks |
| Rate-limit model | Per-OAuth-token; values published on developer portal |
| Webhook model | not supported — polling-only |
| PII constraints | employee name/email/phone on user objects; F&F stores employee-internal-ID + role mapping; PII fields not surfaced in operator-app UI at V1 |
| Last verified date | 2026-05-03 |

### Capability checklist (QuickBooks Time)

| Capability | Status | Notes |
|---|---|---|
| Location list + external location ID | partial | `groups` endpoint exists; mapping to F&F `location_id` is operator-configured |
| Employee / worker IDs | confirmed | stable user IDs |
| Role / job hierarchy | confirmed | `/jobcodes` with parent/child relationships; suitable for FOH/BOH name-heuristic mapping |
| Published schedule shifts | confirmed | `/schedule_events` |
| Actual time punches | confirmed | `/timesheets` with start/end + breaks |
| Current clocked-in labor | confirmed | filter timesheets by `on_the_clock=true` |
| Wage rates / labor dollars | confirmed | `pay_rate` on user object |
| Approved-hours / finalization signal | partial | `approved_to` flag on user (date through which timesheets are payroll-approved); per-punch `approved` boolean |
| Punch edit semantics | confirmed | `last_modified` field on timesheet |
| Source punch / shift IDs | confirmed | stable IDs |
| Webhooks | not supported | polling-only — first-class path in framework |

### Validation questions answered at engineering start

- Confirm whether `groups` provides location-level granularity for multi-location operators; otherwise operator picks group-to-location mapping in admin UI.
- Confirm `approved_to` semantics across the operator's payroll period boundaries.
- Confirm rate-limit ceilings to set polling cadence safely.

### Implementation notes for `8.S.QBT`

- This is the **reference scheduling adapter** and the **polling-only reference**. Build first; Agendrix / Humanity / Push Operations / ADP all use polling-only patterns mirrored from this implementation.
- No webhook URL — polling cadence is configurable in the admin UI (default 5 min during operator workdays, 1 hour off-hours).
- Wage source: `wage_source = vendor` when `pay_rate` is non-null; falls back to app-owned wage generator when null.

---

## Cross-references

- `docs/archive/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md` — template these profiles follow.
- `docs/phases/phase_8/vendor_master_list.md` — full 17-vendor classification + wave plan + partnership applications.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 framework + POS adapter family.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — Reservation adapter family.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — Scheduling adapter family.
- `docs/archive/phases/phase_8_gate/vendor_live_data_capability_matrix.md` — original audit matrix.
