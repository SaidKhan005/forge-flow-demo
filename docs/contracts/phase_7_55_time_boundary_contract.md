# Phase 7.55 - Time Boundary Contract

Updated: 2026-04-12
Owner: Codex architecture
Status: Active authority

## Why This Exists

The repo now has enough date and timing logic that we need one explicit
contract for all of these questions:

- what timezone is authoritative
- what makes a business day roll over
- what counts as day 1 of the week
- when a 60-day cycle starts and ends
- when a weekly plan locks
- when a service period ends
- when a shift becomes closed historical truth
- what resets WTD, Full Week, History, and Learn

Without this, "time" gets split across widget assumptions, fixture-era
helpers, and vendor-specific habits.

For the broader system architecture that sits above these timing rules, see:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`

## Core Principle

```text
Restaurant-local timing rules own operational boundaries.
Business date is the master anchor.
Week, cycle, service period, and close rules all derive from that anchor.
```

UTC timestamps are still useful for storage and audit metadata, but UTC is
not the business boundary authority.

## Plain-English Definitions

### Restaurant local time

The wall clock in the restaurant's configured timezone.

This is the clock used to decide:

- what local day it is
- whether a service period has started or ended
- whether the business day has rolled over
- whether a configured week boundary has been crossed

### Business date

The restaurant's operating date.

This is not always the same thing as calendar midnight. A restaurant may
consider 1:30 AM to still belong to the prior business date.

Business date is the anchor for:

- closed shift truth
- reservation book facts
- weekly plan snapshot week membership
- 60-day target cycle effective windows
- WTD reset
- History and Learn provenance

### Planning anchor date

The date planning surfaces use when resolving a moving "current" window.

Current repo rule:

1. mock replay business date
2. latest closed business date fallback

Planning anchor is for:

- benchmark windows
- demand forecast context
- schedule plan reads
- weekly snapshot generation

Planning anchor is intentionally separate from live operational now.

### Operational current business date

The business date inferred from live/open shift state.

Current repo rule:

- resolve from open shift snapshots

Operational current business date is for:

- Shift dashboard
- live whole-day current state
- Full Week open/projected context

### Business week

The 7-day operating week defined by the restaurant's configured day 1.

The configured day 1 determines:

- when WTD resets
- what dates belong to the same locked weekly snapshot
- when a new weekly plan snapshot should auto-generate

### Target cycle

The locked 60-business-day standards window.

It owns:

- target CPLH
- target SPLH
- target PPA
- wages
- OPZ bounds

It is keyed by business date, not by device-local calendar drift.

### Weekly plan snapshot

The locked week-in-force comparison plan.

It is generated from:

- the active target cycle
- the rolling demand context
- the current weekly distribution logic

Then it remains locked for that week.

### Service period

The app-owned restaurant-specific operating bucket that replaces
vendor-native "daypart" assumptions.

Examples:

- morning
- lunch
- dinner
- late_night

Service periods are variables:

- how many exist
- what they are called
- what order they appear in
- which weekdays they apply to
- when they start and end
- whether they roll past midnight

### Service-period close

The moment a configured service period ends in restaurant local time.

This is a classification boundary, not a historical lock by itself.

A service period can be over even if the shift has not been finalized by the
source system yet.

### Shift close / finalization

The moment a shift becomes closed historical truth.

This is the lock boundary for:

- WTD closed actuals
- History
- Learn
- benchmark daypart evidence

This is not the same thing as service-period end.

## Restaurant Timing Configuration Contract

This is the minimum timing configuration the app should treat as
restaurant-owned authority.

```text
RestaurantTimingConfig
- businessTimezone
- businessDayStartLocalTime
- weekStartDay
- servicePeriodDefinitions[]
- shiftCloseAuthority
- optional localCloseFallback
```

### Required fields

- `businessTimezone`
  - required
  - already persisted today on `RestaurantLocation`

- `businessDayStartLocalTime`
  - required contract
  - example: `04:00`
  - determines when the business date rolls over

- `weekStartDay`
  - required contract
  - example: Monday or Sunday
  - determines day 1 and WTD reset

- `servicePeriodDefinitions[]`
  - required contract
  - each service period needs:
    - stable id
    - label
    - short label
    - sort order
    - local start
    - local end
    - rollover behavior
    - weekday applicability

- `shiftCloseAuthority`
  - contract enum:
    - vendor_finalization
    - app_local_cutoff_fallback

- `localCloseFallback`
  - optional fallback time rule for app-controlled/demo scenarios only
  - not used when vendor finalization truth exists

## Time Ownership Contract

### Rule 1 - Restaurant timezone is authoritative

All vendor timestamps must be interpreted in the restaurant timezone before
the app decides:

- business date
- service period
- week membership
- daypart/service-period rollover

The device timezone must not be the truth source for business boundaries.

### Rule 2 - Business date is the master operational anchor

All downstream reset and lock logic derives from business date first.

That includes:

- target cycle effective windows
- weekly snapshot week membership
- WTD closed progress
- reservation attribution
- history provenance
- learn evidence grouping

### Rule 3 - Planning anchor and operational current date stay separate

Planning anchor date and operational current business date are both valid,
but they are not interchangeable.

- planning anchor drives planning windows and forecast resolution
- operational current date drives live/open surfaces

Replay mode may move the planning anchor without permission to rewrite
already locked truth.

### Rule 4 - Day 1 of the week is restaurant-configurable

WTD reset and weekly snapshot generation must follow the restaurant's
configured `weekStartDay`.

Until that is wired, Monday is only a default, not a permanent truth.

### Rule 5 - Target cycles are business-date windows

`TargetCycle.effectiveStart` and `effectiveEnd` are inclusive business-date
boundaries.

The current cycle remains active while:

```text
effectiveStart <= businessDate <= effectiveEnd
```

Manager override is allowed once per active cycle. Admin replacement can
replace before expiry.

### Rule 6 - Midweek cycle refresh does not rewrite the locked week

If a 60-day cycle boundary lands during a week:

- the already locked weekly snapshot remains in force
- the new cycle affects the next weekly snapshot
- the current week is not regraded midweek

This rule already exists conceptually and should stay explicit.

### Rule 7 - Weekly snapshot lock happens at business-week start

At the first business date of a new configured week, the app may generate
one locked `WeeklyPlanSnapshot` for that week.

Once generated:

- it becomes the comparison truth for that week
- it does not drift with later forecast changes
- it does not rewrite when a target cycle changes midweek

### Rule 8 - Service-period end and shift close are separate boundaries

Service-period end decides:

- which service period an event belongs to
- when a live service period should stop being treated as active

Shift close decides:

- when facts become closed historical truth
- when WTD can count the shift as final
- when History and Learn may consume it

The app must not treat "service period ended" as "closed historical truth"
unless the source finalization rule says so.

### Rule 9 - Service periods are restaurant-owned variables

The number of service periods, their labels, cutoffs, and weekday
availability are restaurant settings, not hardcoded product constants.

Vendor-native daypart labels are optional input hints. They are not the
authoritative model.

### Rule 10 - Learn teaches only from closed truth with time provenance

Learn must teach from:

- the active benchmark/target cycle for current standards
- closed shifts carrying the cycle/week context that was in force when they
  closed

It must not teach from:

- live partial rows
- projected rows
- service periods that ended but have not closed

### Rule 11 - Storage convention for operator-scoped fact tables

Decided 2026-04-25. Applies to every Postgres fact table carrying
`(operator_id, location_id)` (shifts, cycles, plans, weekly snapshots,
variance, history, etc.):

- Source-truth instants are stored as `TIMESTAMPTZ` (UTC). This is the
  audit / ordering / "when did this happen globally" column.
- A denormalized `business_date` `DATE` column lives alongside the
  `TIMESTAMPTZ`, computed at write time using `location.timezone`
  (IANA string on the `locations` table, per-location, since multi-
  location operators can span zones) plus
  `business_day_rollover_hour` (per-location restaurant setting).
  This is the "which restaurant business day does this fact belong
  to" column.
- `business_date` is **write-once** — never recomputed at read.
  Indexes on `business_date` are the natural shape for "shifts on
  2026-04-25" and cycle-bucketing queries.
- `TIMESTAMP WITHOUT TIME ZONE` is **banned** in operator-scoped fact
  tables. DST transitions corrupt timezone-naive timestamps silently
  and unrecoverably (the 2:30 AM hour on fall-back appears twice with
  no way to distinguish; spring-forward gaps lose data).
- The two columns must stay consistent: writes that set `TIMESTAMPTZ`
  also set `business_date`. The trigger or write-time service that
  enforces this lives in the persistence layer, not in app code.

This rule operationalizes the "Restaurant-local timing rules own
operational boundaries; business date is the master anchor" core
principle. Without it, every developer invents their own timezone
math and DST eventually corrupts cycle / shift truth.

## Reset, Lock, and Rollover Matrix

| Surface / concept | Reset trigger | Lock trigger | Authority |
|---|---|---|---|
| Shift whole-day view | operational business date change | none; live surface | open shift snapshots + restaurant timing |
| WTD closed truth | configured week start day | shift close/finalization | business date + weekStartDay |
| Full Week Projection | new weekly snapshot / live row updates | closed rows lock individually | weekly snapshot + open/projected context |
| Weekly plan snapshot | start of configured business week | snapshot generation | planning anchor + weekStartDay |
| 60-day target cycle | businessDate passes effectiveEnd | cycle creation / replacement | business date |
| History | no reset; append over time | closed shift finalization | closed truth + cycle provenance |
| Learn | no reset; reevaluates from closed truth | closed shift finalization | closed truth + cycle provenance |
| Reservation book context | business date or service-period boundary | none; live context | restaurant timezone + service-period definitions |

## Notification Contract

These are the passive visibility rules the product should eventually
support once timing settings are implemented.

### Target cycle notifications

- notify when a new recommended cycle becomes active at cycle rollover
- notify when the manager override has already been consumed for the active
  cycle
- notify when admin replacement changes the active cycle before expiry

### Weekly plan notifications

- notify when a new weekly snapshot is auto-generated for the new week
- optionally notify when the next week's rolling forecast meaningfully changes
  before that week's snapshot locks

### Settings change notifications

Changing any of these should be treated as an administrative timing change:

- business timezone
- business-day start
- week start day
- service-period definitions
- shift close fallback rule

Those changes must never silently rewrite already locked history.

## Current Repo Reality

### What already exists

- `RestaurantLocation.businessTimezone` exists and is persisted
- `ShiftRecord.businessDate` exists and is persisted
- `OpenShiftSnapshot.businessDate` exists and is persisted
- `ReservationBookSnapshot.businessDate` exists and is persisted
- `BusinessDateAuthorityService` separates planning anchor from operational
  current-shift reads
- `WeeklyPlanSnapshotPolicy` already supports `weekStartDay` as a parameter
- `TargetCycle` and `TargetCyclePolicy` already use inclusive business-date
  windows
- weekly snapshot policy already protects the locked week from midweek cycle
  refresh

### What is still implicit or missing

- no persisted restaurant setting for `businessDayStartLocalTime`
- no persisted restaurant setting for `weekStartDay`
- no restaurant-scoped service-period definitions table
- no explicit shift close/finalization policy object
- no explicit service-period boundary resolver
- `CurrentWeekState.shiftRecordFromSnapshot` still drops `businessDate`
- service periods are still hardcoded through fixture-era helpers
  (`WeekDayOrder.daypartsFor(...)`)
- `SettingsScreen` can now surface timing authority summary rows, but
  editable timezone authority is still deferred until full
  restaurant-local timezone conversion lands end to end
- metadata timestamps are not yet consistently normalized to UTC everywhere

## Current Code Seams This Contract Must Govern

### Business-date seam

- `lib/data/business_date_authority_service.dart`
- `lib/data/shift_service.dart`
- `lib/data/weekly_plan_snapshot_service.dart`

### 60-day cycle seam

- `lib/data/target_cycle_service.dart`
- `lib/domain/services/target_cycle_policy.dart`

### Week boundary seam

- `lib/domain/services/weekly_plan_snapshot_policy.dart`
- `lib/domain/models/weekly_plan_snapshot.dart`

### Service-period seam

- `lib/data/legacy_fixture_data.dart`
- `lib/screens/variance_report.dart`
- `lib/screens/schedule_builder.dart`
- `lib/data/baseline_manager_service.dart`

### Restaurant timing scope seam

- `lib/domain/models/restaurant_location.dart`
- `lib/screens/settings_screen.dart`

## Implementation Gaps Now Queued To 7.55n

### 1. Restaurant timing settings persistence

Add a restaurant-scoped timing settings seam carrying:

- business timezone
- business-day start
- week start day
- service-period definitions
- shift close fallback rule

### 2. BusinessDateResolver

Introduce one app-owned resolver that maps:

```text
restaurant timezone + local timestamp + business-day start
-> businessDate
```

This should be the shared source for adapter ingestion and live bucketing.

### 3. ServicePeriodDefinitionResolver

Replace hardcoded daypart availability, labels, and ordering with
restaurant-scoped definitions.

### 4. Shift close vs service-period close contract

Add explicit app-side semantics for:

- service period ended
- shift finalized
- safe to lock into History / Learn

### 5. Week-start wiring

Wire `WeeklyPlanSnapshotPolicy.weekStartDay` to restaurant settings instead
of using Monday everywhere by default.

### 6. Metadata timestamp normalization

Use UTC consistently for stored metadata such as:

- createdAt
- updatedAt
- generatedAt
- lockedAt

That does not replace business date. It keeps audit metadata coherent.

## Phase Ownership

- `7.55m` established planning-anchor vs operational-date separation
- `7.55l` established target-cycle and weekly-snapshot lock rules
- `7.55k` owns downstream daypart/history/learn semantics that depend on these
  timing boundaries
- `7.55n` owns the restaurant timing + service-period runtime foundation:
  timing settings, business-date resolution, service-period definitions,
  week-start wiring, close-boundary contract, and UTC metadata normalization
- `10.5` adds the daypart-aware Shift view, live service-period-aware
  behavior, and live time-into-service as an additive lens alongside the
  existing whole-day view; whole-day Shift remains the default and is
  preserved

## The One-Sentence Product Rule

```text
Restaurant-local business date is the anchor; weeks, cycles, service periods,
locks, resets, and teaching all derive from that anchor without rewriting
already locked truth.
```
