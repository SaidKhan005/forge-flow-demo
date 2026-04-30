# Phase 10.5 - Shift Daypart-Aware Service Period View + Primary Driver

Updated: 2026-04-23
Status: Planned, ready to build against real vendor capability profile
Owner: Future live daypart/service-period lane

## Decisions Locked (2026-04-23 review)

- **Framing: additive, not replacement.** Phase 10.5 adds a daypart-aware
  Shift view alongside the existing whole-day Shift view. Whole-day
  remains the default view and the source of truth for whole-day
  comparisons. Daypart view is a second lens over the same live
  canonical facts, using app-owned service-period bucketing.

- **Design against real vendor capability.** Bucketing logic is designed
  against the Toast POS + 7shifts Labor data shapes confirmed by the
  7.55n.12 official-documentation audit. See capability audit
  references in Source Material below. No synthesis; no imagined
  shapes.

- **Build sequence (superseded 2026-04-25):** original framing was
  "parallel with Phase 8, validate post-Phase-8." Updated lock: 10.5
  runs sequentially in the `7.57 -> 11a -> 9.8 -> 9 -> 10a -> 10.5
  -> 9.5 -> [7.58] -> 11b -> 9.75 -> 11b.2 -> 10b -> [7.61] -> 8 -> 8R`
  order. The bucketing engine, read service, and UI can be built
  against demo data once the deferred time-boundary foundation is
  closed; real-data validation happens after Phase 8 transport ships
  (later in the sequence), not as a build blocker.

- **Pre-requisite: close the deferred time-boundary foundation.**
  Persist timing settings (`businessDayStartLocalTime`, `weekStartDay`),
  persist restaurant-scoped service-period definitions, add live
  service-period boundary resolver, fix
  `CurrentWeekState.shiftRecordFromSnapshot` `businessDate` drop,
  retire `WeekDayOrder.daypartsFor(...)` hardcoding, replace the
  read-only Settings timing panel with editable controls.

- **Canonical-fact contract is the bucketing input boundary.** The
  bucketing engine reads canonical facts with restaurant-local
  timestamps. Vendor timezone normalization, idempotency, and
  correction feeds are adapter (Phase 8) concerns, not bucketing
  concerns.

- **Labor-punch split rule.** Punches that span multiple service
  periods are split so that only the minutes falling within an active
  service period count toward that period's labor. Gap-time (staff on
  premises but no service period active, for example prep between
  Lunch end and Dinner start) is classified `non_service` and excluded
  from per-period CPLH denominators. Matches Jim Taylor methodology.

- **Boundary tie-break.** Event at exact `endLocalTime` of a period
  belongs to the ending period (inclusive end). Event at exact
  `startLocalTime` belongs to the starting period. An event at
  15:00:00 with Lunch 11:00 to 15:00 and Dinner 17:00 to 22:00 belongs
  to Lunch.

- **Correction handling.** `time_punch.edited` and
  `time_punch.deleted` from 7shifts and `Order.modifiedDate` advance
  from Toast are idempotent replacements keyed by source ID. On
  correction, the affected period is re-bucketed from the replacement
  fact.

## Goal

Add a live daypart-aware view to the Shift surface. Managers see
metrics for the active service period (Lunch, Dinner, Late Night)
alongside the existing whole-day view, with real time-into-service
behavior and daypart-live primary-driver teaching.

This is an additive capability: whole-day Shift remains the default
and continues to work unchanged. Daypart Shift is a second lens over
the same live data.

## Scope

Phase 10.5 owns:

- `ShiftServicePeriodReadService`, a new read service parallel to the
  existing whole-day `ShiftDashboardNotifier` and
  `ShiftDashboardReadModel`.
- Live bucketing engine:
  - classification function: timestamp + service-period definitions
    returns service-period id or `non_service`
  - accumulator per service period: covers, sales, PPA, FOH hours, BOH
    hours, CPLH, SPLH, blended wage
  - punch split rule (see Decisions Locked)
  - correction replay on source-ID replacements
- Live service-period boundary classifier (the runtime piece; the
  definition resolver shipped in 7.55n.3).
- Real time-into-service display on the Shift header when the daypart
  view is active.
- New Shift UI surface: daypart tab or toggle alongside the existing
  whole-day view.
- Daypart-live primary-driver teaching: surface which driver (covers,
  PPA, FOH hours, BOH hours, wage) is the biggest variance contributor
  during the active service period.

Adjacent work that plugs in:

- Per-daypart OPZ rendering when consumed by daypart-aware Shift and
  Variance surfaces.
- Broader daypart-scope planned and theoretical comparisons outside
  the current Schedule-only planning seam.

## Scope Does Not Own

Phase 10.5 does not own:

- The whole-day Shift contract. Whole-day Shift, whole-day
  `ShiftDashboardReadModel`, and the whole-day `ShiftDashboardNotifier`
  stay untouched.
- POS + Labor connector transport (`Phase 8`). Timezone normalization,
  webhook dedup, and correction-feed replay are adapter concerns.
- Reservation connector transport (`Phase 8R`).
- Auth, roles, permission keys (`Phase 9`).
- Multi-device shared state (`Phase 10`).
- Canonical-fact contract changes. Phase 10.5 reads canonical facts; if
  the contract needs new fields, that is a separate architectural
  change.

## Frontend Exposure

Phase 10.5 is UX-led — the daypart view IS the deliverable. The
existing sub-slice sequence already owns this; this section makes the
surfaces explicit per Hard Promise #10.

**Operator-facing surfaces this phase requires:**

- Daypart toggle / tab on `lib/screens/shift/` — alongside the existing
  whole-day Shift view (additive, never replacing).
- Daypart-scoped Variance lens consuming the same bucketing engine.
- Time-into-service display when the active service period is in
  progress (e.g., "Lunch · 1h 12m in").
- Daypart-live primary-driver teaching surface (renders the per-period
  driver alongside the whole-day driver).
- Settings → Service periods editor (pre-requisite per the
  deferred-foundation lock): editable `startLocalTime` /
  `endLocalTime` per period, week-start day, business-day rollover
  hour. New section in
  `lib/screens/settings/settings_timing_section.dart` (extend existing).

**Admin (11A) surfaces this phase requires:** none. Service-period
defaults at operator/location level are managed via 11A.1 operator
admin if multi-location consistency is needed; otherwise the operator
edits per-location in Settings.

**UX sub-slice family:** owned inline by existing `10.5.x` slices —
no separate `10.5.UX.<n>` family. Each `10.5.x` slice that ships
operator-visible capability adds the `Operator walkthrough` block +
walkthrough acceptance criterion per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

**Demo-mode walkthrough (`kDemoMode = true`):**

- Settings → Timing → set service periods (Lunch 11:00-15:00,
  Dinner 17:00-22:00) → save.
- Open Shift during simulated Lunch → see daypart toggle → switch to
  daypart view → see Lunch metrics + "1h 12m in" → switch to
  whole-day → metrics aggregate across periods.
- Open Variance → daypart toggle → see per-period variance.
- Primary-driver teaching panel renders daypart-aware copy when in
  daypart view.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Runtime Contract

Once Phase 10.5 ships:

```text
canonical operational facts (restaurant-local timestamps)
-> live bucketing engine (Phase 10.5)
-> ShiftServicePeriodReadService (Phase 10.5)
-> Shift daypart tab / view (Phase 10.5)

canonical operational facts (restaurant-local timestamps)
-> whole-day accumulator (existing)
-> ShiftDashboardNotifier (existing)
-> Shift whole-day tab / view (existing, unchanged)
```

Both paths run concurrently. Both read the same canonical facts. Both
respect the same business-date boundary. The daypart path adds
service-period classification; the whole-day path does not.

## Bucketing Engine Design

### Canonical-fact contract (input boundary)

```text
CanonicalFact
- sourceId: string (idempotency key from vendor)
- kind: enum (order_closed, order_modified, order_voided, order_paid,
          punch_in, punch_out, punch_edit, punch_delete)
- businessDate: date (from BusinessDateResolver)
- eventTimestamp: datetime (restaurant-local; adapter-normalized)
- payload: vendor-kind-specific metrics (covers, sales, hours, wages,
           role, department)
- correction: sourceId or null (non-null when this fact replaces a
              prior one)
```

Adapter emits these. Bucketing reads these. Clean boundary.

### Classification function (pure, deterministic)

```text
classify(
  timestamp: datetime (restaurant-local),
  servicePeriods: List<ServicePeriodDefinition>
) -> ServicePeriodId | 'non_service'

Rules:
1. If no period applies to the weekday: non_service
2. If timestamp is in [startLocalTime, endLocalTime] of exactly one
   period: that period
3. Periods must not overlap on the same weekday (enforced at config
   write)
4. Timestamp at exact endLocalTime belongs to the ending period
5. Timestamp at exact startLocalTime belongs to the starting period
```

### Accumulator per service period

```text
ServicePeriodBucket
- servicePeriodId: string
- covers: int (sum of numberOfGuests on order_closed facts)
- sales: decimal (sum of order amount on order_paid facts, less voids)
- checks: int (count of order_closed facts)
- fohHours: decimal (sum of punch minutes in period, FOH role, divided
            by 60)
- bohHours: decimal (sum of punch minutes in period, BOH role, divided
            by 60)
- fohWageDollars: decimal (sum of per-minute wage multiplied by minutes
                  in period, FOH)
- bohWageDollars: decimal (sum of per-minute wage multiplied by minutes
                  in period, BOH)
- CPLH: covers divided by (fohHours + bohHours) [derived]
- SPLH: sales divided by (fohHours + bohHours) [derived]
- PPA: sales divided by covers [derived]
- blendedWage: (fohWageDollars + bohWageDollars) divided by (fohHours +
               bohHours) [derived]
```

### Punch split rule (labor facts)

Input: a punch with `clocked_in` and `clocked_out` (both
restaurant-local datetimes after adapter normalization).

Process:

1. Compute the punch duration in minutes.
2. For each service period active on the punch's business date:
   - intersect [clocked_in, clocked_out] with [startLocalTime,
     endLocalTime]
   - add intersection minutes to that period's FOH or BOH hours
   - add (intersection minutes multiplied by hourly wage divided by
     60) to that period's wage dollars
3. Minutes outside all service periods are classified `non_service`
   and not added to any period's denominator.

Worked example:

- Punch: 14:30 clocked_in, 19:00 clocked_out, FOH role, $20 per hour
- Service periods: Lunch 11:00 to 15:00, Dinner 17:00 to 22:00
- Lunch intersection: 14:30 to 15:00 equals 30 minutes
- Dinner intersection: 17:00 to 19:00 equals 120 minutes
- Non-service: 15:00 to 17:00 equals 120 minutes (excluded from any
  period's CPLH)
- Lunch FOH hours += 0.5; Lunch FOH wage += $10
- Dinner FOH hours += 2.0; Dinner FOH wage += $40

### Correction replay

On `order_modified`, `order_voided`, `punch_edit`, or `punch_delete`:

1. Look up the prior fact by source ID.
2. Subtract the prior fact's contribution from affected period
   buckets.
3. Add the replacement fact's contribution (if not a delete).
4. Result: buckets reflect current truth without reprocessing the full
   business date.

### Boundary edge cases

- Order with `closedDate` at exactly a service-period boundary:
  belongs to the ending period per tie-break rule.
- Punch that starts before any period and ends within a period:
  minutes before the period start are `non_service`; minutes inside
  the period count.
- Punch that spans the entire business day with no overlap to any
  period: entire punch is `non_service`. Edge case; should not happen
  in practice if service periods cover the operating day.
- Break minutes (paid or unpaid) within a punch: follow the vendor
  payload. 7shifts exposes a breaks array with paid flags; subtract
  unpaid break minutes from period totals. Paid breaks remain in the
  totals.

## Dependencies

Required before Phase 10.5 build can start:

- Foundation closure (app-owned, deferred today):
  - Persist `businessDayStartLocalTime` setting
  - Persist `weekStartDay` setting
  - Restaurant-scoped service-period definitions table (model exists
    in 7.55n.3, persistence incomplete)
  - Fix `CurrentWeekState.shiftRecordFromSnapshot` dropping
    `businessDate`
  - Retire `WeekDayOrder.daypartsFor(...)` fixture-era hardcoding
  - Editable Settings UI for timezone and service periods (currently
    read-only; `7.55o.4` flagged this deferred)
- Canonical-fact contract must include:
  - `sourceId` for idempotency on all vendor-origin facts
  - `eventTimestamp` in restaurant-local time (adapter-normalized)
  - `businessDate` from `BusinessDateResolver`
  - `correction` field for replacement semantics

Required for Phase 10.5 validation in production:

- `Phase 8` Toast POS adapter producing real order facts with clean
  timestamps.
- `Phase 8` 7shifts Labor adapter producing real punch facts with UTC
  to restaurant-local conversion.
- `Phase 8R` OpenTable adapter (useful for daypart reservation signal
  but not strictly required for initial 10.5 launch).

Build and validate against demo data works without Phase 8; validation
against real vendor data requires Phase 8 to be stable.

## Non-Negotiables

- App-owned service-period definitions; vendor-native daypart labels
  are optional hints only, never authoritative.
- Timestamp bucketing; no reliance on vendor daypart fields.
- Whole-day Shift behavior is preserved unchanged. Phase 10.5 adds; it
  does not replace.
- Bucketing engine is a pure function over canonical facts. No vendor
  DTOs reach the bucketing layer.
- Labor-punch split rule is the Jim Taylor methodology (minutes-in-period
  only; gap-time is non-service).
- Boundary tie-break is explicit and tested.

## Source Material

This phase is built against real vendor capability data, not synthesis.

Vendor capability audit (official-documentation-backed, 7.55n.12):

- [vendor_live_data_capability_matrix.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_live_data_capability_matrix.md)
- [vendor_capability_profile_pos.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_capability_profile_pos.md)
- [vendor_capability_profile_labor.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8_gate/vendor_capability_profile_labor.md)

Architectural source:

- [phase_7_55_time_boundary_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_time_boundary_contract.md)
- [phase_7_55_architecture_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_architecture_contract.md)
- [phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md)
- [phase_7_55k_8_integration_implications.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55k/phase_7_55k_8_integration_implications.md)

Integration requirements:

- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md)

## Adjacent Phases

- `Phase 8` provides live Toast POS + 7shifts Labor canonical facts;
  validation partner.
- `Phase 8R` provides OpenTable reservation canonical facts; optional
  signal for daypart reservation covers.
- `Phase 9` provides auth and per-operator scoping; daypart view
  enforces the same scoping as whole-day.
- `Phase 9.75` Barrio Staff Daily Companion shows per-staff daypart
  behavior; consumes daypart bucketing results.
- `Phase 11a` knowledge graph ingestion may later use daypart evidence
  for methodology grounding.

## Placeholder Notes

- Primary-driver teaching at daypart scope needs a design pass: which
  driver is surfaced, how it is ranked, how it degrades when thin
  sample (the `DaypartEvidenceVisibilityPolicy` from 7.55k.7 applies).
- Per-daypart OPZ rendering is adjacent but not in this phase's core
  scope; it can slot in once daypart buckets are producing live
  numbers.
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs
  list on the next Codex pass.
