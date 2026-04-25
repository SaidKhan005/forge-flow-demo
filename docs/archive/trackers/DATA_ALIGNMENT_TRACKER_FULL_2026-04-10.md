# Data Alignment Tracker

Updated: 2026-04-10
Owner: You
Purpose: Make sure the app is fully aligned for live POS, labor, and later official reservation integrations before Phase 8 / Phase 8R work begins.

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> Rolling 60-Day Baseline Build -> Demand Forecast Context + Active Target Profile -> Schedule Plan -> Shift -> Variance -> Learn

## Desired Separation

This is the architecture the app is moving toward:

Vendor APIs / Fixture Replays
-> Adapter DTOs
-> Canonical source facts
-> Domain services / use cases
-> Repositories
-> SQLite persistence
-> In-memory app state
-> UI

In plain terms:

- API adapters should only pull the relevant POS, labor, and reservation data.
- The app should reshape that data into its own canonical format immediately.
- SQLite should hold at least the restaurant's rolling 60-day operational truth plus current-week and target-profile state.
- Providers and notifiers should expose current app state from repositories and queries, not from vendor payloads or screen constants.
- UI should render that app state without needing to know where the data came from.

## Live Data Clarification

- The current repo is not connected to a live POS, labor, forecast, or reservation vendor yet.
- Current displayed data is still fixture, replay, or demo-backed at the transport layer.
- Internally, that data now flows through the same aligned path that live vendor data should use:
  - canonical source facts
  - SQLite persistence
  - app state and read models
  - UI rendering
- Phase 8 should replace fixture or replay transport with live vendor transport.
- Phase 8 should not replace the internal app-side data flow.
- Phase 7.55b clarified the Schedule formula seam: FOH required hours are cover-driven and BOH required hours are forecast-sales-driven.
- Phase 7.55c.2 clarified the Schedule demand-source seam: forecast covers come from POS 60-day history, and forecast sales is always derived as forecast covers * target PPA.
- Phase 7.55c.2 now adds an app-owned Schedule forecast demand model/resolver so forecast sales and forecast covers carry source provenance before live adapters arrive.
- Phase 7.55d is closed through `7.55d.3c`: Demand Forecast Context comes from the eligible 60-day cover total divided by 60/7, Active Target Profile carries PPA/CPLH/SPLH/wage/OPZ standards, Schedule Plan combines them for Schedule and Shift, and static/demo closed-shift rows are backfilled with stable locked targets so strict Variance getters remain safe.
- Phase 7.55e is complete through `7.55e.6a`: distribution weights are data-driven, SQLite operational seed truth comes from deterministic mock POS/labor replay, app runtime no longer depends on hardcoded `DemoData` operational lists, and every seeded `open_shift_snapshots` row carries mock replay source provenance.
- Phase 7.55f is complete through verified `7.55f.4`: true `business_date` exists on closed ShiftRecords, Manager Override uses a real 60-day business-date window with calendar navigation and candidate actual labor %, lever/date copy is manager-facing, and mock replay reset/advance now reseeds coherent scenario truth across all runtime operational tables.
- Quick user-facing readability follow-up is complete and verified: normal UI copy now shifts `Baseline` user-facing language toward `60 Day Benchmark`, the Baseline navigation label is `Benchmark`, the Schedule navigation label is `Plan`, the Schedule screen header is `Weekly Operating Plan`, and related scanability/copy cleanup landed without renaming internal code/model authorities.
- Phase 7.55i is now active: verified `7.55i.1` added canonical repository-backed Demand Forecast Context, moved Schedule/Shift/Audit runtime demand reads off direct `BaselineData`, and `7.55i.2` is next to centralize shared SchedulePlan consumption.
- Sequencing note: before `7.55i.3` finalizes wage-source authority, run a focused integration/daypart capability checkpoint drawn from `7.55j` and `7.55k` to confirm POS timestamps/business-date/finalization semantics, labor punches/schedules/rates-or-dollars, job/role mapping, manager-role handling, and whether app-owned timestamp bucketing is viable across likely vendors.
- Phase 7.55j is planned as the persistent integration feature/endpoint inventory: every current feature should be mapped to the official POS, labor, and reservation capabilities it needs before Phase 8 / Phase 8R implementation begins, including whether labor integrations expose pay rates, labor dollars, job-code mapping, and enough wage detail to retire the fallback wage generator. A narrow subset should be pulled forward before `7.55i.3`.
- Phase 7.55k is planned for downstream daypart semantics and long-term service-period separation: define the `restaurantId + businessDate + daypart` boundary, add app-owned configurable service periods including `morning`, prefer timestamp bucketing over vendor-native daypart dependence, decide what can be implemented before live integrations, identify what must wait for official API capability profiles, and make Variance Full Week Projection, History Benchmark Dayparts, and Learn Repeatable Wins use closed daypart evidence honestly while Shift remains whole-business-day until Phase 10.5. `7.55k` should inherit that checkpoint rather than hardcoding vendor assumptions.
- Phase 7.56 added an app-side reservation-book signal demo: seeded SQLite reservation snapshots now feed the Shift COVERS card through repository/read-model/UI layers.
- That reservation signal is not live OpenTable or reservation-platform integration. Official reservation transport, status mapping, and capability profiling remain Phase 8R.

## Scope Clarification

- Current rollout target: one restaurant or location at a time.
- Multi-location org management is not part of the current Phase 8 plan.
- Even with one location, canonical records should still carry `restaurantId` or `locationId` so onboarding, imports, and future shared state all have a stable scope boundary.
- Local SQLite is the right local persistence layer for one installed app, fixture replay, offline access, and device-local caching.
- Local SQLite by itself is not enough for future cross-device shared restaurant state.
- If manager overrides, auth, or restaurant settings must appear across multiple devices, the app will eventually need a restaurant-scoped remote source of truth or sync service above device-local SQLite.
- The correct long-term shape is:
  - remote restaurant authority for shared auth, permissions, and shared settings
  - local SQLite on each device as cache, replay store, and operational read model

## Restaurant Onboarding Contract

When a new restaurant or location is onboarded, the app should follow this sequence:

1. Create a restaurant scope record.
   - minimum fields:
     - `restaurantId` or `locationId`
     - display name
     - business timezone
     - operating daypart definitions
     - wage and labor-model config when app-owned
2. Create connector configuration records.
   - POS connector settings
   - labor connector settings
   - external vendor location identifiers mapped to the internal restaurant scope
3. Run connector validation.
   - verify credentials
   - verify vendor location mapping
   - verify the connector can fetch both historical and current data
4. Run an initial backfill import.
   - import at least 60 days of eligible closed-shift history
   - import current-week projected, scheduled, or open-shift state
   - store raw import records and import-run metadata
5. Build canonical app truth.
   - normalize vendor data into canonical source facts
   - persist closed history, open/current state, and target/profile state
   - build the rolling 60-day baseline
   - derive and persist the active target profile
6. Mark onboarding complete.
   - the app can now render the location from repository-backed state
   - imported fixture mode or live mode is visible
   - last successful sync or import time is visible

The app should not be considered fully onboarded until the initial backfill has built a valid baseline and active target profile.

## Connector Planning Artifacts

Before implementing a real vendor adapter, document a capability profile for that connector.

Minimum fields:

- connector name and source type
- auth mode such as API key, OAuth, partner-issued credential, or customer credential
- sandbox availability
- location lookup and external-location mapping fields
- historical backfill support and window limits
- webhook support
- polling endpoints and watermark strategy
- intraday sales availability
- labor actuals availability
- schedule or forecast availability
- explicit close or finalization signal availability
- rate-limit or partner-gating notes
- known missing fields and fallback plan

This should exist even when the vendor access is partnership-only, because the app still needs an explicit contract for what the adapter can and cannot provide.

Reservation connectors need the same written capability profile before Phase 8R begins. Minimum reservation-specific fields include:

- official access path and approval status
- reservation status vocabulary
- seated/completed/cancelled/no-show status mapping
- business-date and service/daypart timestamp semantics
- whether guest-level detail is available and whether the app should intentionally discard it
- polling, webhook, or event-stream support
- rate limits, partner restrictions, and data-retention constraints
- fallback behavior when the reservation platform is unavailable

## Source Ownership Matrix

The app should keep an explicit matrix of which system owns which operational truths.

Recommended starting rule:

- POS owns:
  - business date when POS is the source of sales truth
  - sales
  - checks or tickets
  - voids and comps when exposed
  - covers or guest count when exposed reliably
  - revenue center or order channel when available
- Labor system owns:
  - schedules
  - time punches
  - actual worked hours
  - overtime state
  - job or role assignments
  - labor dollars when exposed
- App derives forecast demand from POS history:
  - forecast covers = 60-day total covers Ã· (60/7) weeks
  - forecast sales = forecast covers Ã— target PPA (always derived, never direct input)
  - no vendor-provided forecast covers or sales
  - no manager editing of forecast on Schedule â€” manager influence is Baseline target profile override only
- Reservation platform owns:
  - reservation party size
  - reservation time
  - reservation status before seating
  - arrival, waiting, seated, cancelled, and no-show state when exposed
  - reservation source/service id
- App owns:
  - daypart mapping rules
  - labor-model formula boundaries
  - FOH required-hours derivation from covers and target CPLH
  - BOH required-hours derivation from forecast or actual sales and target SPLH
  - forecast-sales derivation as forecast covers * target PPA
  - Schedule Plan construction from Demand Forecast Context plus Active Target Profile
  - whole-day Shift plan-vs-actual read model until Phase 10.5 adds service-period live views
  - schedule forecast demand source precedence and provenance
  - reservation-book aggregation by restaurant, business date, and daypart
  - whether a reservation status counts as unseated covers for the Shift signal
  - rolling 60-day baseline
  - active target profile
  - OPZ bounds
  - variance math
  - History and Learn derivations
  - manager override state

When fields overlap:

- define source precedence per field
- log the chosen source in adapter docs
- do not let widgets make that decision ad hoc

## Three Sync Lanes

The app should treat ongoing sync as three separate lanes.

### Lane 1. Live Shift Lane

Purpose:

- keep current service and current-week views fresh

Inputs:

- intraday POS updates
- labor punch or hour updates
- closed-shift POS history updates that refresh the 60-day forecast context

Writes:

- raw import records
- import-run metadata
- `OpenShiftSnapshot`
- `CurrentWeekState`

UI impact:

- Shift
- current-week projections
- schedule/live banners when relevant

### Lane 1R. Reservation Book Signal Lane

Purpose:

- keep the Shift COVERS card aware of known-but-not-yet-seated reservation demand

Inputs:

- official reservation-platform reservation/event data
- app-owned daypart mapping
- reservation status mapping from Phase 8R capability profile

Writes:

- raw reservation import/event records when live transport exists
- `ReservationBookSnapshot`

UI impact:

- Shift COVERS card support line only

Guardrails:

- `ReservationBookSnapshot.unseatedCovers` is context, not actual covers.
- The signal must not mutate current covers, forecast covers, target covers, labor percent, OPZ, or lever math.
- Guest-level detail should not be stored or displayed for this Shift-card signal.
- Phase 7.56 may seed this lane locally for demo proof.
- Phase 8R must use official platform access only; no scraping, no shared restaurant credentials in the Flutter client, and no direct mobile API secrets.

### Lane 2. Finalization Lane

Purpose:

- promote a shift from live/current state into historical truth

Inputs:

- explicit close or finalized signals from vendors when available
- fallback close-policy evaluation when vendors do not expose a clean final event

Writes:

- canonical closed-shift input
- locked historical target truth
- closed shift records
- updated week rollups
- closed-shift history inputs for History and Learn

UI impact:

- Variance
- History
- Learn
- weekly rollups

### Lane 3. Historical/Baseline Lane

Purpose:

- keep the rolling 60-day baseline and active target profile current

Inputs:

- newly finalized eligible closed shifts
- corrected historical shifts inside the rolling window
- records aging into or out of the 60-day window
- manager override changes

Writes:

- baseline builds
- active target profiles
- target-profile metadata and history

UI impact:

- Baseline
- Schedule
- Shift targets
- Variance targets
- Learn benchmarks

## How The App Knows A Shift Is Closed

The app should not assume that "time passed" means "the shift is final."

Use this rule order:

1. Prefer explicit vendor finalization.
   - POS exposes a closed batch, finalized business period, or no-more-checks state
   - labor system exposes finalized punches, approved hours, or closed labor summary
2. If explicit finalization is unavailable, evaluate a close policy.
   - business timezone and daypart definition
   - no recent POS mutations for a quiet window
   - labor punches are closed or stable enough
   - optional reconciliation delay
3. Until the record is trustworthy, keep it out of historical truth.

Suggested lifecycle states:

- `open`
- `pending_finalization`
- `closed_final`
- `reconciled`

Suggested decision rule:

- use vendor signals whenever possible
- use fallback close policy only when vendor signals are missing
- never let uncertain live data directly enter the rolling 60-day baseline

## Connector Finalization Policy

Each vendor adapter should declare how it supports finalization.

Minimum policy fields:

- can the POS expose an explicit closed or finalized signal
- can the labor platform expose approved or finalized hours
- does the adapter have enough data for a same-day close, delayed close, or next-day reconciliation only
- what quiet-window fallback is allowed when explicit signals are missing
- what timezone and business-date rules apply
- whether corrections can arrive after `closed_final`

This policy should drive the adapter and use-case behavior, not live only in prompt notes.

## Implementation Sequences

### Onboarding + Initial 60-Day Pull

```text
create restaurant scope
-> save connector config
-> validate vendor auth and location mapping
-> run initial import_run(type=initial_backfill)
-> persist raw vendor payloads
-> map payloads to canonical source facts
-> write open/current operational state
-> write closed historical operational state
-> build rolling 60-day baseline
-> derive active target profile
-> expose onboarding complete + last successful sync
```

### Steady-State Day-To-Day Sync

```text
poll or receive vendor updates
-> persist raw import records
-> update open/current shift state
-> detect finalized daypart shifts
-> build ClosedShiftInput + locked target truth
-> transactionally upsert closed shift + week rollup
-> rebuild rolling 60-day baseline when eligible history changes
-> refresh active target profile when baseline or manager override changes
-> update provider-backed app state
```

## Phase 7.55d Whole-Day Shift / Schedule Alignment Plan

Status: closed through implementation report `7.55d.3c`; this section remains the architecture contract.

Planning artifact:

- `docs/phase_7_55d_whole_day_shift_schedule_plan.md`

Corrected architecture:

- The 60-day baseline process produces two sibling outputs, not one overloaded object.
- Demand Forecast Context comes from the eligible 60-day closed-shift cover total divided by 60/7.
- Active Target Profile comes from baseline-selected standards: target PPA, target CPLH, target SPLH, wage standards, OPZ, and theoretical labor standards.
- Schedule Plan combines Demand Forecast Context + Active Target Profile.
- Schedule renders from Schedule Plan.
- Shift compares whole-business-day live/current actuals against today's Schedule Plan.
- Daypart closed facts remain the finalization truth for Variance, History, and Learn.
- Live daypart-aware Shift views remain Phase 10.5, not 7.55d.

Formula chain:

```text
60-day total covers / (60 / 7) = weekly forecast covers
weekly forecast covers * target PPA = weekly forecast sales
weekly forecast covers / target CPLH = required FOH hours
weekly forecast sales / target SPLH = required BOH hours
```

Manager Override planning impact:

- Manager Override can change active target standards through the selected baseline shifts.
- Changing target PPA must not change forecast covers.
- Changing target PPA must change forecast sales because forecast sales = forecast covers * target PPA.
- Changing target PPA must affect BOH required hours because BOH required hours = forecast sales / target SPLH.
- FOH required hours should change only when forecast covers or target CPLH changes.
- Closed historical shifts and live actuals must not be rewritten by Manager Override.

Prompt breakdown:

Closed prompt breakdown:

- `7.55d.1`: created the SchedulePlan math contract and made Schedule render from it.
- `7.55d.2`: made Shift consume today's whole-business-day SchedulePlan and whole-day live/current actuals.
- `7.55d.3`: expanded Manager Override impact preview and audit proof for PPA/plan effects.
- `7.55d.3a`: corrected WTD, WeekRecord, and ShiftFact BOH model hours to use actual sales instead of target PPA.
- `7.55d.3b`: corrected closed Variance detail target/model hours to use locked actual-volume getters.
- `7.55d.3c`: backfilled static/demo locked target fields from stable `MeridianConfig` defaults so strict historical getters stay strict and demo Variance expansion no longer throws.

Remaining follow-up:

- Canonical demand and shared SchedulePlan service authority are intentionally moved to Phase 7.55i.

## Phase 7.55e Distribution + Mock Integration Replay

Status: complete through `7.55e.6a`.

Planning artifact:

- `docs/phase_7_55e_distribution_architecture_findings.md`

Verified implementation:

- `7.55e.1`: added immutable `ScheduleDistributionWeights` and pure `DistributionWeightBuilder` from closed `ShiftRecord`s.
- `7.55e.2`: made `SchedulePlanResolver` accept optional distribution weights for weekly-to-day allocation while preserving weekly-level planning math.
- `7.55e.3`: made Schedule daypart subrows consume day x daypart weights with largest-remainder reconciliation and fallback behavior.
- `7.55e.4`: added runtime loading through `ScheduleDistributionWeightsNotifier`, wired into `ForgeFlowScope`, and passed closed-shift-derived weights into Schedule.
- `7.55e.5`: added deterministic mock POS/labor integration replay into SQLite operational seed truth.
- `7.55e.6`: retired production runtime dependence on `DemoData` operational lists; `StaticShiftDataSource` is now mock-replay-backed test/preview compatibility.
- `7.55e.6a`: stamped mock provenance on every seeded `open_shift_snapshots` row, including projected/open/closed snapshot rows.

Live-polish note:

- `ScheduleDistributionWeightsNotifier` currently loads on app startup. Add a refresh hook after new shifts close during the same app session so Schedule distribution weights can update without an app restart. This is not a 7.55e.4 blocker; it belongs to the live integration/post-close refresh path.

Remaining 7.55e follow-up:

- None.

Architecture target:

```text
mock POS/labor integration replay
-> raw/import metadata where useful
-> normalized shift_records / week_records / open_shift_snapshots
-> DistributionWeightBuilder
-> SchedulePlanResolver
-> Schedule day rows and daypart subrows
```

Guardrails:

- This is still mock transport, not a live vendor connector.
- The mock replay should behave like the future official integration path: write canonical operational facts into SQLite, then let repositories/notifiers/screens read from SQLite.
- Do not add live vendor credentials, scraping, or unofficial APIs.
- Do not start true `business_date` persistence here; that belongs to 7.55f unless a later prompt explicitly pulls it forward.
- Do not remove fallback defaults yet. Schedule must remain safe with insufficient history.
- Daypart distribution is planning shape, not live intraday truth. Live service-period views remain Phase 10.5.

## Phase 7.55f Manager Override Calendar + business_date

Status: complete through verified `7.55f.4`.

Planning artifact:

- `docs/phase_7_55f_manager_override_calendar_plan.md`

Verified implementation:

- `7.55f.1`: persisted `business_date` on closed `ShiftRecord`s, added SQLite migration/backfill, stamped mock replay rows, and added true closed-shift date-range queries.
- `7.55f.1a`: hardened V12 backfill so malformed legacy week/day rows remain null instead of fabricating sentinel dates.
- `7.55f.1b`: made business-date helpers require strict `YYYY-W##` week ids and removed lib-side `1970-01-01` fallback behavior.
- `7.55f.2`: made Manager Override candidate loading use the latest closed `businessDate` as the anchor for an inclusive 60-day window, added candidate `businessDate` + historical actual labor %, and added draft-only Clear All behavior.
- `7.55f.3`: replaced the flat candidate list with a 60-day calendar -> day-detail flow anchored to candidate `businessDate`.
- `7.55f.3a`: removed DST-sensitive calendar iteration and added focused regression proof around the DST boundary.
- `7.55f.3b`: added available/suggested/selected calendar states + legend, natural-language copy, human-friendly date text, and a larger Clear All touch target while keeping the candidate pool broad and selection shift-level.
- `7.55f.3c`: fixed lever chips to preserve full canonical lever meaning instead of collapsing distinct levers into generic metric buckets.
- `7.55f.4`: added persistent mock replay business-date state, scenario-aware replay generation, reset/advance controls, scenario-aware Manager Override anchoring, and coherent reseeding across `shift_records`, `week_records`, `open_shift_snapshots`, and `reservation_book_snapshots`.

Guardrails:

- Candidate tile `LABOR %` must remain historical actual labor percentage from the closed shift.
- Preview panel `LABOR %` must remain downstream `SchedulePlan` theoretical labor percentage.
- Suggested-star-day highlighting is advisory only; it must not shrink the candidate pool or change selection persistence semantics.
- Manager Override selection still operates at the shift/daypart level, not as a whole-day boolean.
- Non-blocking note: some test/preview compatibility surfaces still intentionally read `MockIntegrationReplaySeed.output`, so they remain fixed to the default scenario while runtime SQLite-backed surfaces move with the mock replay clock.

## Phase 7.55i Canonical Demand + Shared SchedulePlan Authority

Status: active; `7.55i.1` is verified and `7.55i.2` is next.

Sequencing note:

- `7.55i.2` can proceed now because shared SchedulePlan authority is app-side architecture that helps regardless of vendor.
- Before `7.55i.3`, pull forward a narrow capability checkpoint from `7.55j` / `7.55k` to confirm the seams that wage and daypart architecture depend on:
  - POS business-date, timestamps, timezone, and finalization semantics
  - labor punches, schedules, rates or labor dollars, job/role mapping, and manager-role handling
  - whether app-owned timestamp bucketing is viable so the app does not depend on vendor-native dayparts
- Use that checkpoint to shape `7.55i.3` wage-source authority and later `7.55k` daypart separation instead of hardcoding assumptions early.

Planning artifact:

- `docs/phase_7_55i_canonical_demand_schedule_plan_authority.md`

Reason this exists:

- Phase 7.55e covers distribution weights.
- Phase 7.55f covers true business-date windows.
- Phase 7.55g covers Schedule/Baseline presentation.
- Phase 7.55h covers blended wage and decimal consistency.
- None of those fully retire the remaining `BaselineData` compatibility bridge or guarantee that Schedule, Shift, Manager Override preview, and Data Alignment Audit all consume one resolved plan authority.

Required architecture:

```text
closed ShiftRecords
-> rolling 60-day Baseline Context
-> Demand Forecast Context + ActiveTargetProfile + distribution weights
-> shared SchedulePlan authority
-> Schedule + Shift + Audit
```

7.55i must keep these boundaries:

- ActiveTargetProfile owns standards only: PPA, CPLH, SPLH, wage standards, OPZ, theoretical standards.
- Demand Forecast Context owns forecast covers and demand provenance.
- SchedulePlan combines demand + standards + distribution.
- Reservation `In the books` remains contextual and never mutates forecast covers.
- Target PPA can affect forecast sales and BOH plan hours, but must not rewrite actual sales, covers, or actual PPA.

Implementation scope:

- Verified in `7.55i.1` / `7.55i.1a`:
  - added a repository-backed `DemandForecastContext` model/service/notifier
  - anchored demand to mock replay current business date with latest-closed-date fallback
  - replaced production-facing direct `BaselineData.historicalWeeklyAvgCovers` demand reads in Schedule, Shift, and Data Alignment Audit
  - made Schedule react to demand-context changes after provider creation
  - removed the Data Alignment Audit's indirect old-demand bridge through `ShiftService`
- Remaining:
  - add a shared SchedulePlan read service so Schedule, Shift, Data Alignment Audit, and Manager Override preview consume one resolved plan authority
- Add repository-backed wage-standard authority so ActiveTargetProfile wages come from one read path instead of screen-local defaults.
- Make that wage-standard path integration-first: prefer labor-derived wage truth when available, but support a restaurant-scoped wage generator/setup fallback until official labor adapters can fully supply wage context.
- Decide whether WTD Variance compares against current active targets or closed-shift locked targets, then test and label that behavior.
- Move Learn benchmark/target context away from mutable `BaselineData` and onto persisted active target/baseline summary state.
- End with a grep/audit note for any remaining `BaselineData` imports and why each remaining use is allowed.

Acceptance proof:

- The same restaurant/date/profile inputs produce the same SchedulePlan values in Schedule, Shift, Audit, and Manager Override preview.
- Forecast covers remain fixed when Manager Override changes target PPA.
- Forecast sales and BOH plan hours change when Manager Override changes target PPA.
- FOH plan hours change only when forecast covers or target CPLH changes.
- Closed ShiftRecord truth and actual-sales BOH model hours are not rewritten by target PPA.
- Learn pattern analysis remains closed-history-driven and benchmark context is repository-backed.
- Wage standards come from one repository-backed authority, not mixed screen-local calculations.
- When labor wage truth is unavailable, the app falls back to the persisted wage generator/setup path without creating a second UI-facing architecture seam.

## Phase 7.55j Integration Feature + Endpoint Inventory

Status: planned, not implemented.

Front-loaded checkpoint before `7.55i.3`:

- A narrow subset of 7.55j should be pulled forward before wage-source authority work finalizes.
- That checkpoint should confirm:
  - POS business-date and timestamp semantics
  - close/finalization and correction semantics
  - labor punches vs scheduled shifts availability
  - wage truth shape: pay rates, labor dollars, or both
  - job/role mapping and manager-role handling
  - whether app-owned timestamp bucketing is viable without vendor-native dayparts
- The full 7.55j inventory still remains broader than this checkpoint and should continue afterward.

Persistent planning artifact:

- `docs/archive/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md`

Reason this exists:

- The app should not enter Phase 8 / Phase 8R with vague assumptions about what the POS, labor, or reservation systems expose.
- The integration work should fully power Baseline, Schedule, Shift, Variance, History, Learn, and Data Alignment Audit instead of pulling only the first fields needed by one screen.
- Endpoint names are vendor-specific and should be filled in after vendor selection, but the app's required capabilities can be listed now.

Required 7.55j audit output:

- feature inventory across Baseline, Schedule, Shift, Variance, History, Learn, Settings/status, Data Alignment Audit, and Reservation `In the books`
- required POS fields and endpoint capabilities
- required labor fields and endpoint capabilities
- required reservation fields and endpoint capabilities
- freshness requirements: historical backfill, daily close, intraday, or live
- source ownership and fallback behavior
- connector-readiness gaps before Phase 8 / Phase 8R

Core integration requirements:

- POS must provide official access to location mapping, business date, closed sales/covers, live/intraday sales when available, source ids, close/finalization or correction semantics, and historical backfill.
- Labor must provide official access to schedules, time punches, roles/job codes, FOH/BOH mapping inputs, wages or labor dollars, actual hours, scheduled hours, and correction/finalization semantics.
- Labor inventory must explicitly answer whether FOH/BOH wage standards can be derived from official rate/dollar data or whether the app-owned wage generator/setup fallback remains necessary per restaurant.
- Reservation platform must provide official access to reservation id, business date/time, party size, status vocabulary, status timestamps, and enough status mapping to calculate unseated covers.

Guardrail:

- Vendor forecast fields may be documented if available, but current Schedule demand policy remains app-derived: forecast covers from POS history and forecast sales from covers * target PPA.

## Phase 7.55k Daypart Separation, Variance, History, and Learn

Status: planned, not implemented.

Dependency note:

- 7.55k should inherit the focused pre-`7.55i.3` integration/daypart checkpoint instead of assuming vendors will expose native dayparts.
- The preferred architecture remains app-owned service periods plus timestamp bucketing, but that should be confirmed against likely POS/labor capabilities before 7.55k starts hardening downstream read models.

Planning artifact:

- `docs/archive/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md`

Reason this exists:

- Baseline and Schedule are now meaningfully daypart-aware.
- Shift is still intentionally whole-business-day until Phase 10.5.
- Variance Full Week already renders day/daypart rows but mixes closed, open, and projected states.
- History and Learn currently summarize daypart labels from lightweight pattern records, not rich daypart benchmark evidence.
- Full daypart separation needs a long-term service-period boundary before the app starts adapting to vendor-specific API quirks.

Required architecture:

```text
closed daypart ShiftRecords
-> daypart pattern summaries
-> History benchmark dayparts
-> Learn repeatable wins
```

7.55k must keep these boundaries:

- Closed daypart facts are eligible for History and Learn.
- Open/projected rows are not eligible for benchmark or repeatable-win history.
- Full Week Projection can show closed/open/projected daypart rows, but every row must keep its scope explicit.
- Shift remains whole-business-day in this phase.
- Live service-period Shift views remain Phase 10.5.
- The long-term service-period key is `restaurantId + businessDate + daypart`; `weekId` and `dayLabel` are grouping/display fields.
- Vendor-specific DTOs and endpoint semantics must stay in adapters, not leak into UI/read models.

Implementation scope:

- Audit daypart scope across Variance, History, and Learn.
- Document the long-term full daypart separation plan and read-service boundaries.
- Identify which decisions must wait for official POS/labor/reservation API capability profiles.
- Define which weak daypart claims should be hidden or soft-labeled until enough closed evidence exists.
- Add or plan a richer closed-shift daypart summary model with counts, averages, lever frequency, and exemplar source ids.
- Tighten Variance Full Week row labels and reconciliation tests.
- Upgrade History Benchmark Dayparts from simple frequency labels to evidence-backed daypart summaries.
- Upgrade Learn Repeatable Wins so the card explains why a win repeats, not just where it repeated.
- Feed new endpoint/field requirements back into 7.55j.

Acceptance proof:

- Day row totals reconcile to expanded daypart rows in Variance Full Week.
- Closed rows use locked target truth and actual-volume model hours.
- Open/projected rows remain clearly non-final.
- History benchmark dayparts are closed-history-only.
- Learn Repeatable Wins excludes open/projected rows and carries enough evidence to justify the coaching.
- Tracker notes continue to state that Shift is whole-day until Phase 10.5.

## Phase 7.55b Schedule Demand-Source Status

Phase 7.55b is complete on the app-side Schedule path.

Current implementation:

- `LaborModel` remains the single formula source.
- `LaborModel.modelBohHoursFromSales(forecastSales, targetSPLH)` is now the primary BOH required-hours formula.
- `LaborModel.modelBohHours(covers, ppa, targetSPLH)` remains as a compatibility helper for surfaces that only have covers and PPA.
- `ScheduleForecastNotifier.forecastedSales` currently derives forecast sales as weekly forecast covers * target PPA.
- Schedule day and daypart row view models now carry `forecastSales`.
- Schedule BOH required hours calculate from forecast sales.
- The Schedule table now presents `DAY | COVERS | SALES | FOH HRS | BOH HRS`.
- The Schedule table includes short copy: `FOH plans from covers. BOH plans from forecast sales.`

Architectural guardrail:

- FOH Schedule demand is cover-driven.
- BOH Schedule demand is forecast-sales-driven.
- Forecast covers come from POS 60-day history.
- Forecast sales is app-derived as forecast covers * target PPA, not vendor-provided.
- Reservation-book signals may inform known future demand context, but they must not cause BOH required hours to be modeled as cover-driven.

Verification recorded on 2026-04-09:

- `flutter analyze` passed.
- `flutter test test/labor_model_boh_sales_test.dart test/target_consistency_opz_test.dart` passed.
- Full `flutter test` passed with 533 tests.
- `git diff --check` reported no whitespace errors; only expected CRLF warnings.

## Phase 7.55c Schedule Forecast Demand-Source Status

Phase 7.55c.2 is complete on the app-side Schedule path.

Planning and implementation artifact:

- `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`

Current implementation:

Architecture: covers always from POS 60-day history; sales always derived as covers Ã— target PPA.

- `ForecastDemandSource` enum: `appDerivedFromHistoricalAverage` (primary), `appDerivedFromCoversAndPpa` (sales derivation), `appDerivedFromReservationAndWalkInModel` (Phase 8R future), `demoFallback`, `unavailable`.
- `ScheduleForecastDemand` carries resolved weekly forecast sales, forecast covers, and source provenance.
- `ScheduleForecastDemandResolver` waterfall: POS 60-day historical avg â†’ demo fallback â†’ unavailable.
- Schedule is read-only â€” no manager editing. Manager influence is Baseline target profile override only.
- Schedule displays `Forecast source: 60-day weekly average` as provenance.
- `LaborModel` remains the formula source: FOH hours = forecast covers Ã· target CPLH; BOH hours = forecast sales Ã· target SPLH.

Forecast derivation chain:

```text
POS closed shifts (60 days) â†’ total covers â†’ Ã· (60/7) â†’ weekly avg covers
weekly avg covers Ã— target PPA â†’ forecasted sales
forecasted covers Ã· target CPLH â†’ FOH hours
forecasted sales Ã· target SPLH â†’ BOH hours
```

Guardrails:

- Covers always from POS history, never vendor-provided or manager-entered.
- Sales always derived from covers Ã— PPA, never a direct input.
- Do not let reservation `in the books` become forecast covers.
- Do not let BOH required hours become cover-driven.
- Do not let widgets decide forecast source precedence.
- Do not leave demo `1200` as an unexplained production default.

Remaining future integration work:

- No live POS, labor, OpenTable, or reservation transport exists yet.
- Phase 8 replaces the transport (fixture â†’ live POS) but not the derivation logic.
- The app derives forecast from its own historical data â€” vendors provide raw shift data, not forecasts.

Verification recorded on 2026-04-10:

- `flutter analyze` passed.
- `flutter test test/schedule_forecast_demand_resolver_test.dart test/labor_model_boh_sales_test.dart test/target_consistency_opz_test.dart` passed with 63 tests.
- Full `flutter test` passed with 541 tests.
- `git diff --check` reported no whitespace errors; only expected CRLF warnings.

## Phase 7.56 Reservation Signal Status

Phase 7.56 is complete on the app-side demo path.

Current implementation:

- `ReservationBookSnapshot` is the app-owned aggregate for one restaurant, business date, and daypart.
- SQLite schema v11 adds `reservation_book_snapshots`.
- The demo seed writes Friday dinner with `72` unseated covers and `18` unseated parties.
- Shift dashboard notifier/service read the snapshot through the SQLite repository.
- `ShiftDashboardReadModel.inTheBooksCovers` carries the optional display value.
- The COVERS card renders `In the books 72` under the existing forecast line only when a snapshot exists.

Non-claims:

- No live OpenTable or reservation-platform API has been implemented.
- No guest-level reservation details are displayed.
- No reservation data changes operational math.
- Phase 8R remains responsible for official vendor transport, capability profile, status mapping, and sync policy.

Verification recorded on 2026-04-09:

- `flutter analyze` passed.
- Focused reservation repository, notifier, and widget tests passed.
- OPZ contract test passed after stale 7.55 expectation cleanup.
- Full `flutter test` passed with 525 tests.

Commit hygiene:

- The current dirty worktree mixes Phase 7.55 stabilization, Phase 7.56 reservation signal work, tracker/docs updates, and one stale OPZ test-contract cleanup.
- Prefer separate commits by phase and purpose before review.
- If committed together, the commit message should explicitly name the mixed scope.

## Why This Exists

The app should already behave correctly before real vendor data is connected.

Phase 8 should only add adapters and transport. It should not introduce new target math, new tab behavior, or a new data model.

This tracker defines:

- what must be true after Phases 1-7
- how to audit the app state after Phase 7
- how to replace remaining demo-shaped flows without live vendor access
- how to simulate future live data cleanly using fixture imports
- what persistence boundaries should exist before live integrations arrive
- what evidence should exist before Phase 8 starts

## Core Principle

Do not mock the UI.

Do not keep expanding screen-level demo constants.

Mock the feeds instead.

That means:

- create realistic POS and labor fixture payloads
- run them through the same canonical ingest path the live adapters will use
- persist the imported results into the same local storage the app reads in production
- make tabs read persisted or derived state, not hand-authored widget constants

## Critical Clarifications From Repo Audit

These are not optional nice-to-haves. They are required to actually reach the target architecture before Phase 8.

### 1. Historical Target Truth Must Be Persisted

- Closed shifts must persist either:
  - a full locked target snapshot, or
  - a durable target-profile reference plus enough data to reconstruct the exact historical target state
- Historical week and shift views must not read today's active targets for old records.
- Manager overrides applied later must not distort prior closed-shift analysis.

### 2. Restaurant Scope Must Exist In Canonical Data

- Canonical models and persistence must include restaurant or location scope before live adapters arrive.
- Minimum scope fields should include:
  - restaurantId or locationId
  - source timezone when needed for business-date truth
  - vendor/source identifiers where relevant
- Phase 8 should not be the first time the app learns what restaurant a record belongs to.

### 3. Raw Import Tracking Must Be First-Class

- The app needs a raw import layer for replay, debugging, reconciliation, and adapter verification.
- Minimum concepts should include:
  - import run id
  - source type
  - received-at timestamp
  - payload fingerprint or dedupe key
  - import status
  - optional cursor or watermark metadata
- Without this, transport concerns will leak into the product layer later.

### 3A. Vendor Capability Contracts Must Exist

- Phase 8 should not begin with vague assumptions like "the vendor probably has covers" or "the labor tool probably has approved hours."
- Each targeted vendor should have a written capability profile and source-ownership map before implementation starts.
- This is especially important for partnership-gated vendors where public docs are incomplete.

### 4. Open and Current State Must Be Modeled Separately From Closed History

- Closed-shift ingest is only one lane of truth.
- The app also needs explicit current-state models for:
  - projected shifts
  - open shift snapshots
  - current-week state
- Shift and Schedule should eventually read these models, not static widget constants.

### 5. Repository Boundaries Must Be Explicit

- Repositories are the app-facing data boundary.
- SQLite implementations sit below repository interfaces.
- Providers and notifiers should read repositories or query services, not raw tables and not vendor DTOs.

## Pre-Phase-7.5 Debugging Rule

Until Phase 7.5 removes screen-owned demo truth, do not use the entire UI as the proof that target propagation works.

Use this rule:

1. trust tests first
2. trust screens already reading target-driven or shared state second
3. treat mixed demo-backed screens as non-authoritative

Current practical trust order in this repo:

- manager override persistence and preview behavior
- Baseline
- Schedule
- WTD surfaces driven by shared week state

Current mixed surfaces that should not be the only proof of propagation:

- Shift surfaces still reading `ShiftSnapshot` or `ShiftMetrics`
- Zone/OPZ hero surfaces still mixing static shift data with baseline-derived targets
- Variance Full Week surfaces still reading direct demo shift lists
- historical surfaces that still compare past records against current active globals

This rule exists to prevent false negatives while Phases 5 and 6 are still being completed.

## What Must Be True After Phases 1-7

### 1. One App-Wide Pipeline Exists

- Raw operational facts can enter the app in canonical form without touching widget code.
- Closed shift facts can produce normalized shift records and update week rollups.
- Historical closed shifts can produce the rolling 60-day baseline.
- The baseline can produce targets, OPZ, daypart averages, and target covers.
- One active target profile can feed Schedule, Shift, Variance, and Learn.

### 1A. One Separation Of Concerns Exists

- Vendor DTOs stop at the adapter layer.
- Canonical source facts are distinct from read models and widget models.
- SQLite persistence is divided into raw imports, canonical operational records, and target/profile state.
- In-memory state projects persisted truth rather than inventing app truth.
- UI reads providers, notifiers, and queries rather than vendor payloads or screen constants.
- The live shift lane, finalization lane, and baseline lane are separate responsibilities.

### 2. One Active Target Profile Exists

- The system baseline is the default target source.
- A manager override can replace the system baseline as the active target profile.
- The active target profile is visible and understandable in the UI.
- The active target profile is a first-class app concept, not only an implicit static global.
- The app can clearly say whether it is using:
  - system baseline
  - manager override

### 3. Open vs Closed Time Boundaries Are Clean

- Open and future surfaces read the current active target profile.
- Closed shifts lock the targets that were active at close time.
- Locked targets are persisted well enough to keep historical truth stable.
- Historical views use locked target snapshots for truthful analysis.
- A later override must not rewrite historical truth.

### 4. Tabs Are Functionally Aligned

- Baseline is the source-of-truth tab for targets and ranges.
- Schedule uses forecast covers for FOH demand, forecast sales for BOH demand, and the active target profile for target CPLH, target SPLH, target PPA, and wage targets.
- Forecast covers come from POS 60-day history.
- Forecast sales is always derived as forecast covers * target PPA, and downstream BOH math treats that derived forecast sales as the input.
- Schedule should retain demand-source provenance for forecast covers and forecast sales.
- Shift uses live or imported operational facts plus the active target profile.
- Variance uses closed-shift and week-rollup facts, with locked targets where appropriate.
- History and Learn teach repeating patterns from tracked facts, not from hand-authored summaries.

### 5. Demo Logic No Longer Defines App Truth

- Demo fixtures may still exist for seeding and replay.
- Demo fixtures must enter through import or repository paths, not screen constants.
- No production tab should require direct imports of demo-only screen-state constants.

### 6. Sync and Empty-State Behavior Is Defined

- The app can distinguish:
  - no data
  - partial data
  - stale data
  - sync failed
  - imported fixture mode
- These states are visible and not silently hidden behind neutral displays.
- Import status has a real model and persistence story, not just UI copy.

### 7. Verification Exists

- Deterministic tests prove that the same inputs produce the same targets, OPZ, levers, and projections.
- Fixture replay scenarios prove that the UI behavior is stable without live vendors.

## Best Approach Before Phase 8

Use fixture-first integration simulation.

The cleanest approach is:

1. Treat "demo data" as recorded vendor exports, not as app-display constants.
2. Import those exports through canonical ingest paths.
3. Persist the imported results into SQLite.
4. Make the UI read only from repositories, providers, and derived services built on top of persisted state.
5. Use local replay scenarios to simulate live sync, intraday updates, and close-shift events.

This keeps the architecture honest and makes Phase 8 a connector job instead of a product-logic rewrite.

## What To Read After Phase 7

Run a full app-state audit after Phase 7 and classify every visible surface and major model into one of these buckets:

- Source fact
- Canonical normalized fact
- Derived baseline or target state
- Locked historical snapshot
- Fixture-only compatibility data
- Legacy demo-only UI state

The audit is complete only when each visible number in the app has a known home.

## Post-Phase-7 Audit Checklist

### A. Trace Every Tab

For each visible tab and major subview, record:

- what data objects it reads
- whether those objects are source facts, derived targets, or locked historical snapshots
- whether they are persisted or in-memory only
- whether they come from canonical services or demo-only constants

Required tabs and surfaces:

- Shift
- Variance -> This Week
- Variance -> Full Week
- Variance -> History
- Learn
- Schedule
- Baseline
- Manager Override flow
- Settings and any data-reset actions

### B. Trace Every Number

For each major number shown in the UI, document:

- source of record
- derivation rule
- persistence location
- whether it should update live, at close time, or only from the rolling baseline

Examples:

- covers
- forecast covers
- PPA
- CPLH
- SPLH
- labor percent
- dollar gap
- OPZ floor and ceiling
- baseline target CPLH, SPLH, PPA
- target daypart covers
- weekly and historical lever labels

### C. Identify Any Remaining Direct Demo Reads

Flag every production surface that still reads directly from:

- `DemoData`
- `ShiftSnapshot`
- `ShiftMetrics`
- `WeekToDate`
- `WeeklyVariance`
- any similar screen-only constant source

The goal is not "delete all fixtures."

The goal is "fixtures flow through canonical app paths."

### D. Confirm Boundary Rules

Confirm these are all true:

- source facts are never treated as derived metrics
- derived metrics are never persisted as if they were source facts unless intentionally materialized
- historical closed shifts do not recompute against newer override state
- future and in-flight views do use the current active profile
- daypart remains the atomic truth unit

## Known Areas To Recheck In This App

These are current examples that should be revisited when the post-Phase-7 audit is run:

- `lib/screens/shift_dashboard.dart`
  - header currently reads static `ShiftSnapshot`
  - metric cards currently read `ShiftMetrics.cards`
- `lib/widgets/zone_status_card.dart`
  - currently combines static shift snapshot values with baseline-derived targets
- `lib/widgets/variance_banner.dart`
  - already reads shared WTD state through `WeekDataNotifier`
- `lib/screens/variance_report.dart`
  - WTD section reads `WeekDataNotifier`
  - Full Week section currently reads `DemoData.currentWeekShifts`
- `lib/screens/settings_screen.dart`
  - current reset actions still revolve around demo reseeding
- `lib/data/fixture_seed_data.dart` (formerly `demo_data.dart`)
  - should remain available as fixture material or seed content, but not as direct screen truth
- `lib/models/week_data.dart`
  - still derives targets from current global target state
- `lib/models/week_record.dart`
  - still derives target-hour math from current global target state
- `lib/domain/services/target_snapshot_builder.dart`
  - currently builds locked targets from current globals, which is acceptable as a bridge, but the persisted historical representation still needs to be expanded
- `lib/data/database_helper.dart`
  - does not yet have raw import tables, import status storage, or restaurant-scoped persistence

These examples are not the final audit result for post-Phase-7 state.

They are today's known hotspots and should be explicitly rechecked.

## Mock-Live Strategy

### Fixture Types To Create

Before Phase 8, maintain realistic fixture bundles for:

- rolling 60-day historical closed shifts
- current-week scheduled or projected shifts
- intraday open-shift updates
- close-shift finalization events
- manager override selections

### Fixture Shapes

Each fixture should mimic a future adapter payload, not a widget model.

Use shapes that map naturally into:

- POS source facts
- labor-system source facts
- canonical closed-shift input
- projected shift or scheduled shift input

### Fixture Modes To Support

- cold start with only historical data
- cold start with historical data plus a partial current week
- intraday updates arriving during service
- a shift closing and replacing projected state
- manager override applied
- manager override cleared
- stale feed or missing feed
- partial vendor coverage

## Persistence Plan Before Live Integrations

Use local persistence as the stand-in backend until a real remote backend is required.

That local persistence should support three layers.

### 1. Raw Import Layer

Persist imported raw payloads or normalized raw import rows for:

- replay
- debugging
- vendor adapter verification
- reconciliation

This layer should answer:

- what did the source send
- when did we receive it
- what import run did it belong to
- was it accepted, rejected, retried, deduped, or partially applied
- what cursor, watermark, or sync window did it belong to

Recommended minimum fields:

- importRunId
- restaurantId or locationId
- sourceType
- sourceEntityType
- sourceEntityId
- payloadHash or dedupe key
- receivedAt
- importStatus
- errorSummary when needed
- cursor or watermark metadata when needed

Suggested table families:

- `restaurant_locations`
- `connector_configs`
- `import_runs`
- `raw_import_records`
- `sync_watermarks`

### 2. Canonical Operational Layer

Persist the normalized app records the UI actually uses.

Minimum concepts:

- shift records by week, day, and daypart
- projected or scheduled open-shift records
- completed week rollups
- history pattern inputs derived from tracked facts
- restaurant or location scope on every operational record
- locked target reference or locked target snapshot for closed historical truth

This layer should answer:

- what operational truth does the app believe right now

Suggested table families:

- `open_shift_snapshots`
- `shift_records`
- `week_rollups`
- `history_pattern_inputs`

### 3. User-Controlled Target State

Persist user- and app-controlled target state separately from source facts.

Minimum concepts:

- active target profile
- manager override selections
- baseline build metadata
- sync or import metadata
- target profile history or versioning needed for historical reconstruction

This layer should answer:

- why is the app using these targets right now

Suggested table families:

- `baseline_builds`
- `active_target_profiles`
- `target_profile_versions`
- `baseline_selected_records`

## How To Get There From Phase 7 State

### Workstream 1 - Remove Screen-Owned Truth

Goal:

- no tab should require demo-only constants for its core logic

Actions:

- replace direct screen reads of demo constants with repository or provider reads
- make fixture imports populate the same records those repositories expose
- keep fixture seed utilities, but move them behind import or seeding boundaries

Until this workstream is complete, debugging conclusions should explicitly distinguish:

- logic verified
- trusted-surface propagation verified
- mixed-surface mismatch still expected

### Workstream 2 - Make Imports First-Class

Goal:

- app behavior can be exercised end to end with imported fixture bundles

Actions:

- create import formats that resemble future vendor outputs
- add an import or replay harness that writes into local persistence
- support both one-time seed imports and repeat incremental imports
- add idempotency, dedupe, and import-run tracking
- add import-status visibility for stale, partial, and failed states

### Workstream 3 - Separate Open/Future vs Closed/Historical

Goal:

- app uses active targets for open and future state
- app uses locked targets for closed and historical state

Actions:

- verify close-shift ingest locks targets at close time
- persist locked historical target truth explicitly
- verify open or projected states remain tied to the active profile
- verify history and variance do not drift when overrides change later
- add explicit current-state models instead of relying on screen constants

### Workstream 4 - Make Baseline Rebuild Behavior Explicit

Goal:

- everyone can explain when the rolling 60-day baseline rebuilds and what records are eligible

Actions:

- define rebuild triggers
- define eligible and ineligible records
- define how manager override is layered on top of system baseline
- define what the app stores when the baseline changes

Minimum rebuild triggers:

- initial 60-day backfill completed
- eligible closed shift inserted inside the rolling window
- eligible closed shift corrected or replaced inside the rolling window
- a closed shift ages out of the rolling window

Active target profile refresh triggers:

- a new baseline build becomes current
- manager override applied
- manager override cleared

### Workstream 5 - Add State Visibility

Goal:

- the app tells the truth about data freshness and source mode

Actions:

- surface imported fixture mode clearly
- surface last import or sync time
- surface stale, failed, or partial feed states
- surface whether active targets are system-derived or manager-overridden
- surface when the app is reading replayed fixture data vs live adapter data

### Workstream 6 - Build Confidence Through Replay

Goal:

- before live vendors exist, the app can survive realistic operational scenarios

Actions:

- create repeatable replay scenarios
- use them in manual QA
- use them in automated tests where feasible

## Verification Scenarios

The app should pass these before Phase 8 begins.

### Baseline Scenarios

- import 60 days of closed shifts and build the system baseline
- verify derived target CPLH, SPLH, PPA, OPZ, and daypart target covers
- verify baseline changes when eligible tracked history changes

### Override Scenarios

- apply a manager override
- verify Baseline, Schedule, and Shift reflect the override immediately
- verify historical week detail does not rewrite past closed-shift truth
- clear the override and verify the app falls back to the system baseline

### Current-Week Scenarios

- import a partial current week
- verify WTD uses real tracked facts
- verify projected rest-of-week behavior uses active targets
- close a shift and verify the projected slot is replaced atomically

### Shift Scenarios

- replay intraday updates for a live shift
- verify Shift tab and any live banner or OPZ card update from imported operational facts
- verify model-needed hours and variance use the active profile
- verify live intraday records do not directly enter the 60-day baseline until finalized

### History and Learn Scenarios

- verify history summary is built from tracked closed shifts
- verify repeated leak and benchmark patterns survive imports and rebuilds

### Failure Scenarios

- no historical data
- no current-week data
- partial vendor data
- stale imports
- duplicate events
- out-of-order close updates
- restaurant-scoped data isolation remains correct
- close-policy fallback does not finalize a shift too early

## Tab Read Contracts

These are the implementation-level read boundaries the app should converge on.

- Baseline
  - reads `BaselineBuild` and `ActiveTargetProfile`
- Schedule
  - reads POS-history forecast covers, app-derived forecast sales, and `ActiveTargetProfile`
  - derives forecast sales as forecast covers * target PPA
  - never derives forecast covers from sales
  - should retain forecast source/provenance instead of treating demand as anonymous screen state
- Shift
  - reads `OpenShiftSnapshot` plus `ActiveTargetProfile`
- Variance -> This Week
  - reads `CurrentWeekState` or equivalent week query
- Variance -> Full Week
  - reads repository-backed current-week shift list, mixing open/projected and closed states where intended
- Variance -> History
  - reads closed week rollups and locked historical targets
- Learn
  - reads tracked historical pattern inputs derived from closed shifts
- Settings / Sync
  - reads import status, replay mode, last successful sync, and reset/import actions

## Phase 7.51 Closeout Scope

The post-`7.5` repo audit found that the structural alignment work landed, but the Phase 8 gate is not honest enough to call fully passed yet. `Phase 7.51` is the narrow closeout pass between `7.5` and `8`.

### 7.51a. Historical Truth Closeout

- `variance_report.dart` closed-shift rows must stop comparing against current `BaselineData`.
- Closed shifts shown inside Full Week must read the locked target fields already persisted on `ShiftRecord`.
- Manager override must continue to update open and future state immediately without rewriting already-closed shift detail.
- Replay and deterministic tests should prove this explicitly before the gate is signed off.

### 7.51b. Active-Target Bridge Containment

- Persisted `ActiveTargetProfile` plus notifier or provider state should become the app-wide active-target authority.
- `BaselineData.revision` should stop acting as the shell-level rebuild authority.
- Baseline, Schedule, and Learn should stop treating direct `BaselineData` reads as the long-term runtime source of truth.
- If any `BaselineData` bridge remains temporarily, the exact allowed read sites should be documented and treated as compatibility-only.
- The source-of-truth map should be updated for every visible number that still depends on the bridge.

### 7.51c. Vendor Readiness Artifacts + Gate Evidence

- Check in written capability profiles for the first Phase 8 vendors.
- Check in the POS/labor/app source-ownership matrix.
- Capture replay scenarios for no data, partial data, stale data, failed import, and fixture mode.
- Run deterministic tests and replay proof in a Flutter-capable environment.
- Do not mark Phase 8 active until this evidence exists in the repo and the gate answers are all yes.

## Post-7.51 Verification Findings

- `docs/internal/barrio/` is the canonical home for private Barrio source docs, including the business plan, company handbook, and interview playbook; `assets/internal/barrio/` remains the home for supporting visual source material such as branding, logos, color inspiration, and reference imagery/style inspiration.
- later `7.52e`/`7.52f`/`7.52g`/`7.52h`/`7.52i` implementation must translate those private sources into native Barrio UI/content/learning experiences rather than document viewers, including the intended staff play-style learning and gamified motivation patterns such as leaderboard-style progress.
- `docs/internal/barrio/barrio_visual_teaching_system_execution_blueprint.md` is now the authoritative Barrio visual/teaching blueprint for future native fulfillment, covering the living bubble system, subtle atmospheric leaves, card-based microlearning, decision-first teaching loop, and controlled gamification.
- future Barrio UX implementation should enforce the blueprint's decision-speed rule: every visual element must help staff decide faster.
- during `7.52e`/`7.52f`/`7.52g`/`7.52h`/`7.52i`, Forge & Flow should be treated as frozen: no edits to its public screens, navigation, styling, copy, behavior, data flow, or operational UX while Barrio work is underway.

The verification pass after 7.51a-e found:

- 7.51a complete: closed-shift Full Week detail reads locked target truth.
- 7.51b complete: app-shell authority off BaselineData.revision; remaining bridge frozen.
- 7.51c complete: gate artifacts checked in; vendor profiles remain TBD.
- 7.51d complete: projected/open Variance uses active target profile; Shift empty-state renders truthfully; connector config persistence boundary exists; Clear All Data actually clears; Schedule visible surface uses injected targets; variance banner uses WeekData theoretical labor %.
- repo-wide code and architecture audit says the app is structurally ready for Phase 8 transport work.
- the tracked test corpus is now 28 test files.
- the checked-in rerun artifacts are:
  - docs/phases/phase_8_gate/test_execution_manifest.md
  - scripts/run_phase8_gate_tests.ps1
- 7.51e complete: 28-file Flutter corpus rerun passed (all 28/28, re-verified post-7.52c). Gate blocked on vendor selection only.
- Phase 8 is blocked on vendor selection only.
  - 7.52 can proceed in parallel as non-architectural cleanup and product-boundary work:
    - repo rename
    - file and asset cleanup
    - product identity clarification
    - private Barrio layer setup inside the same repo
    - Barrio shell IA and handbook-learning work
    - no changes to the aligned Phase 8 data path
  - 7.52d complete: the internal Barrio code boundary now exists under `lib/internal/barrio/` with typed destination/source-material scaffolding and no public runtime wiring.
  - 7.52g complete: the Company Handbook is now a native all-staff Barrio learning surface with typed chapter content, chapter switching, interactive lesson cards, and focused handbook widget coverage; the public Forge & Flow runtime remained untouched.
  - 7.52h complete: the Interview Playbook and Jim Taylor destinations are now native private learning surfaces with typed content, scenario/checkpoint interactions, and focused widget coverage; Preston Lee remains Coming Soon, Supervisor Content remains light, and the public Forge & Flow runtime remained untouched.
  - 7.52i complete: a typed preview-role model, preview-aware shell emphasis, preview-role route propagation, and shared access-intent messaging now exist across the private Barrio destinations; focused preview-role and destination tests passed and the public Forge & Flow runtime remained untouched.

### 7.51d. Compatibility-Bridge Retirement + Pending-State Closure
- Decide which production `BaselineData` reads are being retired now versus explicitly frozen as temporary compatibility scope.
- Migrate or clearly freeze the remaining bridge usage in:
  - Baseline
  - Schedule
  - Learn
- Close the replay-readiness scenarios that are still pending when they are required by the formal Phase 8 gate:
  - no data
  - stale data
  - failed import
  - historical-only cold start
  - any other scenario still required pre-Phase-8
- Update the sign-off and replay matrix so the gate documents do not disagree with each other.

### 7.51e. Vendor Selection + Final Gate Sign-Off

- Select the first POS vendor.
- Select the first labor vendor.
- Replace TBD entries in both capability profiles with real vendor-specific details.
- Run the current 28-file Flutter test corpus one file at a time in a supported environment.
  - use docs/phases/phase_8_gate/test_execution_manifest.md
  - use scripts/run_phase8_gate_tests.ps1
  - record exact pass or fail results without reusing older file counts
- Only after the above is done should the final sign-off change from blocked to passed.

## Phase 7.52 Follow-On Scope

This is intentionally outside the core data-alignment gate.

7.52 is allowed to proceed while vendor selection is still pending as long as it does not reopen the aligned architecture.

Allowed 7.52 work:

- repo and package naming cleanup
- legacy file and asset cleanup
- product identity clarification so Forge & Flow is the product and restaurant name remains runtime-scoped
- private Barrio layer setup inside the same repo
- dual-build or flavor foundation for separate Forge & Flow and Barrio app identities from one codebase
- Barrio shell and private-route structure
- structured interactive private content surfaces built from source documents
- preparation for Phase 9 and Phase 10

Disallowed 7.52 drift:

- no new Phase 8 transport work without a vendor
- no new screen-level demo truth
- no forked Barrio codebase that duplicates Forge & Flow core
- no real login or permission enforcement before Phase 9
- no raw PDF or raw HTML file viewer being treated as the final private app experience if the content is meant to become a polished in-app surface
- no changes that bypass canonical models, SQLite, app state, and UI layering

## Phase 7.52 Execution Breakdown

7.52 is a product-shell and private-build phase, not a new data-architecture phase.

### 7.52a. Tracker Lock + Scope

- freeze the naming and product contract:
  - Forge & Flow = shared product
  - restaurant name = runtime restaurant scope
  - Barrio = private internal build identity
- freeze the phase boundary:
  - 7.52 builds shell, content structure, and build identity
  - Phase 9 owns login, permissions, and real access control
  - Phase 10 owns cross-device shared state
- lock the execution contract in:
  - `docs/archive/phases/phase_7_52_execution_plan.md`
- once that contract is written and accepted, advance the active execution block to `7.52b`

### 7.52b. Product Identity + Naming Cleanup

- rename public product-facing identity away from demo placeholders and public `Barrio` naming
- resolved hotspots included:
  - `pubspec.yaml`
  - `forge_and_flow.iml`
  - `README.md`
  - `android/app/src/main/AndroidManifest.xml`
  - `ios/Runner/Info.plist`
  - `windows/runner/Runner.rc`
  - `windows/runner/main.cpp`
  - `windows/CMakeLists.txt`
- keep restaurant display name runtime-scoped in the app itself
- completion note:
  - public product identity now reads as Forge & Flow across package, module, README, Android, iOS, and Windows visible app strings
  - default demo restaurant scope no longer uses the product name as the restaurant label
  - app title now remains `Forge & Flow` even when restaurant scope is loaded
  - stale persisted restaurant scope rows using `Forge & Flow Demo` are normalized on load so old demo branding does not leak back into the UI

### 7.52c. Legacy File + Private Asset Cleanup

- rename legacy/demo-heavy files to honest neutral names
- move Barrio-only root files into a private boundary under docs or assets
- remove stale root clutter that is not part of the shared product identity
- do not touch the aligned Phase 8 data path while doing this

### 7.52d. Private Barrio Boundary

- create a private Barrio layer inside the same repo
- Barrio-only docs, assets, routes, and content should live there
- shared product logic must remain in Forge & Flow core
- no forked customer product codebase
- completion note:
  - `lib/internal/barrio/` now exists with `content/`, `routes/`, `screens/`, and `widgets/`
  - a Barrio boundary entry file, destination manifest, and source-material catalog are now checked in
  - the scaffolding remains dormant and is not wired into `lib/main.dart` or public customer navigation

### 7.52e. Dual-Build Foundation

- prepare two future app identities from one codebase:
  - Forge & Flow
  - Barrio
- separate branding, app name, and icon identity are allowed here
- split those identities at the native build layer first:
  - Android product flavors
  - iOS schemes and build configurations
- use separate package or bundle ids, display names, app icon sets, and splash assets per identity
- keep one shared Dart runtime and `lib/main.dart` unless the Forge & Flow and Barrio shells truly diverge later
- prefer flavor-specific launcher-icon and native-splash config files over one shared single-brand generator block
- this is a build and product-shell concern, not a data-layer concern

### 7.52f. Barrio Shell IA + Home Navigation

- build the private Barrio shell before real auth exists
- use a destination-first home hub or living system map rather than a generic utility menu
- keep `Forge & Flow` as the primary destination inside Barrio
- show all major tools before auth, while only labeling future audience tiers
- the information architecture can be role-aware in structure even though enforcement waits for Phase 9
- completion note:
  - the private Barrio shell now exists as a real living-system-map home screen
  - typed route metadata and destination placeholder screens exist for all current Barrio destinations
  - focused shell widget coverage passed
  - the public Forge & Flow runtime remained untouched

### 7.52g. Company Handbook Experience

- source PDFs and business-plan material should be treated as source material, not as the final runtime experience
- the handbook should become a structured in-app all-staff learning surface
- use chapter progression, progress, quizzes, decision-based learning, and light game-style motivation where useful
- this surface should be searchable, navigable, and ready for later role gating
- completion note:
  - the handbook placeholder was replaced by a real native handbook screen inside the private Barrio boundary
  - typed handbook content now exists with three real source-backed chapters and two scaffolded chapters
  - chapter switching, decision interactions, and checkpoint interactions are now implemented natively
  - focused handbook and shell widget coverage passed without touching the public Forge & Flow runtime

### 7.52h. Manager/Admin Learning Surfaces

- build the `Interview Playbook`
- build the `Jim Taylor Labor Model`
- keep `Preston Lee Model` as `Coming Soon`
- reserve supervisor content in the shell structure even if the content remains light for now
- completion note:
  - the Interview Playbook placeholder was replaced by a real native learning surface with two fully built sections and two scaffolded sections
  - the Jim Taylor placeholder was replaced by a real native learning surface with three fully built modules and one scaffolded module
  - scenario and checkpoint interactions now exist across both manager/admin destinations
  - focused playbook, Jim Taylor, and shell widget coverage passed without touching the public Forge & Flow runtime

### 7.52i. Phase 9 Handoff

- if useful, add role-aware preview structure only
- do not implement real auth checks or permission enforcement
- stop 7.52 after shell, handbook, and manager-learning surfaces are ready for Phase 9 login and roles
- completion note:
  - typed preview-role behavior now exists for `Staff`, `Supervisor`, `Manager`, and `Admin`
  - the Barrio home shell now has a local role-preview control with `Admin` as the default preview state
  - destinations remain visible in every preview mode, but intent/emphasis and screen messaging now react to the selected preview role
  - route navigation now carries preview-role context into destination screens
  - focused preview-role, shell, handbook, playbook, and Jim Taylor widget coverage passed without touching the public Forge & Flow runtime

## Post-7.52 Handoff

- `7.52` is now complete as a private Barrio shell and content phase.
- the next active execution block outside Phase 7.52 is `7.53b - iOS per-flavor asset catalog split (macOS/Xcode)`.
- `7.53a` is effectively complete: Android flavors plus iOS schemes/configurations, ids, and display-name wiring landed while one shared Dart runtime remained intact.
- `7.53b` is the remaining native-build blocker: finish the iOS per-flavor app icon and splash asset-catalog split on macOS/Xcode.
- `9.1 - Restaurant identity + role model` should remain the next follow-on block after `7.53`.
- Phase 8 remains structurally ready but blocked on vendor selection only.

## Formal Readiness Gate For Phase 8
Do not start live adapter work until `Phase 7.51` is complete and the answer is "yes" to all of these:

- Can the app run end to end from imported fixture bundles without relying on direct screen-level demo constants?
- Can every tab explain where its numbers come from?
- Can the app distinguish source facts, derived targets, and locked historical snapshots?
- Are locked historical targets actually persisted well enough to prevent drift?
- Can a manager override trickle down immediately without rewriting history?
- Can a close-shift event lock targets and update week rollups correctly?
- Do canonical records carry restaurant or location scope correctly?
- Do raw import runs, dedupe, and import-status records exist?
- Does the project have a written capability profile and field-ownership plan for each vendor being targeted first?
- Can the app handle empty, partial, stale, and failed data states?
- Do deterministic tests and replay scenarios prove the logic is stable?

## Non-Goals Before Phase 8

- no vendor-specific API optimization yet
- no multi-location org management yet
- no remote multi-device sync in Phase 8 unless the first live rollout requires shared state across devices immediately
- no redesign of target math during adapter implementation
- no screen-specific exceptions for one vendor

## Deliverables To Have Ready Before Phase 8

- a post-Phase-7 app-state audit
- a source-of-truth map for major UI numbers
- fixture bundles that mimic future vendor inputs
- a local import or replay harness
- written connector capability profiles for the first target vendors
- written reservation connector capability profile before Phase 8R official reservation transport starts
- a source-ownership matrix for POS fields, labor fields, and app-owned derivations
- persistence separation between raw imports, canonical records, and target state
- explicit restaurant or location scope in canonical models and persistence
- persisted historical target truth for closed records
- closed-shift Full Week detail reading locked shift targets instead of current-global targets
- app-wide active-target propagation no longer depending on `BaselineData.revision`
- compatibility-bridge scope either retired or explicitly frozen and documented for remaining production surfaces
- no disagreement between the final sign-off doc and the replay-readiness matrix
- replay scenarios for historical, current-week, intraday, and close-shift flows
- explicit readiness sign-off that the app is aligned

## Success Definition

The app is aligned when a realistic imported fixture bundle can drive:

- the 60-day baseline
- the active target profile
- manager override behavior
- schedule recommendations
- live shift diagnosis
- week-to-date variance
- historical teaching
- closed-shift Full Week detail without rewriting history when overrides change later

without changing screen logic.

At that point, Phase 8 becomes:

"Connect real POS and labor systems to the existing pipeline."

not:

"Figure out how the app should work once real data shows up."

## Future Shared Restaurant State

This is not the current Phase 8 target, and it should be treated as a future Phase 10 concern rather than being mixed into restaurant login.

If the app must support:

- multiple installed devices for the same restaurant
- a login tab with restaurant-scoped users
- manager-only permissions such as override rights
- shared override state visible on every device

then local SQLite cannot be the only authority.

That future phase should add:

- restaurant-scoped user accounts or federated login mapping
- permission or role checks such as manager-only override rights
- a remote restaurant-scoped sync authority for shared settings and audit history
- device-local SQLite as cache and offline store
- outbound and inbound sync handling for shared mutations

Minimum shared-state concepts for that later phase:

- `restaurant_users`
- `restaurant_roles`
- `device_installations`
- `shared_mutations` or sync queue
- audit metadata such as `updated_by_user_id` and `updated_at`

## Future Restaurant Identity And Authorization

This is the future Phase 9 concern.

The desired Phase 9 login experience can be:

- `restaurant id`
- `username`
- `password`

But the implementation should separate:

- authentication
- identity mapping
- authorization

Recommended model:

- Authentication
  - app-managed restaurant credentials created during onboarding
  - usernames should mirror the restaurant's existing POS-style naming convention when that helps adoption
  - passwords or temporary credentials should be managed by the app, not pulled from POS or labor vendors
- Identity mapping
  - map the authenticated person to one `RestaurantUser`
  - optionally link that user to vendor employee ids from POS and labor systems
- Authorization
  - always remain app-owned
  - the app decides who can override, manage users, or change settings

Recommended starting roles:

- `supervisor`
  - can view all operational data
  - cannot apply override
- `manager`
  - can view all operational data
  - can apply override
- `owner_admin`
  - can view all operational data
  - can manage users, roles, permissions, and identity mappings

Recommended future concepts:

- `restaurant_users`
- `role_permission_sets`
- `vendor_identity_links`
- `user_sessions`
- `shared_mutations`
- audit metadata such as `created_by_user_id`, `updated_by_user_id`, and `updated_at`

Recommended onboarding extension for that phase:

- create the initial restaurant users during onboarding
- assign their starting roles such as supervisor, manager, or owner_admin
- issue temporary app credentials or a first-login reset path

Recommended future admin-screen responsibilities:

- list users for the restaurant
- assign roles
- adjust permission sets
- create or reset restaurant user credentials
- map users to vendor employee identities when helpful for reconciliation
- review recent shared administrative changes

## Future Corporate / Franchise Structure

This is a later future phase, after restaurant-level auth/login and shared multi-device sync are stable.

Guiding rules:

- restaurant id remains the operational truth boundary
- baselines, active targets, overrides, and close-shift truth remain restaurant-scoped
- corporate or franchise layers should aggregate restaurant truth rather than replace it

Expected future concerns:

- organization or franchise hierarchy above restaurants
- corporate users with cross-store visibility
- optional corporate permissions that do not override restaurant-level truth semantics
- cross-store reporting, benchmarking, and administrative visibility
