# Phase 7.55j.2 — Required Capability Matrix

Updated: 2026-04-12
Owner: Claude (matrix), Codex (verification)
Status: Complete — capability matrix from 7.55j.1 inventory

## Purpose

This document translates the 7.55j.1 codebase feature inventory into an
explicit integration requirements matrix. For every product surface, each
required operational capability is documented with:

- source system needed
- required fields and capabilities
- freshness requirement
- source ownership
- fallback behavior if missing
- blocked-vs-degrade-gracefully judgment

No code changes, no architecture redefinition. Requirements mapping only.

## Architecture Reference

```text
POS + Labor + Reservation Systems
-> Canonical Operational Facts
-> 60-Day Benchmark Snapshot
-> TargetCycle + DemandForecastContext
-> SchedulePlan
-> WeeklyPlanSnapshot
-> Shift
-> Variance
-> History
-> Learn
```

Active planning rule:
- standards lock on a 60-day `TargetCycle`
- demand rolls from level 1 baseline + fixed 3-week recent trend
- `WeeklyPlanSnapshot` auto-generates and locks the week
- no intended UX change to Benchmark, Schedule, History, or Learn

## Source System Ownership Summary

| Source System | Owns | Does Not Own |
|---|---|---|
| POS | Sales, covers, checks, business date, close/finalization, revenue center | Demand forecast, targets, daypart definitions |
| Labor | Schedules, time punches, actual hours, job roles, wage rates, labor dollars | Target CPLH/SPLH, model hours, OPZ |
| Reservation | Party size, reservation time, status, status timestamps | Cover forecast, demand signal (unless future phase promotes) |
| App | TargetCycle, ActiveTargetProfile, DemandForecastContext, SchedulePlan, WeeklyPlanSnapshot, daypart mapping, OPZ, LaborModel formulas, forecast sales derivation, service-period definitions | Raw POS sales, raw labor hours, raw reservation data |

---

## 1. Benchmark / Manager Override

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed historical sales by business date | net sales, business date, check/order id | Backfill: 60-day rolling window | POS | No closed sales: benchmark cannot calculate PPA or SPLH | **Blocked** — benchmark requires at least one 60-day window of closed sales |
| Closed historical covers by business date | guest count or cover count per check, business date | Backfill: 60-day rolling window | POS | No covers: benchmark cannot calculate CPLH or weekly average covers | **Blocked** — covers are the primary demand evidence |
| Check/order source ids | check id, order id, or ticket id | Backfill | POS | Cannot deduplicate or trace exemplar shifts | **Degrade** — benchmark computes but traceability is lost |
| Daypart or service-period timestamp | opened/closed timestamps, or vendor service period | Backfill | POS (timestamp); App (daypart mapping) | App assigns daypart from timestamps; if no timestamps, daypart-level breakdown unavailable | **Degrade** — whole-day benchmark works; daypart table is empty or estimated |
| Finalization/close-of-day signal | closed-business-date flag or finalization event | Backfill | POS | Cannot distinguish closed vs still-open business dates | **Degrade** — benchmark may include partially open days near the window edge |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Actual worked hours by business date | clock-in, clock-out, paid/unpaid break, adjusted hours, business date | Backfill: 60-day rolling window | Labor | No hours: benchmark cannot calculate CPLH or SPLH | **Blocked** — hours are required for all labor efficiency targets |
| FOH/BOH role classification | job code, role, department, or labor category | Backfill | Labor (role assignment); App (FOH/BOH mapping) | Cannot split FOH vs BOH targets; blended-only benchmark | **Degrade** — blended targets work; FOH/BOH split is unavailable |
| Wage rates or labor dollars | hourly rate per role, or direct labor dollars per shift/day | Backfill | Labor (preferred); App fallback generator | App-owned wage generator provides FOH/BOH wage standards | **Degrade** — app fallback wages are functional but less accurate |
| Manager role tagging | manager flag or manager job code | Backfill | Labor | Cannot exclude or split manager labor from FOH/BOH pools | **Degrade** — manager hours may inflate FOH or BOH totals |
| Source shift/punch ids | shift id, punch id, or timecard id | Backfill | Labor | Cannot deduplicate or trace labor exemplars | **Degrade** — benchmark computes but traceability is lost |

### Required Reservation Capabilities

None required for Benchmark / Manager Override.

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Manager override selection state | Which shifts the manager has selected as "star shifts" | App-owned; no external dependency |
| Derived targets (CPLH/SPLH/PPA/OPZ) | Computed from closed POS + Labor truth | POS covers/sales + Labor hours |
| Active target profile | Runtime projection of current TargetCycle | App-owned after benchmark calibration |
| Wage authority resolution | Integration-first with app fallback generator | Labor wages (preferred); app generator (fallback) |

---

## 2. Schedule

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Historical closed covers for demand baseline | cover count by business date, over 60-day window | Daily close (rolling) | POS | No demand baseline: forecast covers default to zero or static seed | **Blocked** — schedule requires a demand baseline to generate cover forecasts |
| Historical closed sales for demand baseline | net sales by business date, over 60-day window | Daily close (rolling) | POS | Forecast sales derived from covers x PPA; if no sales history, PPA calibration is weaker | **Degrade** — PPA from benchmark still works; sales history improves calibration |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Published schedule shifts (optional comparison) | scheduled hours by business date, role, start/end | Daily close or near-real-time | Labor | No published schedule comparison: schedule shows app-planned hours only | **Degrade** — schedule operates without published-staffing comparison |

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Future reservation book context (optional) | party size, reservation time, business date | Near-real-time | Reservation | No reservation signal in schedule; forecast uses historical demand only | **Degrade** — future product decision required to promote reservations into demand |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Rolling DemandForecastContext | Level 1 baseline + fixed 3-week trend from closed POS history | POS closed covers |
| Forecast sales derivation | Forecast covers x target PPA | DemandForecastContext + ActiveTargetProfile |
| SchedulePlan resolution | Demand + targets + distribution weights | DemandForecastContext + ActiveTargetProfile + weights |
| Distribution weights | Day-level cover/sales/FOH/BOH shares from recent 8 completed weeks | Closed shift history (POS + Labor) |
| WeeklyPlanSnapshot (7.55l.6) | Auto-locked weekly plan at week start | SchedulePlan at lock time |

---

## 3. Shift

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Live/intraday covers to date | cover count for the open business day | Near-real-time or live | POS | Shift dashboard "actual covers" shows zero or stale value | **Blocked** — live covers are the primary shift actual signal |
| Live/intraday sales to date | net sales for the open business day | Near-real-time or live | POS | Shift dashboard "actual sales" shows zero or stale value | **Blocked** — live sales are required for shift actual PPA and dollar gap |
| Business date identification | business date for the current open day | Live | POS | App must derive business date from clock or config | **Degrade** — app can use its own business-date rules |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Scheduled hours for the open day | scheduled shifts by role, start/end, business date | Near-real-time | Labor | Shift dashboard "plan hours" comes from WeeklyPlanSnapshot instead | **Degrade** — plan hours from app model; no vendor-scheduled comparison |
| Actual/current clocked-in labor | current labor hours to date, by role | Near-real-time or live | Labor | Shift dashboard "actual hours" shows zero or last snapshot value | **Blocked** — actual labor hours are required for live CPLH/SPLH |

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Unseated reservation covers | party size, reservation status, business date | Near-real-time | Reservation | "In the books" shows zero; shift dashboard loses reservation signal | **Degrade** — shift plan-vs-actual still works without reservation context |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Plan values for the day | Forecast covers, sales, FOH/BOH hours from locked WeeklyPlanSnapshot day row | WeeklyPlanSnapshot (7.55l.6) |
| OPZ zone status | Computed from live CPLH vs target OPZ bounds | ActiveTargetProfile + live covers/hours |
| Unseated covers aggregation | Sums reservation snapshots by day | Reservation data |
| Shift is whole-business-day | Until Phase 10.5 adds daypart-aware service periods | Architecture decision |

---

## 4. Variance — This Week (WTD)

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed actual covers per shift/day | cover count, business date | Daily close | POS | WTD actual covers column is empty or zero | **Blocked** — variance requires closed actuals to compare against plan |
| Closed actual sales per shift/day | net sales, business date | Daily close | POS | WTD actual PPA and dollar gap cannot be computed | **Blocked** — sales are required for PPA, SPLH, and dollar impact |
| Close/finalization signal | closed-business-date flag or event | Daily close | POS | Cannot confirm whether a day's actuals are final | **Degrade** — variance computes but may include partial-day rows |
| Correction/update feed after close | voided, refunded, edited records | Daily close | POS | Closed actuals may drift after initial close without correction awareness | **Degrade** — initial close is used; late corrections may cause small drift |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed actual FOH/BOH hours per day | actual hours by role/FOH/BOH, business date | Daily close | Labor | WTD actual hours column is empty or zero | **Blocked** — hours are required for CPLH, SPLH, labor % variance |
| Closed actual labor dollars per day | labor dollars or (hours x wage rates) by role | Daily close | Labor | Dollar gap and labor % cannot be computed accurately | **Blocked** — labor dollars are required for dollar impact and labor % |
| Punch edit/correction semantics | edited/adjusted punches, correction events | Daily close | Labor | Actual hours may drift after initial close without correction awareness | **Degrade** — initial close is used; late corrections may cause small drift |

### Required Reservation Capabilities

None required for WTD Variance. Reservation data is optional explanatory context only.

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Locked weekly plan targets for comparison | Target CPLH/SPLH/PPA/wages from WeeklyPlanSnapshot | WeeklyPlanSnapshot (7.55l.6); currently from ActiveTargetProfile |
| Projected rows for unclosed days | From open_shift_snapshots for remaining days in the week | POS/Labor near-real-time (Phase 8); currently from replay |
| Dollar gap / lever / primary driver | Computed by LaborModel formulas | App-owned formulas |
| Full week projection | Extends closed actuals with projected future days | Closed actuals + open shift snapshots |

---

## 5. Variance — History

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed weekly covers | aggregated covers per completed week | Backfill / daily close | POS | No historical variance weeks can be materialized | **Blocked** — cover actuals are required for historical lever determination |
| Closed weekly sales | aggregated sales per completed week | Backfill / daily close | POS | PPA and dollar gap for historical weeks unavailable | **Blocked** — sales are required for PPA, SPLH, and dollar history |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed weekly FOH/BOH hours | aggregated hours per completed week, by role | Backfill / daily close | Labor | No historical labor variance | **Blocked** — hours are required for CPLH and labor % history |
| Closed weekly labor dollars | aggregated labor dollars per completed week | Backfill / daily close | Labor | Dollar gap history unavailable | **Blocked** — labor dollars are required for historical dollar impact |

### Required Reservation Capabilities

None required. Optional explanatory context only.

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Locked targets per week | TargetSnapshot locked at shift close time; weighted average for the week | TargetCycle in force at close time |
| WeekRecord materialization | Aggregated when all 14 shifts (7 days x 2 dayparts) are closed | Closed shift pipeline |
| Lever outcome classification | Computed from actuals vs locked targets using LaborModel | App-owned formulas |
| Cycle and week identity (7.55l.7) | Which TargetCycle and WeeklyPlanSnapshot each week belonged to | TargetCycle + WeeklyPlanSnapshot |

---

## 6. History Pattern Analysis + Benchmark Dayparts

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed shift-level covers/sales | per-shift actuals for lever calculation | Backfill / daily close | POS | No pattern records can be built | **Blocked** — lever outcomes depend on actuals vs targets |
| Daypart-assignable timestamps | opened/closed timestamps for app-owned service-period bucketing | Backfill | POS | Cannot produce daypart-level benchmark evidence; whole-day patterns only | **Degrade** — whole-day patterns work; daypart benchmark depth unavailable |
| Source IDs (check/order) | unique identifiers per closed shift/check | Backfill | POS | Cannot trace exemplar daypart records back to originals; deduplication lost | **Degrade** — evidence computes but traceability and deduplication are lost |
| Close/finalization signal | closed-business-date flag or finalization event | Daily close | POS | Cannot confirm whether a day's actuals are final; open rows may enter evidence | **Degrade** — history may include partially open days near the window edge |
| Correction/update feed after close | voided, refunded, edited records | Daily close | POS | Benchmark evidence may drift from initial close values | **Degrade** — initial close values are used; late corrections may cause small drift |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed shift-level FOH/BOH hours | per-shift actual hours by role | Backfill / daily close | Labor | Lever calculation incomplete (no CPLH/SPLH) | **Blocked** — labor hours are required for efficiency lever outcomes |
| Hours by time range for daypart mapping | actual hours mapped to service periods by clock-in/clock-out time | Backfill | Labor | Cannot produce daypart-level CPLH/SPLH evidence; whole-day labor only | **Degrade** — whole-day patterns work; daypart labor depth unavailable |
| Source IDs (shift/punch) | unique shift or punch identifiers | Backfill | Labor | Cannot trace labor exemplars or deduplicate across syncs | **Degrade** — evidence computes but traceability and deduplication are lost |
| Punch edit/correction semantics | edited/adjusted punches, correction events | Daily close | Labor | Labor evidence may drift after initial close | **Degrade** — initial close values are used |

### Required Reservation Capabilities

None required. Optional explanatory context for History depth.

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Lever pattern records | Per-shift `normalizedLeverId`, `isBenchmark` from LaborModel | Closed POS + Labor actuals vs locked targets |
| Lever card definitions | Lever ids, labels, favorable/unfavorable classification | App-owned domain constants |
| Teaching summaries (most common leak, top dayparts, benchmark dayparts) | Aggregated from pattern records | Closed pattern data |
| Evidence-backed benchmark dayparts (7.55k.5) | `HistoryBenchmarkDaypartReadService` derives sample count, metric proofs, exemplar IDs from closed shifts via `DaypartPatternSummaryBuilder` | Closed POS + Labor with source IDs and timestamps |
| Tier-aware visibility (7.55k.7) | `DaypartEvidenceVisibilityPolicy` classifies evidence as strong (3+ closed shifts), earlySignal, or hidden | App-owned policy; depends on integration providing enough closed-shift depth |

---

## 7. Learn

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed shift history (same as History Pattern) | per-shift covers/sales for pattern building | Backfill / daily close | POS | Learn has no pattern data to summarize | **Blocked** — Learn depends on History pattern records which depend on closed POS data |
| Timestamped source facts for daypart wins | opened/closed timestamps per check/order | Backfill | POS | Repeatable Wins cannot produce daypart-level evidence; whole-day win patterns only | **Degrade** — wins are whole-day only; daypart win depth unavailable |
| Source IDs for win stability | unique identifiers per closed shift/check | Backfill | POS | Win counts may inflate if same shift appears in multiple sync batches | **Degrade** — evidence computes but deduplication is lost |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Closed shift labor hours (same as History Pattern) | per-shift actual FOH/BOH hours | Backfill / daily close | Labor | Learn has no labor efficiency patterns | **Blocked** — Learn depends on History pattern records which depend on closed Labor data |
| Hours by time range for daypart win evidence | actual hours mapped to service periods | Backfill | Labor | CPLH/SPLH metric proofs unavailable for daypart-level wins | **Degrade** — win evidence limited to whole-day patterns |

### Required Reservation Capabilities

None required. Optional context for explaining demand patterns.

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Benchmark context | From persisted cycle/profile/summary authority via `LearnBenchmarkContextService` (retired from BaselineData in 7.55l.8a) | TargetCycle / ActiveTargetProfile / BenchmarkSelectionSummary |
| Recurring leak identification | From History pattern records across multiple weeks | Closed pattern history |
| Evidence-backed Repeatable Wins (7.55k.6) | `LearnRepeatableWinsReadService` derives win summaries with dominant favorable lever, sample depth, metric proofs, and exemplar IDs from closed shifts via `DaypartPatternSummaryBuilder` | Closed POS + Labor with source IDs and timestamps |
| Visibility policy for wins (7.55k.7) | Only buckets with 2+ favorable shifts qualify as repeatable; single favorable shifts are hidden | App-owned policy; depends on integration providing enough closed-shift depth |
| Coaching summaries | Teaching scoped to top-ranked win; supporting lever-card copy alongside evidence | Pattern records + benchmark context |

---

## 8. Data Alignment Audit

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Source ids and payload provenance | check/order ids, import run ids | On-demand | POS | Audit cannot verify POS data lineage | **Degrade** — audit panel still shows app-side values; provenance column is empty |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Source ids and payload provenance | shift/punch ids, import run ids | On-demand | Labor | Audit cannot verify labor data lineage | **Degrade** — audit panel still shows app-side values; provenance column is empty |

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Source ids and payload provenance | reservation ids, import run ids | On-demand | Reservation | Audit cannot verify reservation data lineage | **Degrade** — audit panel still shows app-side values; provenance column is empty |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| All data layer comparison | ActiveTargetProfile, DemandForecastContext, SchedulePlan, ShiftDashboard, WeekData, WageContext, BaselineData, MeridianConfig | All app-owned models |
| Cycle/week provenance (7.55l.7) | TargetCycle id, WeeklyPlanSnapshot id | TargetCycle + WeeklyPlanSnapshot |
| Import run tracking | Already uses real `import_runs` schema | App-owned transport tracking |

---

## 9. Settings / App Data Status

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Connector health / sync status | auth validation, last sync timestamp, error state | On-demand | POS | Settings shows "not connected" or demo status | **Degrade** — settings page works; connector status section is empty |
| Location ids and auth validation | location list, external location id | On setup | POS | Cannot validate POS connection | **Degrade** — app operates on demo/replay path |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Connector health / sync status | auth validation, last sync timestamp, error state | On-demand | Labor | Settings shows "not connected" or demo status | **Degrade** — settings page works; connector status section is empty |
| Wage rate availability check | whether the vendor exposes pay rates, direct labor dollars, or both | On setup | Labor | App fallback wage generator remains active | **Degrade** — wage setup section shows app-configured wages |
| Role availability | available job codes, roles, departments | On setup | Labor | App cannot auto-map FOH/BOH from vendor roles | **Degrade** — manual role mapping or blended-only mode |

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Connector health / API access status | auth validation, access status | On-demand | Reservation | Settings shows "not connected" for reservation | **Degrade** — app works without reservation; "In the books" is zero |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| App data status evaluation | no data / historical only / stale / current / failed import | Import run records |
| Mock replay scenario controls | Demo-only: advance/reset business date | Demo path only; not present in production |
| Wage role setup | Integration-first wage path with app fallback | Labor (preferred); app generator (fallback) |
| TargetCycle status (7.55l) | Current cycle identity, remaining days | TargetCycle model |
| WeeklyPlanSnapshot status (7.55l) | Current week plan state | WeeklyPlanSnapshot model |

---

## 10. Reservation — "In the Books"

### Required POS Capabilities

None required for the reservation signal itself.

### Required Labor Capabilities

None required for the reservation signal itself.

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Reservation party size | party size per reservation | Near-real-time | Reservation | "In the books" shows zero | **Blocked** — party size is the core reservation signal |
| Reservation status and timestamps | booked, confirmed, arrived, seated, completed, cancelled, no-show | Near-real-time | Reservation | Cannot filter to unseated-only; all reservations appear as pending | **Degrade** — unseated filtering is lost; signal is less precise |
| Reservation time and business date | reservation time, business date | Near-real-time | Reservation | Cannot assign reservations to the correct business day or daypart | **Blocked** — date/time assignment is required for shift-day matching |
| Reservation id for idempotency | unique reservation identifier | Near-real-time | Reservation | Cannot deduplicate reservation snapshots | **Degrade** — duplicates may inflate "In the books" count |
| Cancellation/no-show semantics | cancelled/no-show status values | Near-real-time | Reservation | Cancelled reservations may persist in the unseated count | **Degrade** — "In the books" may overcount |
| Webhook, polling, or event stream support | push/pull sync mechanism | Near-real-time | Reservation | Must fall back to periodic polling | **Degrade** — higher latency but functional |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Unseated covers aggregation | Sums party sizes where status is unseated for the business date | Reservation party size + status |
| Shift dashboard integration | Aggregated into ShiftDashboardReadModel.inTheBooksCovers | Reservation book snapshots |
| Schema readiness | `reservation_book_snapshots` table already has sourceSystem, sourceServiceId, lastEventAt | Phase 8R: populate from live vendor |

---

## 11. Bootstrap / Transport / Replay

### Required POS Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Historical backfill (60-day minimum) | closed shifts: covers, sales, hours, business date | Backfill | POS | App cannot bootstrap a 60-day benchmark window | **Blocked** — initial benchmark requires a 60-day backfill |
| Incremental sync after backfill | new closed shifts since last sync | Daily close | POS | Must re-backfill periodically or miss new data | **Degrade** — less efficient but functional with periodic full-window pull |
| Location lookup and external id | location list, location identifier mapping | On setup | POS | Cannot match POS location to app restaurant scope | **Blocked** — location binding is required for data routing |

### Required Labor Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| Historical backfill (60-day minimum) | actual hours, role/department, wages/labor dollars, business date | Backfill | Labor | App cannot bootstrap labor portion of benchmark | **Blocked** — initial benchmark requires labor backfill alongside POS |
| Incremental sync after backfill | new closed punches/shifts since last sync | Daily close | Labor | Must re-backfill periodically | **Degrade** — less efficient but functional |
| Location lookup and external id | location list, location identifier mapping | On setup | Labor | Cannot match labor location to app restaurant scope | **Blocked** — location binding is required |

### Required Reservation Capabilities

| Capability | Required Fields | Freshness | Source Ownership | Fallback If Missing | Blocked or Degrade |
|---|---|---|---|---|---|
| API access and reservation feed | reservation list with party size, time, status | Near-real-time | Reservation | No "In the books" signal; app works without it | **Degrade** — reservation is optional for MVP |
| Location lookup | location identifier | On setup | Reservation | Cannot match reservation venue to app restaurant | **Blocked if reservation is enabled** — required for routing |

### App-Derived / App-Owned

| Capability | Description | Depends On |
|---|---|---|
| Transport replacement rule | Phase 8 replaces MockIntegrationReplaySeed with live vendor adapters | Vendor selection |
| Same internal data flow | Live data flows through the same canonical path: adapter -> canonical facts -> SQLite -> app state -> UI | Architecture alignment (current) |
| Demo lifecycle controls | reseedDemo(), clearAllData(), mock replay scenario date | Demo path only |
| Import run tracking | `import_runs` and `raw_import_records` tables already exist | App-owned schema |

---

## Cross-Cutting: Freshness Requirement Summary

| Freshness Tier | Definition | Surfaces That Need It | Source Systems |
|---|---|---|---|
| **Backfill** | 60-day historical window loaded once at setup, then extended incrementally | Benchmark, Schedule demand baseline, History, Learn, Bootstrap | POS, Labor |
| **Daily close** | Updated when a business day closes and actuals are finalized | Variance WTD, Variance History, Schedule weights, History patterns | POS, Labor |
| **Near-real-time** | Updated within minutes during active service | Shift actuals, Reservation "In the books", Settings sync status | POS, Labor, Reservation |
| **Live** | Continuous or sub-minute updates during service | Shift covers/sales to date, Shift clocked-in labor | POS, Labor |
| **On-demand** | Loaded when the user opens a screen or panel | Data Audit, Settings status check | All |

### Freshness Priority for Phase 8

1. **Backfill** — must be solved first; without it, no benchmark can be built
2. **Daily close** — required for Variance, History, and ongoing demand context
3. **Near-real-time** — required for Shift dashboard live-feeling behavior
4. **Live** — ideal for Shift; acceptable to degrade to near-real-time initially

---

## Cross-Cutting: Blocked vs Degrade Summary

### Blocked Without (feature cannot operate)

| Capability | Surfaces Blocked | Source |
|---|---|---|
| Closed covers (60-day backfill) | Benchmark, Schedule, History, Learn, Bootstrap | POS |
| Closed sales (60-day backfill) | Benchmark, Variance, History, Learn, Bootstrap | POS |
| Actual worked hours (60-day backfill) | Benchmark, Variance, History, Learn, Bootstrap | Labor |
| Labor dollars or wage rates | Variance WTD, Variance History | Labor |
| Live/intraday covers to date | Shift | POS |
| Live/intraday sales to date | Shift | POS |
| Actual/current clocked-in labor | Shift | Labor |
| Location lookup and id mapping | Bootstrap | POS, Labor |
| Reservation party size (if reservation enabled) | Reservation "In the books" | Reservation |
| Reservation time + business date (if reservation enabled) | Reservation "In the books" | Reservation |

### Degrade Gracefully (feature still works with reduced quality)

| Capability | Surfaces That Degrade | Impact | Source |
|---|---|---|---|
| FOH/BOH role classification | Benchmark, Variance, History | Blended-only targets; no FOH/BOH split | Labor |
| Vendor wage rates | Benchmark, Schedule, Variance | App fallback wage generator used instead | Labor |
| Manager role tagging | Benchmark | Manager hours may inflate FOH or BOH | Labor |
| Source ids (check/shift/punch) | All | No traceability or deduplication | POS, Labor |
| Daypart timestamps | Benchmark daypart table, History patterns, Learn coaching | Whole-day only; no daypart depth | POS, Labor |
| Close/finalization signal | Variance WTD, Benchmark | Partial-day rows may appear near window edge | POS |
| Post-close corrections | Variance WTD, History | Small drift from initial close values | POS, Labor |
| Published schedule comparison | Schedule | App-planned hours only; no vendor-scheduled staffing | Labor |
| Future reservation context | Schedule | Forecast uses historical demand only | Reservation |
| Reservation status filtering | Reservation "In the books" | Unseated filtering lost; less precise signal | Reservation |
| Cancellation/no-show semantics | Reservation "In the books" | Unseated count may overcount | Reservation |
| Connector health / sync status | Settings | Shows "not connected" or demo status | All |
| Source provenance for audit | Data Audit | Provenance column is empty; app values still shown | All |
| Incremental sync | Bootstrap | Must re-backfill periodically; less efficient | POS, Labor |

---

## Cross-Cutting: Wage Authority Decision Tree

This is a cross-cutting concern for Benchmark, Schedule, Variance, and Learn.

```text
Does the labor vendor expose pay rates by role?
  YES -> Does it expose enough detail for FOH/BOH wage standards?
    YES -> labor-derived wage standards replace app fallback
    NO  -> app-owned wage generator remains active for FOH/BOH split
  NO  -> Does it expose direct labor dollars per shift/punch/day?
    YES -> derive blended wage from hours + dollars; app fallback for split
    NO  -> app-owned wage generator is the only source; document as gap
```

Wage authority applies to:
- Benchmark: FOH/BOH wage standards for target derivation
- Schedule: labor budget calculation
- Variance WTD: dollar gap and labor %
- Variance History: historical labor cost analysis
- Learn: benchmark context for coaching

The wage decision is vendor-specific and will be resolved per-vendor in
`7.55j.3` (Vendor Endpoint Checklist Template).

---

## Cross-Cutting: Daypart Evidence Capability Check (proven by 7.55k)

Phase 7.55k (`7.55k.4` through `7.55k.7a`) has now landed evidence-backed
daypart depth for Variance, History, and Learn. The requirements below are
proven downstream integration needs, not speculative capability checks.

Full detail: `docs/phases/7_55k/phase_7_55k_8_integration_implications.md`

### Required for closed-truth evidence (History benchmarks, Learn wins)

| Capability | Required From | Purpose | Fallback |
|---|---|---|---|
| Timestamp-based daypart assignment | POS: opened/closed timestamps | App maps sales/covers into service periods via `DaypartPatternSummaryBuilder` | If no timestamps: daypart evidence unavailable; whole-day patterns only. Visibility policy correctly hides or downgrades. |
| Daypart-level labor mapping | Labor: hours by time range and role | App maps labor hours into service periods for CPLH/SPLH metric proofs | If no time-range granularity: daypart labor evidence unavailable; whole-day only |
| Post-close correction feed | POS + Labor | Ensures benchmark and win evidence does not go stale after refunds, punch edits, late adjustments | If no correction feed: accept initial close values; small drift tolerated |
| Source IDs for exemplar tracing | POS + Labor | Dedup and trace exemplar daypart records; required for win stability across sync batches | If no source IDs: evidence computes but traceability and deduplication are lost |
| Close/finalization signal | POS | Variance `RowStatus` depends on distinguishing finalized from still-open days; evidence pipeline must exclude open rows | If no signal: open rows may enter evidence near window edge; small risk |
| 60-day backfill minimum | POS + Labor | Evidence tiers (strong = 3+ shifts, repeatable = 2+ favorable) require enough closed-shift depth | If shallow backfill: most buckets stay in earlySignal or hidden tiers |

### Distinction: closed-truth vs live/open vs projected

`7.55k.4` proved that integrations must not conflate these three categories:

| Category | Integration requirement | Evidence pipeline role |
|---|---|---|
| **Closed truth** | Business-date-tagged finalized actuals with source IDs | Enters History, Learn, and Benchmark evidence pipelines |
| **Open/live context** | Intraday covers/sales/labor for the open business day | Shown as non-final context in Variance Full Week; never enters evidence |
| **Projected/plan context** | App-owned from WeeklyPlanSnapshot | No integration required; app-derived |

### Degradation path without timestamps

If a vendor provides only full-day aggregates with no usable timestamps:

- Whole-day Shift, Schedule, and Variance WTD still work
- History benchmark dayparts, Learn Repeatable Wins, and Variance Full Week
  daypart detail rows cannot produce honest closed-daypart truth
- The app's `DaypartEvidenceVisibilityPolicy` correctly hides or downgrades
  these surfaces to their whole-day fallback
- This is an acceptable degradation path, not a blocker — per-vendor profiles
  should document whether daypart depth is available

### Architecture decisions (unchanged, confirmed by 7.55k)

- app-owned service-period definitions (confirmed by `phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`)
- timestamp bucketing rather than vendor-native dayparts
- daypart assignment is always app-side regardless of vendor
- vendor-native service period field is optional shortcut, not a requirement

---

## Cross-Cutting: TargetCycle and WeeklyPlanSnapshot (landed in 7.55l)

`TargetCycle` and `WeeklyPlanSnapshot` are now implemented (`7.55l` complete).
Multiple surfaces consume them:

| Model | Consuming Surfaces | Status |
|---|---|---|
| `TargetCycle` | Benchmark, Schedule, Variance WTD, Variance History, History, Learn | **Landed** (`7.55l.1`–`7.55l.4`). `ActiveTargetProfile` is now a cycle projection. |
| `WeeklyPlanSnapshot` | Schedule, Shift, Variance WTD, Variance History, History | **Landed** (`7.55l.6`–`7.55l.7`). Consumer migration complete. |

Remaining integration note: live POS/Labor transport (Phase 8) feeds closed
facts into the same canonical path. The cycle/week runtime architecture is
already in place to lock and compare targets and plans correctly.

Remaining bridge note: some non-Learn `BaselineData` and `MeridianConfig`
bridge reads persist in production paths (Schedule fallback, Audit display,
bootstrap priming). These are yellow-tier items documented in the gate
verdict, not cycle/week architecture gaps.

---

## Summary: Minimum Viable Integration Capabilities

### POS — Must Have

1. Location list + location id mapping
2. Closed historical covers by business date (60-day backfill)
3. Closed historical sales by business date (60-day backfill)
4. Check/order ids for idempotency
5. Business date assignment
6. Live/intraday covers and sales to date for the open business day

### POS — Should Have

7. Opened/closed timestamps for app-side daypart assignment
8. Close/finalization signal
9. Post-close correction feed
10. Revenue center, dining option, or service mode

### Labor — Must Have

1. Location list + location id mapping
2. Actual worked hours by business date (60-day backfill)
3. Job code or role assignment (for FOH/BOH mapping)
4. Actual clocked-in labor for the open business day
5. Source shift/punch ids for idempotency

### Labor — Should Have

6. Hourly wage rates or direct labor dollars per shift
7. Manager role tagging
8. Published schedule shifts for comparison
9. Punch edit/correction semantics
10. Hours mapped to time ranges for daypart-level depth

### Reservation — Must Have (if enabled)

1. Location list + location id mapping
2. Reservation party size
3. Reservation time + business date
4. Reservation status (unseated/seated/cancelled/no-show)
5. Reservation id for idempotency

### Reservation — Should Have (if enabled)

6. Status timestamps (booked, confirmed, arrived, seated, completed)
7. Webhook or event stream support
8. Cancellation/no-show semantics
9. Walk-in or waitlist support

---

## UX Guardrail Compliance

All capability requirements in this matrix preserve the active rule:

- No intended manager-facing UX change in Benchmark, Schedule, History, or Learn
- All planned architecture work (TargetCycle, WeeklyPlanSnapshot, bridge retirement) is internal
- No draft/publish state in the UI
- No new manager workflow
- Integration capabilities improve data quality and freshness, not surface behavior
