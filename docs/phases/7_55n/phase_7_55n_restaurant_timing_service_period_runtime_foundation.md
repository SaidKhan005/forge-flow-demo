# Phase 7.55n - Restaurant Timing and Service-Period Runtime Foundation

Updated: 2026-04-12
Owner: Codex planning / tracker truth
Status: Queued after `7.55k`

## Purpose

Phase `7.55n` turns the timing and service-period contracts into runtime seams.

`7.55m` separated planning-anchor date from operational current date.
`7.55k` is hardening downstream semantics on top of the existing runtime.
What is still missing is the restaurant-owned timing foundation that those
contracts assume:

- restaurant timing settings
- business-date resolution from restaurant-local rules
- service-period definition resolution
- week-start wiring
- explicit separation between service-period end and shift finalization
- metadata timestamp normalization

This lane exists so those concerns have a real implementation owner before
Phase `10.5`.

## What This Lane Does Not Do

- Does not make Shift daypart-live.
- Does not add live time-into-service behavior.
- Does not redesign manager workflow.
- Does not replace `7.55k` closed-truth evidence work.
- Does not add vendor-native daypart dependence.

Live service-period-aware Shift remains `10.5`.

## Why This Lane Is Needed

The current repo is directionally correct, but still has these gaps:

- `RestaurantLocation.businessTimezone` is persisted, but the rest of
  `RestaurantTimingConfig` is not.
- `WeeklyPlanSnapshotPolicy` supports `weekStartDay`, but runtime services
  still consume the Monday default.
- service-period availability, labels, and ordering are still hardcoded in
  helpers like `WeekDayOrder`.
- Full Week / Schedule / History / Learn still depend on fixture-era
  daypart assumptions.
- service-period end and shift finalization are not modeled as separate
  runtime seams yet.
- metadata timestamps are mixed between local `DateTime.now()` and UTC.

## Current Truth To Build On

- `ShiftRecord.businessDate` is already persisted.
- `OpenShiftSnapshot` already carries `businessDate`.
- `ReservationBookSnapshot` already carries `businessDate + daypart`.
- `WeeklyPlanSnapshotPolicy` already supports a configurable `weekStartDay`.
- the time boundary contract already defines the target architecture.

So `7.55n` is not starting from zero. It is wiring landed facts to the runtime
rules they should already follow.

## Planned Slices

### 7.55n.1 - Restaurant Timing Config Persistence Seam

Persist the minimum restaurant-owned timing settings:

- business timezone
- business-day start
- week-start day
- service-period definitions
- shift-close fallback authority

Acceptance:

- one persisted timing config seam exists
- runtime services can read it without touching UI widgets
- no live Shift behavior changes yet

### 7.55n.2 - BusinessDateResolver

Introduce one app-owned resolver:

```text
restaurant timezone + local timestamp + business-day start
-> businessDate
```

Acceptance:

- adapter ingestion and app bucketing can share one business-date rule
- device-local clock does not become business-boundary truth
- existing planning vs operational date split remains explicit

### 7.55n.3 - ServicePeriodDefinitionResolver

Replace hardcoded daypart definitions with restaurant-scoped service-period
definitions.

Acceptance:

- no new widget-owned daypart ordering rules
- `WeekDayOrder` style helpers can be retired or reduced to a thin bridge
- `morning` is supported at the definition level even if not yet surfaced live

### 7.55n.4 - Week-Start Wiring

Wire week-start settings through:

- `WeeklyPlanSnapshotPolicy`
- current-week snapshot generation
- WTD and Full Week week membership

Acceptance:

- Monday is only a default, not hidden truth
- WTD reset and snapshot week identity follow restaurant settings

### 7.55n.5 - Service-Period Close vs Shift Finalization Contract

Add explicit runtime semantics for:

- service period ended
- shift finalized
- eligible for History / Learn locking

Acceptance:

- service-period end and shift close are separate runtime concepts
- downstream closed-truth surfaces do not infer one from the other silently

### 7.55n.6 - Metadata Timestamp Normalization

Normalize stored metadata timestamps to UTC for:

- `createdAt`
- `updatedAt`
- `generatedAt`
- `lockedAt`

Acceptance:

- audit metadata is coherent
- business date remains separate from UTC metadata

## Relationship To Other Lanes

- `7.55k` continues first:
  - Variance / History / Learn semantics hardening still depends on the
    current runtime shape
- `7.55n` follows:
  - it implements the restaurant timing + service-period foundation the
    contracts already describe
- `10.5` remains reserved for:
  - live service-period-aware Shift
  - live time-into-service
  - daypart-live driver teaching

## Closeout Criteria

`7.55n` can close when:

- restaurant timing settings exist as a persisted seam
- business-date resolution is app-owned and reusable
- service-period definitions are no longer hardcoded across screens/helpers
- week-start wiring is restaurant-driven
- service-period close vs shift finalization is explicit
- metadata timestamps are normalized without replacing business-date truth
