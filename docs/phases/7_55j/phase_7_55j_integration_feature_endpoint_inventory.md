# Phase 7.55j - Integration Feature + Endpoint Inventory

Updated: 2026-04-12
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
  - `docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- It confirmed the preferred architecture for upcoming work:
  - app-owned service-period definitions
  - timestamp bucketing instead of depending on vendor-native dayparts
  - integration-first wage authority with an app-owned fallback generator
- Continue the broader 7.55j feature-to-endpoint inventory after the retired `7.55i` lane (`7.55i.3a` was the last accepted slice).
- 7.55j now includes a formal readiness gate:
  - `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
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
- Forecast demand remains app-owned. POS history is the baseline evidence, and the current architecture refines the weekly forecast with fixed recent-trend logic rather than manager forecast adjustments.
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
| Variance WTD | closed actuals, finalization signal, business date | closed actual hours/labor dollars | optional explanatory context | lever math, locked weekly-plan comparison, explicit row status (7.55k.4) |
| History | closed historical actuals, timestamps for daypart mapping, source IDs, correction feeds | closed historical labor hours by time range, source IDs, correction feeds | optional context | evidence-backed benchmark dayparts (7.55k.5), tier-aware visibility (7.55k.7) |
| Learn | closed historical actuals, timestamps for daypart mapping, source IDs | closed historical labor hours by time range, source IDs | optional context | evidence-backed repeatable wins (7.55k.6), visibility policy (7.55k.7) |
| Data Audit | source ids, payload status | source ids, payload status | source ids, payload status | provenance, alignment proof |

## 7.55k Daypart Evidence Addendum (updated after 7.55k.4â€“7.55k.7a)

Phase 7.55k has now landed concrete evidence-backed evidence for Variance,
History, and Learn. The original generic requirements in this section have been
replaced with the proven downstream integration needs.

Full detail: `docs/archive/phases/7_55k/phase_7_55k_8_integration_implications.md`

### What 7.55k proved

- **Variance Full Week** (`7.55k.4` / `7.55k.4a`): every row carries explicit
  `RowStatus` (closed, open, projected, mixed). Integrations must provide
  close/finalization semantics and business-date-tagged actuals so the app can
  distinguish finalized truth from live context.

- **History Benchmark Dayparts** (`7.55k.5` / `7.55k.5a`): benchmark dayparts
  are evidence-backed closed-truth summaries with sample count, metric proofs,
  and exemplar IDs. Integrations must provide timestamped source facts for
  app-owned service-period mapping, source IDs for exemplar tracing, and
  correction/update feeds after close.

- **Learn Repeatable Wins** (`7.55k.6` / `7.55k.6a`): win evidence requires
  closed covers, sales, and hours at per-shift, per-daypart granularity.
  Integrations that provide only weekly aggregates cannot power this surface.
  Source IDs are required for deduplication and win stability.

- **Interim Visibility Rules** (`7.55k.7` / `7.55k.7a`): the app enforces
  explicit sample-depth thresholds (strong = 3+ closed shifts, repeatable win =
  2+ favorable shifts). Integrations must provide at least a 60-day backfill
  window and incremental daily-close sync for evidence to mature past thin-sample
  tiers.

### Proven closed-truth evidence requirements

These are now **required for evidence-backed History, Learn, and Benchmark
surfaces** (not generic wishes):

| Requirement | Why proven | Source |
|---|---|---|
| Business-date-tagged closed actuals | Evidence bucketed by business date + daypart | POS + Labor |
| Timestamped source facts (opened/closed times) | App maps facts into service periods; without timestamps, daypart depth unavailable | POS + Labor |
| Close/finalization signal per business date | Variance row status depends on distinguishing finalized vs still-open days | POS |
| Source IDs (check/order/shift/punch) | Exemplar tracing, deduplication, correction tracking for evidence stability | POS + Labor |
| Correction/update feeds after close | Benchmark and win evidence must not go stale after refunds, punch edits, late adjustments | POS + Labor |
| FOH/BOH hours by time range | Daypart-level CPLH/SPLH requires hours mapped to service periods, not daily totals | Labor |
| 60-day backfill minimum | Evidence tiers require enough depth to cross strong/repeatable thresholds | POS + Labor |
| Incremental daily-close sync | Without ongoing sync, evidence depth cannot grow past the backfill | POS + Labor |

### Proven live/open context requirements

Required for Variance Full Week open/projected rows (not for evidence):

| Requirement | Why proven | Source |
|---|---|---|
| Intraday covers/sales for the open business day | Open rows show live in-progress context | POS |
| Current clocked-in labor | Open rows show live labor context | Labor |

### Degradation path without timestamps

If a vendor provides only full-day aggregates with no usable timestamps:

- Whole-day Shift, Schedule, and Variance WTD still work
- Daypart evidence (History benchmarks, Learn wins, Full Week daypart detail)
  degrades or stays hidden â€” the app's interim visibility rules handle this
  correctly
- Per-vendor vendor profiles should document whether daypart depth is available

### Decisions still deferred to official API capability profiles

- whether daypart assignment can use an official vendor service-period field or must be entirely timestamp-derived by the app
- how reliable POS covers are by order/check/channel
- whether intraday sales/covers are available enough for live service-period diagnosis
- whether labor scheduled/actual hours can be mapped cleanly to daypart by role and time range
- whether labor dollars/wages are exposed or must be estimated from app-owned wage standards
- whether the vendor exposes pay rates by role, direct labor dollars by shift/punch/day, or both
- whether manager pay and multi-role workers can be mapped cleanly into FOH/BOH wage standards
- how close/finalization and post-close corrections are represented
- whether reservation status timestamps are reliable enough for future explanatory history

### App-side work already landed before live integrations

- `VarianceWeekProjectionReadService` with explicit row status (`7.55k.4`)
- `HistoryBenchmarkDaypartReadService` with evidence-backed summaries (`7.55k.5`)
- `LearnRepeatableWinsReadService` with evidence-backed summaries (`7.55k.6`)
- `DaypartEvidenceVisibilityPolicy` with strong/earlySignal/hidden tiers (`7.55k.7`)
- Tier-aware truncation so strong evidence is prioritized (`7.55k.7a`)
- Intentional empty/partial states for thin-sample surfaces (`7.55k.7a`)

## 7.55j Work Breakdown

### 7.55j.1 - Codebase Feature Inventory â€” COMPLETE

**Output**: `docs/archive/phases/7_55j/phase_7_55j_1_codebase_feature_inventory.md`

Covers 11 product surfaces: Benchmark/Manager Override, Schedule, Shift,
Variance WTD, Variance History, History Pattern Analysis, Learn, Data
Alignment Audit, Settings/App Data Status, Reservation "In the Books", and
Bootstrap/Transport/Replay/Fixture truth path.

Each surface documents: files, current truth consumed, freshness needs, future
source ownership, target architecture destination, current bridge/demo
dependencies, and owning phase for unresolved migrations.

Also includes summary tables: BaselineData bridge reads (~61 reads across 9
files), MeridianConfig bridge reads (~41 reads across 11 files), demo/replay
dependencies (6 components), and architecture destination cross-reference map.

### 7.55j.2 - Required Capability Matrix â€” COMPLETE

**Output**: `docs/archive/phases/7_55j/phase_7_55j_2_required_capability_matrix.md`

Covers all 11 product surfaces from 7.55j.1 with per-surface capability
tables documenting: source system needed, required fields, freshness
requirement (backfill / daily close / near-real-time / live), source
ownership, fallback behavior, and blocked-vs-degrade judgment.

Also includes cross-cutting summaries: freshness priority for Phase 8,
blocked-vs-degrade summary tables, wage authority decision tree, daypart
capability check (7.55k dependency), TargetCycle/WeeklyPlanSnapshot
dependency map, and minimum viable integration capability lists for POS,
Labor, and Reservation.

### 7.55j.gate - Integration Readiness Pressure Test â€” COMPLETE

**Output**: `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`

Gate verdict: **simple-swap integration ready: NO**.

The app is integration-shaped but not integration-finished. The internal
SQLite/repository/notifier/UI data flow is correct, but the runtime
architecture that makes live data behave correctly is not yet in place:
no `TargetCycle`, no `WeeklyPlanSnapshot`, `DemandForecastContext` v1 only,
`BaselineData` bridge still load-bearing (88 refs / 13 files), and
`MeridianConfig` fallback still embedded (58 refs / 12 files).

Blocker grouping: 10 green, 12 yellow, 8 red.
Handoff: all 8 red blockers are owned by `7.55l.0` through `7.55l.8`.
Earlier checkpoint (`phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`)
still holds as seam guidance under the newer cycle/week architecture.

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
