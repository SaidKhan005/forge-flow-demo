# Mobile Core Logic Data Wiring Contract

Date: 2026-05-06

Status: planning and execution contract

Purpose: capture the mobile data wiring audit in one durable place so implementation can close the remaining gaps without losing the core app logic.

This document covers the full operational flow discussed in the audit:

- vendor connection and first 60-day backfill
- closed shift truth
- live shift truth
- star shift recommendations and manager overrides
- target cycles and active target profiles
- weekly plan snapshots and forecast numbers
- business timing, dayparts, and hierarchy overrides
- admin/web settings that must reflect on mobile
- business structure scope selection for consultants and multi-location users
- screen-by-screen wiring expectations

## Authority

Implementation should follow this document, then the existing authority chain:

1. `PROJECT_TRACKER.md`
2. `docs/contracts/integration_spine_architecture_contract.md`
3. `docs/contracts/phase_7_55_time_boundary_contract.md`
4. `docs/phases/phase_business_timing_live/business_timing_live_plan.md`
5. `docs/contracts/slice_runtime_acceptance_contract.md`
6. `CLAUDE.md`

If any implementation detail conflicts with the core data spine, the core data spine wins.

## Core App Logic In Plain English

Forge & Flow is not supposed to be a phone-only calculator.

The intended product logic is:

1. Vendors provide operational facts.
2. Server adapters turn vendor payloads into canonical facts.
3. Server-side logic writes durable Postgres truth.
4. Business settings explain how to bucket and interpret that truth.
5. Star shifts and manager choices create locked targets.
6. Locked targets create weekly plan snapshots.
7. Mobile pulls fixed server truth through the proxy.
8. Mobile SQLite is a cache, not the source of truth.
9. Screens read the cache for speed, but the server owns the truth.
10. Users only see the business scopes they are allowed to access.

The phone must not talk directly to vendors or directly to Postgres.

## Current State Summary

Some plumbing is now real:

- Mobile can pull closed `shift_records` through the proxy.
- Mobile can pull `open_shift_snapshots` through the proxy.
- Mobile can pull resolved timing config.
- Mobile can pull demo mode state.
- Mobile can pull data accuracy settings.
- Mobile can pull polling tier assignment.
- Shift, Variance, History, Learn, Star Shifts, and Plan can consume local SQLite rows once those rows exist.

But the server-side creation and decision layer is still incomplete:

- First connection does not reliably enqueue and complete the 60-day backfill.
- Backfilled facts do not have a fully proven production path into closed `shift_records`.
- Live vendor facts do not yet have the complete `OpenShiftSnapshotProjector` path.
- Star shift selections are still local-only.
- Target cycles are still local-only.
- Active target profiles are still local-only.
- Weekly plan snapshots are still local-only.
- Business scope selection on mobile is not built.
- Multi-location and hierarchy rollups are not built.
- Some web/admin settings sync to mobile, but not all business-control settings do.

## Data Object Definitions

### Vendor Fact

A vendor fact is raw operational truth normalized into app shape.

Examples:

- POS check/order
- covers
- net sales
- labor punches
- labor dollars
- reservations
- party size
- booking state

Vendor facts are not screen data yet. They must be transformed into business read models.

### Closed Shift Record

A closed shift record is the durable history for one location, business date, and service period after the shift is complete.

It feeds:

- Star Shift candidates
- 60-day benchmarks
- forecast context
- target recommendations
- History
- Learn
- Variance closed rows
- distribution weights

### Open Shift Snapshot

An open shift snapshot is the current live shift read model.

It feeds:

- Shift Dashboard live state
- current service-period lens
- live Variance state

It is provisional. It must not replace closed shift truth.

### Star Shift Selection

Star shift selection is a business decision.

It is not the same as a recommended candidate list.

Candidates can be generated from closed shift history. The final selected stars, especially manager-selected stars, must become server-backed decision truth.

### Target Cycle

A target cycle is the locked standards window.

It is created from recommended or manager-selected stars. It must preserve:

- source type
- selected shift summary
- calibration window
- effective window
- whether manager override was used
- target CPLH
- target SPLH
- target PPA
- FOH wage
- BOH wage
- OPZ floor and ceiling

### Active Target Profile

The active target profile is the currently effective target tuple used by screens.

It is projected from the current target cycle and should be server-backed.

### Weekly Plan Snapshot

A weekly plan snapshot is the locked plan truth for the current week.

It should not be recomputed loosely every time a screen opens.

It should be created from:

- active target profile
- demand forecast context
- distribution weights
- timing/week-start config

Then it should be locked and pulled by mobile.

### Business Scope

Business scope is the selected level the user is looking at.

Examples:

- company
- ownership group
- region
- location
- one restaurant

Users should only see scopes their role grants them.

## Required End-To-End Spine

### First Connection Spine

When a vendor is connected for the first time:

1. User connects vendor in web/admin/operator flow.
2. Server persists vendor credentials.
3. Server persists `connector_connection`.
4. Server enqueues a first 60-day backfill job.
5. Worker runs adapter `backfill`.
6. Adapter writes canonical facts.
7. Server advances watermark per batch.
8. Server flips demo mode only after first committed batch with at least one row.
9. Server runs closed-shift aggregation.
10. Server writes closed `shift_records`.
11. Server projects or updates target/recommendation inputs.
12. Mobile sync pulls the new records through proxy.
13. Screens leave setup/loading state and show real data.

Acceptance: a new connected operator can go from empty account to visible closed shift history on mobile without manual database seeding.

### Closed Shift Spine

Closed shift creation must follow:

1. POS/labor/reservation facts land server-side.
2. Facts are bucketed by stable `service_period_key`.
3. Aggregator builds `ClosedShiftInput`.
4. `ShiftFactBuilder` calculates the formula outputs.
5. Writer persists `shift_records`.
6. Existing closed rows preserve their original timing provenance and target provenance.
7. Proxy exposes changed rows.
8. Mobile sync writes local SQLite.
9. History, Learn, Variance, Star Shifts, and Plan see the row.

Acceptance: a closed service period from vendor facts becomes one mobile-visible closed row with correct covers, sales, labor, target fields, timing provenance, and source provenance.

### Live Shift Spine

Live shift creation must follow:

1. POS/labor/reservation events arrive while the business date is still open.
2. Canonical facts are bucketed by stable `service_period_key`.
3. `OpenShiftSnapshotProjector` writes per-service-period rows to `open_shift_snapshots`.
4. Projector writes a Whole Day rollup from the service-period buckets.
5. Proxy exposes changed snapshots.
6. Mobile sync writes local SQLite.
7. Shift Dashboard renders live state.

Acceptance: POS webhook to mobile dashboard can be demonstrated in one path:

POS webhook -> canonical fact -> projector -> Postgres `open_shift_snapshots` -> proxy pull -> mobile SQLite -> Shift Dashboard live indicator.

### Star Shift And Manager Override Spine

Star shift candidates and selected star shifts are different.

Candidate path:

1. Closed `shift_records` exist for the 60-day window.
2. Server or mobile read model builds candidate list.
3. Recommendations mark suggested stars.
4. Mobile displays candidates.

Selection path:

1. Manager selects or clears stars.
2. Mobile sends selection to proxy.
3. Server checks permission.
4. Server checks the once-per-cycle override rule.
5. Server writes selected star keys.
6. Server writes audit trail.
7. Server writes or replaces target cycle.
8. Server projects active target profile.
9. Server creates or updates weekly plan snapshot according to plan policy.
10. Mobile pulls the new fixed truth.

Acceptance: manager selection on one device is visible on another device after sync, and the target/plan surfaces update from server truth.

### Target And Weekly Plan Spine

Targets and plans are fixed business truth, not random screen state.

Target path:

1. Recommended stars or manager-selected stars are resolved.
2. Server creates target cycle.
3. Server projects active target profile.
4. Mobile sync pulls active target profile.
5. Screens read the local cache.

Plan path:

1. Server builds demand forecast context from closed history.
2. Server combines demand with active target profile and distribution weights.
3. Server creates weekly plan snapshot.
4. Weekly snapshot is locked for the in-force week.
5. Mobile sync pulls the locked snapshot.
6. Schedule, Shift, and Variance read the locked snapshot.

Acceptance: opening Schedule in production mode never silently generates a new local plan when the server plan is missing. It shows setup/unavailable state until server truth arrives.

### Timing And Daypart Spine

Timing and dayparts must follow hierarchy.

Hierarchy:

1. company default timing
2. group or region override
3. location override
4. resolved location timing config

Mobile should receive the resolved config, but durable rows must preserve stable provenance.

Closed shift rows must carry:

- `business_timing_profile_id`
- `business_timing_profile_version_id`
- `service_period_key`

Live rows must carry:

- `business_timing_profile_id`
- `business_timing_profile_version_id`
- `service_period_key`

Acceptance: if an operator renames Dinner to Supper next month, last month's closed Dinner rows still resolve using the original timing version.

### Admin/Web Settings Spine

Any web/admin setting that changes app calculations, data interpretation, access, or planning must flow to mobile.

Already partially wired:

- resolved timing config
- data accuracy settings
- polling tier assignment
- demo mode state

Still required:

- selected star shifts
- target cycles
- active target profiles
- weekly plan snapshots
- wage source and wage mix details used in labor calculations
- role/job-code mapping
- reservation demand settings
- business structure and accessible scopes
- admin-created org/location changes

Acceptance: after an admin changes an operational setting on web/admin, mobile either syncs the change or clearly shows that the setting is not mobile-facing yet. No hidden divergence.

### Business Scope Spine

Mobile needs a top-left hamburger scope selector.

The scope selector must:

1. Show only business scopes the user can access.
2. Support consultant access across multiple locations or org units.
3. Allow switching active scope.
4. Update local active scope.
5. Cancel any in-flight sync for the old scope.
6. Wipe or isolate old-scope cache.
7. Pull fresh data for the new scope.
8. Refresh all screens.

Location scope can use existing screen models.

Group, region, or company scope requires server rollup models. In this mobile sprint, higher-level grants must instead expand server-side into their underlying selectable location rows. Mobile must not fake rollups by mixing location rows locally.

Acceptance: a consultant with access to two locations can switch between them from the hamburger menu and never see data leakage from the prior scope.

## Screen Contracts

### Dashboard / Shift Screen

Must read:

- live `open_shift_snapshots`
- closed `shift_records`
- active target profile
- locked weekly plan snapshot
- resolved timing config
- current business scope

Must not:

- show demo data after live backfill succeeds
- pretend live data exists when server has no open snapshot
- use mutable daypart labels for closed truth

Required states:

- setting up first connection
- backfill running
- waiting for live snapshot
- live
- stale
- disconnected

### Star Shifts / Baseline Screen

Must read:

- closed 60-day shift records
- recommended star candidates
- selected star shifts
- active target cycle
- manager override availability
- current business scope

Must write:

- manager selected stars through proxy
- clear selection through proxy

Must not:

- store final selection as local-only truth
- bypass once-per-cycle override rule
- create fake manager selection rows for app recommendations

### Plan / Schedule Screen

Must read:

- locked weekly plan snapshot
- active target profile
- demand forecast context
- distribution weights
- resolved timing config and week start
- current business scope

Must not:

- silently generate a local plan in production read-only mode
- drift from the server plan
- show a blank screen without setup reason

Forecast numbers must be explainable:

- 60-day baseline total covers
- 60-day weekly average
- 21-day recent trend
- smoothed resolved weekly forecast
- target PPA
- forecast sales
- required FOH hours
- required BOH hours
- theoretical labor dollars

### Variance Screen

Must read:

- closed shift records
- open shift snapshots
- locked weekly plan snapshot
- active target profile
- resolved timing config

Must not:

- compare against a local-only target if server target exists
- compare closed rows using current timing labels instead of saved timing provenance

### History Screen

Must read:

- closed shift records
- timing provenance
- target provenance

Must not:

- relabel old rows using current mutable settings
- show backfilled rows without source provenance

### Learn Screen

Must read:

- closed 60-day history
- benchmark/star context
- timing provenance
- target provenance

Must not:

- claim learning confidence without enough closed history
- learn from demo rows after live data is active unless explicitly in demo mode

### Settings / Data Accuracy / Timing

Must read:

- resolved timing config
- data accuracy settings
- polling tier
- demo mode state
- accessible business scopes where relevant

Must write through server when the setting affects shared truth.

### Scope Drawer / Hamburger Menu

Must read:

- accessible operators
- accessible org units
- accessible locations
- current scope
- permissions for each scope

Must write:

- selected active mobile scope

Must trigger:

- sync cancellation for previous scope
- cache isolation or wipe
- fresh proxy pull for new scope
- screen refresh

## Execution Plan

### Phase 0: Freeze The Contract

Deliverables:

- This document committed.
- Coding prompts reference this document.
- Each slice must list which contracts it satisfies.

Acceptance:

- No implementation slice starts without mapping to this document.

### Phase 1: Mobile Scope Foundation

Deliverables:

- Server route for accessible business scopes.
- Mobile model for scope options.
- Local active scope repository.
- Top-left hamburger button in the app toolbar.
- Scope drawer UI.
- Scope-switch runtime behavior.

Contracts:

- Permission-scoped options only.
- No stale data from previous scope.
- No multi-location rollup unless server provides rollup truth.

Acceptance:

- Consultant can switch allowed locations.
- Unauthorized location does not appear.
- Switching scope triggers fresh sync.

### Phase 2: First Connection 60-Day Backfill

Deliverables:

- Production integration route bindings.
- On first connect, enqueue 60-day backfill.
- Worker runs adapter `backfill`.
- Worker writes canonical facts.
- Backfill status exposed to web/admin and mobile.
- Demo mode flip on first committed batch with records.

Contracts:

- Backfill window is bounded.
- Watermarks persist per batch.
- Sanity hook runs per row.
- Mobile does not run vendor backfill directly.

Acceptance:

- New vendor connection produces closed history without manual seeding.

### Phase 3: Closed Shift Server Truth

Deliverables:

- Production trigger from canonical facts to closed `shift_records`.
- Timing provenance added to closed rows.
- Source provenance preserved.
- Re-aggregation preserves existing closed timing/target provenance.

Contracts:

- Stable `service_period_key`.
- No mutable daypart-label authority on closed rows.
- Concern A preserved: do not rewrite closed target/timing provenance.

Acceptance:

- 60-day backfill creates usable History, Learn, Star candidates, and forecast context.

### Phase 4: Live Shift Projector

Deliverables:

- `OpenShiftSnapshotProjector`.
- Per-service-period open rows.
- Whole Day rollup from buckets.
- Proxy pull already exists, verify shape.
- Mobile dashboard rendering proof.

Contracts:

- Bucket by stable `service_period_key`.
- Whole Day rollup comes from service-period buckets.
- Live snapshots do not overwrite closed records.

Acceptance:

- Live POS event appears on Shift Dashboard through proxy and mobile SQLite.

### Phase 5: Star Selection And Manager Override Server Truth

Deliverables:

- Server table for selected star shifts.
- Proxy read/write routes.
- Mobile sync/read repository.
- Manager override write path through proxy.
- Permission and once-per-cycle validation.
- Audit log for selection changes.

Contracts:

- Recommendations and manager selections are separate.
- Manager selection is shared truth.
- One manager override per cycle unless admin reset permits otherwise.

Acceptance:

- Selection made on one device appears on another.
- Override updates target cycle and active target profile.

### Phase 6: Target Cycle And Active Target Profile Server Truth

Deliverables:

- Server-owned target cycles.
- Server-owned active target profiles.
- Proxy sync routes.
- Mobile SQLite mirror.
- Screens read server-backed local mirrors.

Contracts:

- Target cycle is immutable once locked except approved replacement path.
- Active target profile is a projection of target cycle.
- All rows are operator/location/scope isolated.

Acceptance:

- Star selection or recommendation produces the same target profile across devices.

### Phase 7: Weekly Plan Snapshot Server Truth

Deliverables:

- Server-owned weekly plan snapshot creation.
- Server-owned forecast context or serialized forecast explanation.
- Proxy sync route.
- Mobile SQLite mirror.
- Schedule reads locked server snapshot.

Contracts:

- Production Schedule read path must not auto-generate local plans.
- Forecast numbers must be explainable from 60-day baseline, 21-day trend, target PPA, and target profile.
- Week start comes from resolved timing config.

Acceptance:

- Missing server snapshot produces setup/unavailable state, not silent local fallback.

### Phase 8: Web/Admin Settings To Mobile

Deliverables:

- Complete settings inventory.
- Sync or read routes for mobile-facing settings.
- Mobile cache for shared settings.
- Realtime invalidation topics.

Contracts:

- If a setting changes calculations, it must be server truth.
- Mobile must refresh after admin changes.
- No split-brain between web/admin and mobile.

Acceptance:

- Change timing/data accuracy/target-related settings on web/admin, then verify mobile reflects it after sync.

### Phase 9: Screen Wiring And Empty States

Deliverables:

- Shift setup/backfill/live/stale states.
- Star Shifts setup/backfill/no-candidates/ready states.
- Plan setup/no-history/no-target/no-snapshot/ready states.
- Variance setup/live/closed/stale states.
- History/Learn thin-history states.

Contracts:

- Empty means truly no data.
- Loading means work is active.
- Setup means a required upstream piece is missing.
- Stale means last good data exists but freshness failed.

Acceptance:

- No core screen opens blank without a plain-English reason.

### Phase 10: End-To-End Device Proof

Deliverables:

- Connected mobile device E2E test plan.
- Simulated vendor data where live vendor credentials are unavailable.
- Real proxy and mobile SQLite verification.
- Screenshot or log evidence per screen.

Required paths:

1. first connect -> backfill -> closed shifts -> Star candidates
2. manager selection -> target cycle -> active target profile -> plan
3. POS live event -> open snapshot -> Shift Dashboard
4. admin timing change -> mobile timing config -> screen dayparts
5. scope switch -> fresh data -> no leakage

Acceptance:

- All paths proven on connected device or explicitly simulated with documented substitutions.

## Hard Contracts For Coding

### Contract 1: Mobile Is A Cache

Mobile SQLite is a cache of server truth for shared business objects.

Mobile may store:

- cached server rows
- local UI state
- local sync watermarks
- temporary drafts before submit

Mobile must not be the only durable owner for:

- selected star shifts
- target cycles
- active target profiles
- weekly plan snapshots
- business scope access
- admin settings

### Contract 2: No Direct Vendor Or Postgres Calls From Mobile

Mobile communicates through:

- proxy routes
- realtime subscription
- push notification registration

Mobile must not:

- call vendors directly
- import Postgres drivers
- hold provider credentials

### Contract 3: Stable Timing Keys

Every durable operational row that is bucketed by service period must store stable timing keys.

Required keys:

- `business_timing_profile_id`
- `business_timing_profile_version_id`
- `service_period_key`

Mutable labels are display only.

### Contract 4: Star Recommendations Are Not Manager Overrides

Recommended stars can be generated by the app.

Manager-selected stars are explicit decisions and must be persisted separately.

No code may fabricate manager-selected rows just because the recommendation engine picked candidates.

### Contract 5: Locked Weekly Plan Is The In-Force Truth

The in-force weekly plan must be read from the locked weekly plan snapshot.

Production read-only screens must not generate a new local plan on miss.

Generation is allowed only in explicit server-side or approved bootstrap paths.

### Contract 6: Scope Must Gate Everything

Every shared read and write must be scoped by the selected business access level.

Location scope reads location truth.

Group/region/company scope reads server rollup truth.

No local mixing of unrelated location caches unless a rollup contract explicitly permits it.

### Contract 7: Permissions And Audit

Manager and admin writes must be:

- permission checked
- idempotency keyed
- audit logged
- visible through sync or refresh

This applies to:

- star selection
- manager override
- target replacement
- timing changes
- data accuracy changes
- wage/source settings
- scope-sensitive access changes

### Contract 8: Empty Screens Must Explain The Missing Upstream Piece

Do not show blank operational screens.

Every core screen needs a reasoned state:

- waiting for first connection
- first backfill running
- no closed history yet
- no live snapshot yet
- no target cycle yet
- no weekly plan snapshot yet
- sync stale
- permission denied

### Contract 9: Realtime Is A Signal, Not Truth

Realtime tells mobile to refresh.

Proxy pull plus SQLite write provides durable truth.

Do not rely on realtime frames as the only copy of business data.

### Contract 10: Cross-Device Behavior Required

Any shared business object changed on one device must appear on another after sync.

This includes:

- selected star shifts
- target cycle
- active target profile
- weekly plan snapshot
- timing config
- admin settings

## Proposed Proxy Sync Surface

Existing or partially existing:

- `shift_records`
- `open_shift_snapshots`
- `timing/resolved`
- `demo_mode_states`
- `data_accuracy_settings`
- `polling_tier_assignment`

Needed:

- accessible business scopes
- selected star shifts
- recommended star candidates or recommendation summary
- target cycles
- active target profiles
- weekly plan snapshots
- forecast context or forecast explanation
- wage/role mapping settings
- reservation demand settings
- admin org/location changes relevant to mobile

Proposed mobile pull routes can follow the existing pattern:

- `/v1/operators/:operatorId/locations/:locationId/baseline_selected_records`
- `/v1/operators/:operatorId/locations/:locationId/target_cycles/current`
- `/v1/operators/:operatorId/locations/:locationId/active_target_profile`
- `/v1/operators/:operatorId/locations/:locationId/weekly_plan_snapshots/current`
- `/v1/operators/:operatorId/locations/:locationId/forecast_context/current`
- `/v1/operators/:operatorId/business_scopes`
- `/v1/operators/:operatorId/business_scopes/:scopeId/snapshot`

Names may change during implementation, but the contracts must remain.

## Migration Inventory Needed

Likely server migrations:

- add timing provenance columns to `public.shift_records`
- create selected star shift table
- create or promote server `target_cycles`
- create or promote server `active_target_profiles`
- create or promote server `weekly_plan_snapshots`
- create mobile-facing forecast context table or projection
- create indexes leading with `operator_id`
- add audit/event topics for all shared decision changes

Likely mobile SQLite migrations:

- selected star shift cache
- target cycle cache
- active target profile cache
- weekly plan snapshot cache
- accessible business scope cache
- forecast context cache if not embedded in weekly plan snapshot

## Testing Contract

Minimum tests per slice:

- unit tests for pure builders/resolvers
- repository tests for SQLite and Postgres writes
- proxy route tests for auth, scope, pagination, and idempotency
- mobile sync tests for pull, write, cursor, and cross-tenant wipe
- screen state tests for setup/loading/ready/stale
- E2E test or documented simulation for every required spine path

Required E2E parcels:

1. first connection backfill fills mobile closed history
2. closed history fills Star Shift candidates
3. manager override writes server selection and updates targets
4. targets produce active target profile
5. active target profile produces locked weekly plan
6. locked weekly plan appears on Schedule
7. live POS event appears on Dashboard
8. timing hierarchy change affects future rows, not old closed rows
9. scope switch refreshes mobile without data leakage

## Plain-English Done Definition

This work is done when a real operator can:

1. Connect vendors.
2. Wait for first 60-day backfill.
3. See real shift history on mobile.
4. See Star Shift candidates from that history.
5. Pick stars manually if desired.
6. Have those picks saved as shared server truth.
7. See targets update from those picks.
8. See a locked weekly plan from those targets.
9. See live shift activity from vendor events.
10. Change timing/settings in web/admin and see mobile reflect it.
11. Switch business scope from the mobile hamburger menu if their role allows it.
12. Open every screen without mystery blanks.

## Do Not Miss Checklist

- [ ] First-connection backfill is actually enqueued and run.
- [ ] Backfill writes canonical facts.
- [ ] Canonical facts create closed `shift_records`.
- [ ] Closed rows store timing provenance.
- [ ] Mobile pulls first backfill history.
- [ ] Star candidates populate from closed rows.
- [ ] Recommended stars stay separate from manager selections.
- [ ] Manager selections write through proxy.
- [ ] Manager override is permission-checked.
- [ ] Manager override is audit-logged.
- [ ] Manager override updates server target cycle.
- [ ] Target cycle projects server active target profile.
- [ ] Active target profile syncs to mobile.
- [ ] Weekly plan snapshot is server-owned.
- [ ] Schedule reads locked snapshot, not local fallback.
- [ ] Forecast numbers are explainable.
- [ ] Dayparts come from resolved timing config.
- [ ] Closed rows preserve original timing version.
- [ ] Live projector creates `open_shift_snapshots`.
- [ ] Whole Day live row rolls up from service-period buckets.
- [ ] Admin/web settings sync to mobile where they affect behavior.
- [ ] Hamburger scope selector exists on mobile.
- [ ] Scope options are permission-scoped.
- [ ] Scope switch cancels old sync and refreshes new scope.
- [ ] Higher-level grants expose underlying locations unless a future server rollup truth exists.
- [ ] Realtime invalidates, proxy pull persists.
- [ ] Empty screens explain what is missing.
- [ ] Connected-device E2E proof covers all core paths.

