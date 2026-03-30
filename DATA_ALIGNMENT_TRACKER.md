# Data Alignment Tracker

Updated: 2026-03-29
Owner: You
Purpose: Make sure the app is fully aligned for live POS + labor integrations before Phase 8 begins.

## North Star

POS + Labor Systems -> Canonical Shift Facts -> Rolling 60-Day Baseline -> Active Target Profile -> Schedule -> Shift -> Variance -> Learn

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

- API adapters should only pull the relevant POS and labor data.
- The app should reshape that data into its own canonical format immediately.
- SQLite should hold at least the restaurant's rolling 60-day operational truth plus current-week and target-profile state.
- Providers and notifiers should expose current app state from repositories and queries, not from vendor payloads or screen constants.
- UI should render that app state without needing to know where the data came from.

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
- App owns:
  - daypart mapping rules
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
- schedule or forecast updates

Writes:

- raw import records
- import-run metadata
- `OpenShiftSnapshot`
- `CurrentWeekState`

UI impact:

- Shift
- current-week projections
- schedule/live banners when relevant

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
- Schedule uses forecast covers plus the active target profile.
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
- `lib/data/demo_data.dart`
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
  - reads forecast input plus `ActiveTargetProfile`
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

## Formal Readiness Gate For Phase 8

Do not start live adapter work until the answer is "yes" to all of these:

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
- a source-ownership matrix for POS fields, labor fields, and app-owned derivations
- persistence separation between raw imports, canonical records, and target state
- explicit restaurant or location scope in canonical models and persistence
- persisted historical target truth for closed records
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
