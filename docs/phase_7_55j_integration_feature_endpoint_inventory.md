# Phase 7.55j - Integration Feature + Endpoint Inventory

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Planned, not implemented

## Purpose

Phase 7.55j is a pre-live-integration audit phase.

The goal is to walk the whole Forge & Flow codebase and product surface, then produce a feature-by-feature map of what official POS, labor, and reservation integrations must provide for the app to use its full power.

This phase does not implement live connectors. It prepares Phase 8 and Phase 8R so the first vendor work is not based on vague assumptions like "the POS probably has covers" or "the labor system probably has scheduled hours."

## Why This Phase Exists

Phases 7.55e through 7.55i make the app-side architecture more coherent:

- 7.55e makes operational seed truth mock-integration-backed.
- 7.55f makes the app date-native with `business_date`.
- 7.55g and 7.55h clean up presentation and wage/precision consistency.
- 7.55i creates canonical demand and shared SchedulePlan authority.

After that, the next risk is integration underuse: connecting to a vendor but only pulling enough data for the first screen, leaving richer features underpowered.

7.55j prevents that by creating a durable requirements map before Phase 8 / Phase 8R implementation.

## Sequencing Note

- The full 7.55j inventory remains broader than the immediate next step.
- The narrow checkpoint pulled forward from this phase is now complete:
  - `docs/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- It confirmed the preferred architecture for upcoming work:
  - app-owned service-period definitions
  - timestamp bucketing instead of depending on vendor-native dayparts
  - integration-first wage authority with an app-owned fallback generator
- Continue the broader 7.55j feature-to-endpoint inventory after the retired `7.55i` lane (`7.55i.3a` was the last accepted slice).
- 7.55j now includes a formal readiness gate:
  - `docs/phase_7_55j_gate_integration_readiness_pressure_test.md`
- After `7.55j.2`, the sequence is:
  - `7.55j.gate`
  - `7.55l.0` through `7.55l.8`
  - `7.55j.3`
  - `7.55j.4`

## Output

7.55j should produce:

1. A repo-wide feature inventory.
2. A feature-to-source map: POS, labor, reservation platform, or app-derived.
3. A required field and endpoint capability matrix.
4. A fallback plan for missing vendor capabilities.
5. A source ownership map for any contested fields.
6. A list of connector-readiness blockers before Phase 8 / Phase 8R.

This inventory should follow the active `TargetCycle + WeeklyPlanSnapshot`
planning rule:

- integrations improve rolling demand inputs and canonical operational facts
- integrations do not change the app rule that standards lock on a 60-day cycle
- integrations should support a locked weekly plan comparison truth where
  possible

## Guardrails

- Official integrations only.
- No scraping.
- No browser automation against vendor portals.
- No shared restaurant credentials stored in the Flutter client.
- No direct mobile calls that expose vendor API secrets.
- Vendor DTOs stop at the adapter layer.
- UI reads app repositories, query services, notifiers, and read models.
- Forecast demand remains app-owned. POS history is the baseline evidence, and later app-side trend or manager adjustments may refine the weekly forecast.
- Vendor forecast fields, if available, should be documented as optional context until the app intentionally adopts them.
- Reservation data remains contextual unless a later phase explicitly promotes reservation signal into the rolling app-owned demand forecast.

## Universal Integration Information Needed

Every official connector profile should answer these questions:

- vendor name and product module
- official access path and approval status
- auth model: OAuth, API key, partner token, service account, webhook signing secret
- sandbox availability
- location lookup and external location identifiers
- timezone and business-day semantics
- service period or daypart semantics, if provided
- historical backfill support and maximum window
- incremental sync support: updated-since cursor, page token, sync token, or webhook event id
- webhook support, event vocabulary, retry behavior, and ordering guarantees
- rate limits and partner restrictions
- delete, correction, refund, void, and edit semantics
- finalization or close-of-business signal
- data latency expectations
- raw payload retention constraints
- PII fields available and fields the app should intentionally discard
- source ids needed for idempotent upsert

## POS Information Needed

The POS connector powers sales, covers, demand history, closed truth, and current shift actuals.

Required capabilities:

- location list and location id mapping
- business date for each sale/check/order
- timestamps for opened, closed, paid, voided, refunded, and updated records
- closed historical sales by business date and daypart
- current/intraday sales to date for the open business day
- guest count or covers per check/order, if reliable
- net sales and gross sales definitions
- taxes, tips, service charges, discounts, comps, voids, refunds, and whether they are included in sales totals
- check/order/ticket ids for idempotency
- revenue center, dining option, service mode, or order channel when available
- employee/server id when available for reconciliation
- finalization signal or closed-business-day report
- update/correction feed after close

Feature use:

- Benchmark baseline: closed covers and sales over the rolling 60-day window.
- Schedule: weekly forecast covers from app-owned demand context, with POS history as the baseline evidence and forecast sales derived by app from covers * target PPA.
- Shift: live covers/sales to date for the current business date.
- Variance: closed actual covers, sales, PPA, and source ids.
- History/Learn: repeated closed patterns by business date, daypart, and lever.

## Labor Information Needed

The labor connector powers scheduled hours, actual hours, wage/labor dollars, and FOH/BOH classification.

Required capabilities:

- location list and location id mapping
- employee ids or worker ids
- job codes, roles, departments, or labor categories
- app mapping from roles to FOH, BOH, manager, or excluded labor
- published schedule shifts by business date, daypart, role, start, end, and scheduled hours
- actual time punches by business date, role, clock-in, clock-out, paid break, unpaid break, and adjusted hours
- current clocked-in labor when available
- hourly wage rates or direct labor dollars
- overtime, premium pay, salaried manager handling, and blended wage rules
- punch edit/correction semantics
- payroll/finalization signal if available
- source shift id / punch id for idempotency
- whether managers are tagged distinctly and how they should map into FOH, BOH, or a split rule
- whether the vendor exposes enough official wage truth to derive FOH/BOH wage standards directly, or whether the app-owned wage generator/setup fallback must remain active

Feature use:

- Baseline targets: actual FOH/BOH hours, labor dollars, and wage context from closed shifts.
- Schedule: planned FOH/BOH hours compared with model-required hours.
- Shift: scheduled hours for the whole current business day and actual/open labor where available.
- Variance: actual hours and labor dollars locked to closed truth.
- History/Learn: recurring over/under hours, CPLH/SPLH, and wage patterns.

Fallback policy to document per vendor:

- if official labor data provides enough hours + dollars or rates + hours, labor-derived wage standards should replace the app fallback
- if official labor data does not provide enough wage truth yet, the restaurant-scoped wage generator/setup remains the temporary source for target-side FOH/BOH wage standards only
- blended wage remains derived from hours and dollars/rates; it is never treated as a manually owned source fact

## Reservation Information Needed

The reservation connector powers the Shift `In the books` signal and future reservation-aware demand context.

Required capabilities:

- location list and location id mapping
- reservation id for idempotency
- business date and reservation time
- party size
- reservation status vocabulary
- status timestamps: booked, confirmed, arrived, waiting, seated, completed, cancelled, no-show
- table, room, area, or service period when available
- created and updated timestamps
- cancellation/no-show semantics
- walk-in or waitlist support if official API exposes it
- webhook, polling, or event stream support
- rate limits and data retention rules
- guest identity fields and whether the app should discard them

Feature use:

- Shift: `In the books` = unseated covers for current restaurant/business date/daypart.
- Schedule future context: optional reservation/walk-in model input only after a future product decision.
- Variance/History: reservation context can explain demand misses, but must not rewrite POS actual covers.

## Feature-To-Integration Matrix

| Feature / Surface | POS Needed | Labor Needed | Reservation Needed | App-Derived / Owned |
|---|---|---|---|---|
| Onboarding + status | location ids, auth validation, backfill status | location ids, role availability | location ids, API access status | restaurant scope, connector configs, sync status |
| 60-day Baseline | closed covers, sales, business date, daypart | actual hours, labor dollars, wage/role data | none required | target profile, OPZ, selected shifts |
| Manager Override | closed shift candidates by business date/daypart | actual labor metrics for selected shifts | none required | selection state, target recalculation |
| Schedule | historical covers/sales for demand baseline | schedule hours if comparing published staffing | optional future book context | rolling demand forecast, forecast sales, SchedulePlan, WeeklyPlanSnapshot |
| Shift | live covers/sales to date, closed dayparts | scheduled hours, actual/current labor | unseated reservation covers | whole-day plan-vs-actual read model |
| Variance WTD | closed actuals and finalization | closed actual hours/labor dollars | optional explanatory context | lever math, locked weekly-plan comparison |
| History | closed historical actuals | closed historical labor | optional context | repeated pattern analysis |
| Learn | closed historical patterns | labor execution patterns | optional context | teaching summaries and benchmark context |
| Data Audit | source ids, payload status | source ids, payload status | source ids, payload status | provenance, alignment proof |

## 7.55k Daypart History Addendum

Phase 7.55k adds a specific downstream requirement: History Benchmark Dayparts and Learn Repeatable Wins should be evidence-backed, not just daypart frequency labels.

This means 7.55j must explicitly verify that the selected official POS/labor integrations can support closed daypart summaries.

Additional capability checks:

- POS data must include enough timestamp or service-period information for the app to map closed sales/covers into the correct business date and daypart.
- POS data must preserve source ids for checks/orders or closed shift summaries so exemplar daypart records can be traced and deduped.
- POS correction/update feeds after close must be understood so benchmark history does not become stale after refunds, edits, or late closeout adjustments.
- Labor data must include scheduled hours, actual hours, role/job mapping, and wage/labor-dollar context at a granularity that can be mapped to daypart.
- Labor correction/update feeds after close must be understood so recurring labor patterns do not drift from final payroll truth.
- Reservation data remains optional explanatory context for History/Learn unless a future product phase promotes reservations into demand forecasting.
- Wage-standard ownership must stay explicit: labor-derived when possible, app-configured fallback only when official labor data cannot yet support it.

Feature implications:

- Variance Full Week Projection needs clear source provenance for closed, open, and projected rows.
- History Benchmark Dayparts need closed daypart counts, averages, lever outcomes, and exemplar source ids.
- Learn Repeatable Wins needs enough closed daypart evidence to explain why a win repeated.
- Shift remains whole-business-day until Phase 10.5; do not use 7.55k as a reason to require live daypart Shift transport immediately.

Decisions to wait on until official API capability profiles are available:

- whether daypart assignment can use an official vendor service-period field or must be entirely timestamp-derived by the app
- how reliable POS covers are by order/check/channel
- whether intraday sales/covers are available enough for live service-period diagnosis
- whether labor scheduled/actual hours can be mapped cleanly to daypart by role and time range
- whether labor dollars/wages are exposed or must be estimated from app-owned wage standards
- whether the vendor exposes pay rates by role, direct labor dollars by shift/punch/day, or both
- whether manager pay and multi-role workers can be mapped cleanly into FOH/BOH wage standards
- how close/finalization and post-close corrections are represented
- whether reservation status timestamps are reliable enough for future explanatory history, not just the Shift `In the books` signal

Implementation that can proceed before live integrations:

- app-owned service-period boundary planning
- daypart summary models derived from existing closed `ShiftRecord`s
- closed-only History/Learn gating
- Variance row-scope labels and reconciliation tests
- soft-labeling or hiding weak daypart claims when sample size is thin

## 7.55j Work Breakdown

### 7.55j.1 - Codebase Feature Inventory

Walk the repo and list every feature/screen/read model that consumes operational truth.

Minimum areas:

- Baseline Manager
- Schedule Builder
- Shift Dashboard
- Variance This Week
- Variance History
- Learn
- Data Alignment Audit
- Settings / data status
- Reservation `In the books`

### 7.55j.2 - Required Capability Matrix

For every feature, list:

- required source system
- required fields
- freshness requirement: backfill, daily close, near-real-time, or live
- source ownership
- fallback behavior if missing
- whether the feature is blocked without the field or can degrade gracefully

### 7.55j.gate - Integration Readiness Pressure Test

Document the explicit answer to:

- are we fully aligned through real SQL simulation?
- are we truly ready for simple-swap live integrations?
- does the earlier checkpoint still hold under the newer
  `TargetCycle + WeeklyPlanSnapshot` model?

Required output:

- green / yellow / red blocker grouping
- honest simple-swap readiness verdict
- unambiguous handoff into `7.55l`

### 7.55j.3 - Vendor Endpoint Checklist Template

Create a reusable checklist that can be filled in once the first POS, labor, and reservation vendors are selected.

The checklist should avoid fake endpoint names before a vendor is chosen. Use capability language first, then fill in official endpoint names later.

### 7.55j.4 - Gap Report

End with a short "integration readiness gap report":

- features fully supported by current canonical models
- features needing schema/model additions
- features needing a backend connector boundary
- features that should remain app-derived
- fields that must be validated against vendor docs before Phase 8 / Phase 8R

Important:

- `7.55j.3` and `7.55j.4` now come after `7.55l`, not before it
- this keeps vendor-specific packaging downstream of the cycle/week runtime
  architecture rather than upstream of it

## Closeout Criteria

7.55j can close when:

- every current feature has an explicit integration requirement row
- every required POS/labor/reservation capability is documented
- fallback behavior exists for missing optional fields
- Phase 8 and Phase 8R can start with vendor-specific profiles instead of rediscovering app requirements
- no feature depends on vendor DTOs reaching UI code
- official-access-only guardrails are repeated in the connector checklist
