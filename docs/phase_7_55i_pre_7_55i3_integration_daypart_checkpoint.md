# Pre-7.55i.3 Integration + Daypart Capability Checkpoint

Updated: 2026-04-11
Owner: Codex planning / architecture
Status: Complete planning checkpoint

## Why This Exists

Before `7.55i.3` defines wage-source authority and before `7.55k` hardens daypart semantics, the app needs one clear answer:

```text
What can we safely own in the app,
and what must stay flexible until a vendor is chosen?
```

This checkpoint answers that with two inputs:

1. current repo architecture
2. official vendor docs for likely POS/labor providers

## Short Answer

The simplest sound architecture is:

```text
vendor timestamps + timezone/business-date semantics
-> app-owned service-period rules
-> app buckets facts into morning / lunch / dinner / late_night
```

That means:

- we should not depend on vendors to support "dayparts" natively
- we should prefer timestamp bucketing from POS and labor facts
- we should keep Shift whole-day until Phase 10.5
- closed daypart truth should feed Benchmark, Variance, History, and Learn
- wage authority should be integration-first, with an app-owned fallback generator

## What The Current Repo Already Supports

The repo is already close to the right seams:

- restaurant scope already stores `business_timezone`
- closed truth already stores `businessDate` + `daypart`
- open/current snapshots already store `businessDate` + `daypart`
- reservation snapshots already store `businessDate` + `daypart`
- target standards already store `fohWage` + `bohWage`
- blended wage is already treated as derived presentation, not canonical source truth

Important existing shapes:

- `ShiftFact` = closed daypart fact with business date, daypart, target snapshot, actual labor dollars, and lever truth
- `OpenShiftSnapshot` = current/open/projected daypart snapshot with business date
- `ReservationBookSnapshot` = business date + daypart reservation context
- `ActiveTargetProfile` = current standards, including FOH/BOH wage standards

Main gaps still visible in the repo:

- daypart definitions are still hardcoded in fixture-era helpers such as `WeekDayOrder.daypartsFor(...)`
- the current app assumes `lunch`, `dinner`, and `late_night`, but not configurable `morning`
- there is no restaurant-scoped service-period settings table yet
- there is no restaurant-scoped wage setup / wage generator fallback yet

## Official Vendor Capability Snapshot

This checkpoint used official docs only.

### Toast

What the docs support:

- Orders expose `businessDate`, and Toast documents restaurant business date semantics separately from calendar date:
  - [Restaurant business date](https://doc.toasttab.com/doc/devguide/apiRestaurantBusinessDate.html)
  - [Orders bulk API](https://doc.toasttab.com/openapi/orders/operation/ordersBulkGet/)
- Labor exposes actual worked time through time entries:
  - [Time entries endpoint](https://doc.toasttab.com/openapi/labor/operation/timeEntriesGet/)
- Toast exposes scheduled shifts:
  - [Getting shift assignments for employees](https://doc.toasttab.com/doc/devguide/apiGettingShiftAssignmentsForEmployees.html)
- Labor docs also expose job/wage objects:
  - [JobWageOverride](https://doc.toasttab.com/openapi/labor/tag/Data-definitions/schema/JobWageOverride/)

What that means for us:

- Toast is strong on business-date semantics
- Toast should support timestamp-based daypart bucketing well
- Toast should also support labor-derived wage standards if the integration has the needed labor scopes enabled

### Square

What the docs support:

- Orders can be filtered and sorted by RFC 3339 event timestamps such as `created_at`, `updated_at`, and `closed_at`:
  - [Search Orders](https://developer.squareup.com/docs/orders-api/manage-orders/search-orders)
- Labor `Timecard` data is built around actual worked shifts with `start_at`, `end_at`, job, and wage information:
  - [Labor guide](https://developer.squareup.com/docs/labor-api/build-with-labor)
  - [Timecard object](https://developer.squareup.com/reference/square/objects/Timecard)
- Team member wage data is available:
  - [TeamMemberWage](https://developer.squareup.com/reference/square/objects/TeamMemberWage)
- Scheduled shifts are also available:
  - [ScheduledShiftFilter](https://developer.squareup.com/reference/square/objects/ScheduledShiftFilter)

What that means for us:

- Square is strong on timestamps, labor timecards, scheduled shifts, jobs, and wages
- Square docs in this checkpoint are more timestamp-centric than business-date-centric, so the app should be prepared to own business-date mapping from timezone/workday rules where needed
- Square looks viable for both app-owned daypart bucketing and integration-derived wage authority

### 7shifts

What the docs support:

- 7shifts labor integration is centered on shifts and time punches:
  - [Labor integration overview](https://developers.7shifts.com/docs/labor-integration-overview)
- Roles are first-class:
  - [List Roles](https://developers.7shifts.com/reference/listroles)
- Employee wage data can be role-specific:
  - [Create Employee Data](https://developers.7shifts.com/docs/create-employee-data)

What that means for us:

- 7shifts looks strong as a labor/schedule source
- roles and wages are explicit enough to support FOH/BOH mapping and wage derivation
- 7shifts is not the POS side of the equation, so POS sales/covers/business-date truth still need a separate POS source

### Clover

What the public docs clearly support:

- employee endpoints and employee shift endpoints are available with the right permissions
- order endpoints are available with the right permissions
  - [Clover permissions](https://docs.clover.com/dev/docs/permissions)

What that means for us:

- Clover public docs clearly confirm access to orders and employee shifts
- Clover public docs are less crisp than Toast/Square on wage/rate semantics in the materials reviewed here
- treat Clover as viable for operational data, but confirm wage and post-close correction details during vendor-specific Phase 8 profiling before promoting Clover to first-choice wage authority

## Capability Matrix

| Vendor | POS business date | POS timestamps | Labor actuals | Labor schedule | Wage/rate signal | Role/job signal | Checkpoint confidence |
|---|---|---|---|---|---|---|---|
| Toast | Strong | Strong | Strong | Strong | Medium-strong | Strong | High |
| Square | App may need to own business-date mapping | Strong | Strong | Strong | Strong | Strong | High |
| 7shifts | N/A for POS | N/A for POS | Strong | Strong | Strong | Strong | High as labor-only |
| Clover | We need vendor-profile follow-up | Medium | Medium | Medium | Medium-low in public docs reviewed | Medium | Medium |

## Architecture Decision

### 1. The App Should Own Service Periods

Preferred model:

```text
restaurant-scoped service-period definitions
-> morning / lunch / dinner / late_night
-> labels, ordering, start/end rules, rollover semantics
```

This should live in app settings and persistence, not in vendor DTOs.

Why:

- vendor "daypart" support is inconsistent
- timestamps are more universal than vendor-native service periods
- the app needs one consistent definition across Benchmark, Plan, Variance, History, and Learn

### 2. Shift Can Stay Whole-Day For Now

Keep current product rule:

- Shift remains whole-business-day until Phase 10.5

That is still compatible with daypart architecture.

Reason:

- live whole-day Shift is already stable
- closed daypart truth can still power Benchmark, Variance, History, and Learn
- we do not need to wait for a live daypart Shift UI in order to build the correct closed-truth foundation

### 3. Closed Daypart Truth Should Come From Timestamp Bucketing

Preferred end state:

```text
POS order/check timestamps
+ labor punch/schedule timestamps
+ restaurant timezone/business-date rules
+ app-owned service-period definitions
-> app-bucketed daypart facts
```

This is the right seam for:

- Benchmark / Manager Override candidates
- closed Variance detail
- History benchmark dayparts
- Learn repeatable wins

Important guardrail:

- if an integration only gives full-day aggregates and no usable timestamps, we must not pretend closed daypart truth exists

In that weaker case:

- Shift whole-day still works
- Plan daypart allocation still works as planning math
- but Benchmark / Variance / History / Learn daypart claims must stay limited or clearly labeled as estimated

### 4. Wage Authority Should Be Integration-First

Preferred precedence:

1. labor dollars + hours from the labor system
2. labor rates + hours from the labor system
3. app-owned wage generator / wage setup fallback
4. config fallback
5. unavailable

Rules:

- FOH wage and BOH wage are source-backed standards
- blended wage is always derived
- manager-role handling must be explicit

This is the core architectural recommendation for `7.55i.3`.

### 5. Business Date Must Stay Explicit

Preferred precedence:

1. vendor business date when the source system provides a real business date
2. otherwise app-owned business-date mapping from timezone + configured closeout / service-period rules

This is especially important for:

- late night
- after-midnight service
- DST transitions
- post-close corrections

## What 7.55i.3 Should Build

`7.55i.3` should not build a connector. It should build the app-side seam that connectors will later feed.

Recommended output:

1. `WageStandardContext`
   - restaurant-scoped
   - source-backed
   - explicit provenance

2. `WageStandardSource`
   - labor dollars/hours
   - labor rates/hours
   - app-configured generator
   - config fallback
   - unavailable

3. Settings-based fallback wage setup
   - simple role rows
   - FOH / BOH / manager classification
   - hourly rate
   - weighting input

4. Derived outputs
   - FOH wage standard
   - BOH wage standard
   - reference blended wage

5. Explicit manager-role policy
   - FOH
   - BOH
   - excluded
   - future split rule if needed

## What 7.55k Can Safely Assume

`7.55k` can safely proceed on these assumptions:

- the app should support `morning` in addition to `lunch`, `dinner`, and `late_night`
- service periods should be app-configurable
- closed daypart evidence should be built from timestamps, not vendor-native dayparts
- Shift remains whole-day until Phase 10.5
- History and Learn should stay closed-truth only
- weak daypart evidence should be hidden or soft-labeled

## Open Questions To Defer Until Vendor Selection

These do not block app-side architecture, but they should stay explicit for Phase 8 profiling:

- how reliable POS covers are by channel/order type
- how refunds, voids, and late edits are represented after close
- whether a vendor exposes direct labor dollars, rates only, or hours only
- how salaried managers appear in labor systems
- how multi-role workers should map into FOH/BOH wages
- whether a selected vendor has a usable native workday/business-date concept, or whether the app must compute it

## Practical Recommendation

Build the next phases like this:

1. finish `7.55i.3` with wage authority + fallback generator
2. keep vendor-facing assumptions minimal and timestamp-based
3. later add restaurant-scoped service-period settings with `morning` support
4. let `7.55k` build daypart truth from app bucketing, not vendor-native dayparts

That is the lowest-risk path and the best fit for the codebase as it exists today.

## Current Hierarchy Note

This checkpoint still holds as seam guidance.

It now sits under the newer planning authority in:

- `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
- `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`

In plain terms:

- keep the checkpoint's service-period and timestamp-bucketing guidance
- do not treat this checkpoint as the full runtime architecture by itself
