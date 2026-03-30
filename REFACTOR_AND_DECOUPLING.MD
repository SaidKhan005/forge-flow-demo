# Refactor and Decoupling Plan

Updated: 2026-03-29
Owner: You
Purpose: Define the repo-wide refactor needed to reach the pre-Phase-8 alignment gate so live vendor integrations can remain adapter and transport work only.

## North Star Pipeline

Vendor APIs / Fixture Replays
-> Adapter DTOs
-> Canonical import mappers
-> Canonical domain models
-> Domain services / use cases
-> Repositories
-> SQLite persistence
-> In-memory app state (providers/notifiers)
-> UI

## Architecture We Are Actually Aiming For

The desired app shape is:

- API adapters pull only the relevant POS and labor data
- adapter DTOs are translated immediately into canonical app facts
- canonical facts are persisted locally for the restaurant, including at least a rolling 60-day operational window
- repositories expose app truth to queries, use cases, and in-memory state
- providers and notifiers hold current app state for the UI
- screens render that state without caring whether the source was fixture replay or a live vendor

This means the app should have separate and scalable layers for:

- vendor transport
- canonical app data
- persistence
- in-memory current state
- business logic
- UI

## Current To Target Mapping

This is the practical replacement map for the current repo.

- `BaselineData`
  - split into:
    - `BaselineBuild`
    - `ActiveTargetProfile`
    - `ActiveTargetProfileNotifier`
- `ShiftSnapshot`
  - replace with `OpenShiftSnapshot`
- `ShiftMetrics.cards`
  - replace with a `ShiftDashboardReadModel` built from query state
- `WeekToDate`
  - replace with `CurrentWeekState` or a `CurrentWeekQuery`
- `WeeklyVariance`
  - replace with repository-backed week read models
- `ShiftService.closeShift()`
  - evolve into `FinalizeShiftUseCase`
- `TargetSnapshotBuilder.fromCurrentBaseline()`
  - evolve into `TargetSnapshotBuilder.fromActiveTargetProfile(profile)`
- `DatabaseHelper`
  - split into SQLite bootstrap + DAOs + repository implementations
- `BaselineManagerService`
  - evolve into `ApplyManagerOverrideUseCase`

## Why This File Exists

The current repo already has important canonical foundations, but it still has several places where demo-shaped screen state, static global target state, and persistence concerns are mixed together.

This document defines:

- the target dependency direction
- the current repo hotspots that break that direction
- the specific refactor needed by file group
- the migration order
- the validation needed before Phase 8 starts

## Architectural Rules

- UI must not read vendor payloads directly.
- UI must not depend on `DemoData`, `ShiftSnapshot`, `ShiftMetrics`, `WeekToDate`, or `WeeklyVariance` for production truth.
- Vendor-specific DTOs must stop at the adapter layer.
- Canonical domain models must not import SQLite or widget code.
- In-memory state must cache or project truth, not define truth.
- Local SQLite is the device-local operational store, not the long-term shared authority for cross-device restaurant state.
- Closed shifts must lock the active target profile at close time.
- Open and future views must read the current active target profile.
- Historical views must read locked historical snapshots.
- Daypart remains the atomic truth unit.

## Current Repo State

### Good Foundations Already Present

- Canonical close-shift ingress exists:
  - `lib/domain/models/closed_shift_input.dart`
  - `lib/domain/models/target_snapshot.dart`
  - `lib/domain/models/shift_fact.dart`
  - `lib/domain/services/target_snapshot_builder.dart`
  - `lib/domain/services/shift_fact_builder.dart`
- Core labor formulas are centralized in `lib/services/labor_model.dart`.
- History teaching now flows from tracked closed shifts rather than only manual pattern records.
- `ShiftDataSource` already proves that some screens can be decoupled from SQLite details.
- `WeekDataNotifier` already acts like shared in-memory query state instead of widget-local recomputation.

### Main Misalignments

- `lib/data/meridian_data.dart` combines too many layers in one file:
  - restaurant config
  - screen demo constants
  - baseline computation
  - OPZ computation
  - lever copy
  - schedule defaults
  - active in-memory target state
- `BaselineData` is a static global rather than a first-class target profile or baseline aggregate.
- `lib/models/week_data.dart` and `lib/models/week_record.dart` import active target globals instead of receiving a target profile or using a query service.
- `lib/data/database_helper.dart` mixes persistence mechanics with demo seeding behavior.
- Several production screens still read demo-owned truth directly.
- Closed-shift target snapshots are described as durable historical truth, but the current persisted shape does not yet store the full locked target picture.
- Canonical models and persistence are not yet restaurant- or location-scoped.
- There is no raw import layer yet for replay, dedupe, reconciliation, and import-status tracking.
- Current and open-state modeling is still weaker than closed historical modeling.

## Audit Corrections That Must Be In Scope

These are required design corrections for Phase 7.5.

### 1. Persist Historical Target Truth

- Closed operational records must persist either:
  - a full locked target snapshot, or
  - a durable `targetProfileId` plus versioned target-profile history that preserves exact historical truth
- Historical screens must stop reading current active targets for past records.

### 2. Add Restaurant Scope

- Canonical domain models must support `restaurantId` or `locationId`.
- Persistence tables must carry that scope.
- Import runs and target profiles must also be restaurant-scoped.

### 3. Add A Real Raw Import Layer

- Introduce raw import persistence for fixture replay and future vendor adapters.
- Support:
  - import runs
  - dedupe or idempotency keys
  - received timestamps
  - source metadata
  - import status
  - optional cursor or watermark metadata

### 4. Model Open and Current State Explicitly

- Add explicit models for projected shifts, open shifts, and current-week state.
- Replace screen-level constants with provider-backed state over time.

### 5. Make Repository Ports Explicit

- Repository interfaces belong above persistence.
- SQLite implementations belong below those interfaces.
- Application state should read repositories and use cases, not raw DB helpers.

## Known Hotspots To Refactor

### Direct Demo Reads In Production Surfaces

- `lib/screens/shift_dashboard.dart`
  - reads `ShiftSnapshot`
  - reads `ShiftMetrics.cards`
- `lib/widgets/zone_status_card.dart`
  - reads `ShiftSnapshot.actualCPLH`
- `lib/screens/variance_report.dart`
  - Full Week section reads `DemoData.currentWeekShifts`
- `lib/screens/settings_screen.dart`
  - reset actions are still demo-reseed oriented

### Static Global Target Coupling

- `lib/data/meridian_data.dart`
  - `BaselineData`
  - `ScheduleDay`
  - `DaypartForecast`
- `lib/models/week_data.dart`
- `lib/models/week_record.dart`
- `lib/screens/schedule_builder.dart`
- `lib/screens/baseline_tracker.dart`
- `lib/screens/week_detail_screen.dart`
- `lib/screens/variance_report.dart`
- `lib/screens/shift_dashboard.dart`
- `lib/widgets/zone_status_card.dart`

### Persistence and App Logic Mixed Together

- `lib/data/database_helper.dart`
- `lib/data/shift_service.dart`
- `lib/data/baseline_manager_service.dart`

## Target Package Shape

The repo does not need a big-bang rewrite, but the target shape should move toward this:

```text
lib/
  application/
    state/
    use_cases/
    queries/
    read_models/
  domain/
    models/
    services/
    repositories/
    value_objects/
  infrastructure/
    adapters/
      pos/
      labor/
      fixtures/
    mappers/
    persistence/
      sqlite/
        dao/
        repositories/
        seed/
  presentation/
    screens/
    widgets/
    theme/
    content/
```

This can be introduced gradually while current folders still exist.

## Suggested SQLite Shape

Exact names can change, but the responsibilities should not.

### Restaurant / Connector Scope

- `restaurant_locations`
  - `restaurant_id`
  - `display_name`
  - `business_timezone`
  - `daypart_config_json`
  - `created_at`
  - `updated_at`
- `connector_configs`
  - `connector_id`
  - `restaurant_id`
  - `source_type`
  - `external_location_id`
  - `status`
  - `created_at`
  - `updated_at`

### Raw Import Layer

- `import_runs`
  - `import_run_id`
  - `restaurant_id`
  - `mode` such as `fixture_backfill`, `fixture_replay`, `live_poll`, `live_webhook`
  - `started_at`
  - `completed_at`
  - `status`
  - `cursor_json`
  - `error_summary`
- `raw_import_records`
  - `raw_import_id`
  - `import_run_id`
  - `restaurant_id`
  - `source_type`
  - `source_entity_type`
  - `source_entity_id`
  - `payload_hash`
  - `business_date`
  - `received_at`
  - `status`
  - `payload_json`
  - `error_summary`
- `sync_watermarks`
  - `restaurant_id`
  - `source_type`
  - `watermark_type`
  - `watermark_value`
  - `updated_at`

### Canonical Operational Layer

- `open_shift_snapshots`
  - `restaurant_id`
  - `business_date`
  - `week_id`
  - `day_label`
  - `daypart`
  - `status`
  - current covers, sales, hours, labor dollars
  - source metadata
  - `last_event_at`
  - `updated_at`
- `shift_records`
  - `restaurant_id`
  - closed shift facts
  - locked historical target fields or `target_profile_version_id`
  - source metadata
  - `closed_at`
- `week_rollups`
  - `restaurant_id`
  - `week_id`
  - aggregate closed-week metrics
  - rollup status
  - `updated_at`
- `history_pattern_inputs`
  - `restaurant_id`
  - closed shift references or derived fields needed for Learn/History queries

### Target / Baseline Layer

- `baseline_builds`
  - `baseline_build_id`
  - `restaurant_id`
  - rolling window start/end
  - eligible shift count
  - derived target metrics
  - OPZ bounds
  - build reason
  - `built_at`
- `active_target_profiles`
  - `target_profile_id`
  - `restaurant_id`
  - `source_type`
  - active target metrics
  - OPZ bounds
  - metadata
  - `built_at`
- `target_profile_versions`
  - `target_profile_version_id`
  - `restaurant_id`
  - full immutable snapshot of targets
  - `created_at`
- `baseline_selected_records`
  - selected manager override references
  - `restaurant_id`

## Repository Port Sketch

These are the app-facing data contracts the UI and use cases should converge on.

```text
RestaurantRepository
  - getActiveRestaurant()
  - saveRestaurantScope()

ImportRepository
  - startImportRun()
  - appendRawImportRecord()
  - completeImportRun()
  - getImportStatus()
  - getSyncWatermark()
  - updateSyncWatermark()

ShiftRepository
  - upsertOpenShiftSnapshot()
  - removeOpenShiftSnapshot()
  - saveClosedShift()
  - listCurrentWeekShifts()
  - listClosedShiftsInWindow()

WeekRepository
  - getCurrentWeekState()
  - upsertWeekRollup()
  - listHistoricalWeeks()

TargetProfileRepository
  - getActiveTargetProfile()
  - saveTargetProfileVersion()
  - setActiveTargetProfile()
  - listTargetProfileHistory()

BaselineRepository
  - buildBaseline()
  - saveBaselineBuild()
  - getCurrentBaselineBuild()
  - saveManagerOverrideSelection()
```

## Application Use Case Sketch

The repo should evolve toward explicit use cases like these:

- `OnboardRestaurantUseCase`
  - creates restaurant scope
  - saves connector mappings
  - kicks off initial backfill
- `RunInitialBackfillUseCase`
  - pulls 60-day history plus current week
  - writes raw import and canonical rows
- `SyncIntradayUpdatesUseCase`
  - refreshes live shift/current-week state
- `FinalizeShiftUseCase`
  - turns final vendor data into one canonical closed shift
  - locks historical targets
  - updates week rollups
- `RebuildBaselineUseCase`
  - rebuilds the rolling 60-day baseline from eligible closed shifts
- `RefreshActiveTargetProfileUseCase`
  - updates active targets from baseline or manager override
- `ApplyManagerOverrideUseCase`
  - saves override selection and refreshes the active profile
- `GetShiftDashboardQuery`
  - builds a shift dashboard read model from open/current state plus targets
- `GetCurrentWeekQuery`
  - builds current-week variance read models
- `GetHistoricalTeachingQuery`
  - builds History and Learn query results

Future Phase 9 use cases should include:

- `AuthenticateRestaurantUserUseCase`
  - authenticates with the app-managed restaurant credential set
- `ProvisionRestaurantUserUseCase`
  - creates onboarding-time restaurant users and credentials
- `MapVendorIdentityUseCase`
  - optionally links app users to vendor employee identities when useful for reconciliation
- `AuthorizeRestaurantActionUseCase`
  - checks whether the current role can perform an action such as override
- `ManageRestaurantUsersUseCase`
  - creates or updates users, roles, and permission links from the Admin screen

Future Phase 10 use cases should include:

- `SyncSharedMutationUseCase`
  - propagates shared restaurant state changes across devices

Future Phase 11 use cases can stay brief for now, for example:

- `GetCorporateOverviewQuery`
  - aggregates restaurant-scoped truth into cross-store reporting
- `AuthorizeCorporateActionUseCase`
  - checks corporate-level visibility and admin permissions without changing restaurant-level truth rules

## Future Multi-Device Shared State

This is not part of the immediate Phase 7.5 or Phase 8 execution target, and it should be treated as future Phase 10 rather than being mixed into restaurant login.

Target future behavior:

- one restaurant or location
- multiple installed devices
- restaurant-scoped login
- role-based permissions
- shared manager override and shared settings across devices

Recommended login experience:

- `restaurant id -> username -> password`

Recommended implementation split:

- authentication proves who the user is
- identity mapping connects that person to one `RestaurantUser`
- authorization decides what the user can do in this app

Important rule:

- the app should own restaurant login directly
- onboarding should create app credentials that mirror the restaurant's POS-style username and role conventions
- app passwords or temporary credentials should not depend on vendor credential reuse
- app authentication and authorization should both remain app-owned

- local SQLite can cache and project shared state on each device
- local SQLite alone cannot be the only authority if overrides must propagate across devices

Expected long-term write path:

```text
user action on device
-> permission check
-> local use case writes optimistic local state if allowed
-> enqueue shared mutation
-> remote restaurant authority accepts and versions the change
-> other devices pull or receive the new shared state
-> each device updates local SQLite and provider-backed app state
```

If the first live rollout truly needs cross-device shared override behavior, that shared authority should become a dedicated follow-on phase rather than being hidden inside local Phase 8 adapter work.

Recommended future roles:

- `Supervisor`
  - view all operational data
  - cannot apply override
- `Manager`
  - view all operational data
  - can apply override
- `OwnerAdmin`
  - view all operational data
  - can manage users, roles, permissions, and identity mappings

Recommended future admin-screen responsibilities:

- user management
- role assignment
- permission editing
- vendor identity mapping
- audit review

## Future Corporate / Franchise Layer

This is a later future phase and can stay lightweight for now.

Guiding rules:

- restaurant id remains the truth boundary for operational records
- baselines, targets, overrides, and close-shift truth stay restaurant-scoped
- corporate structure should layer above restaurant truth, not flatten it

Likely future concepts:

- `CorporateOrganization`
- `CorporateUser`
- `StoreMembership`
- `CorporatePermissionSet`
- cross-store read models and reporting queries

## Implementation Status Enums

These statuses should become explicit values in the app rather than implied behavior.

### Import Status

- `queued`
- `running`
- `completed`
- `completed_with_warnings`
- `failed`

### Shift Lifecycle

- `open`
- `pending_finalization`
- `closed_final`
- `reconciled`

### Target Source Mode

- `system_baseline`
- `manager_override`

### Data Freshness

- `fresh`
- `stale`
- `partial`
- `empty`
- `failed`

## New Core Concepts To Add

### 1. ActiveTargetProfile

Purpose:

- Replace direct app-wide reads of `BaselineData`
- Represent the targets the app is using right now

Suggested fields:

- profileId
- sourceType: `system_baseline` or `manager_override`
- targetCPLH
- targetSPLH
- targetPPA
- fohWage
- bohWage
- opzFloorCPLH
- opzCeilingCPLH
- theoreticalFohLaborPct
- theoreticalBohLaborPct
- theoreticalLaborPct
- builtAt
- baselineWindowMetadata
- managerSelectionMetadata

### 2. BaselineBuild

Purpose:

- Represent the system-built rolling baseline independent of the active override layer

Suggested fields:

- eligibleShiftCount
- rollingWindowStart
- rollingWindowEnd
- derived target metrics
- daypart target covers
- OPZ bounds
- build reason
- build timestamp

### 3. Import Tracking

Purpose:

- Support fixture replay and future vendor debugging

Suggested concepts:

- `ImportRun`
- `RawImportRecord`
- `ImportSourceType`
- `ImportStatus`
- `ImportCursor` or sync watermark metadata
- `ImportDeduplicationKey`

### 4. Restaurant Scope

Purpose:

- Make canonical app truth scalable beyond a single implicit restaurant

Suggested concepts:

- `RestaurantScope`
- `restaurantId` or `locationId`
- source business timezone metadata

### 5. Locked Historical Target State

Purpose:

- Preserve historical truth when active targets change later

Suggested concepts:

- `LockedTargetSnapshot`
- `TargetProfileVersion`
- `targetProfileId`

### 6. Open and Future State Models

Purpose:

- Stop using screen constants for in-flight and projected state

Suggested concepts:

- `ProjectedShiftInput`
- `OpenShiftSnapshot`
- `CurrentWeekState`

### 7. ConnectorCapabilityProfile

Purpose:

- make vendor assumptions explicit before adapter work starts

Suggested concepts:

- auth mode
- sandbox support
- location lookup and external-location mapping
- backfill window support
- webhook vs polling support
- explicit finalization support
- rate-limit notes
- known field gaps and fallback plan

### 8. SourceOwnershipPolicy

Purpose:

- define which system owns each canonical field

Suggested concepts:

- POS-owned fields
- labor-owned fields
- app-owned derived fields
- field precedence when sources overlap

### 9. Future Shared Restaurant State

Purpose:

- leave a clean path for restaurant login, permissions, and cross-device shared settings later

Suggested concepts:

- `RestaurantUser`
- `RolePermissionSet`
- `DeviceInstallation`
- `SharedMutation`
- audit metadata such as `updatedByUserId`
- `VendorIdentityLink`
- `UserSession`

## Repo-Wide Refactor Targets

### Composition Root

- `lib/main.dart`
  - Keep as the composition root.
  - Move provider setup toward repository and use-case wiring instead of direct static/demo choices.

### Canonical Domain Layer

- Keep and strengthen:
  - `lib/domain/models/closed_shift_input.dart`
  - `lib/domain/models/target_snapshot.dart`
  - `lib/domain/models/shift_fact.dart`
  - `lib/domain/services/target_snapshot_builder.dart`
  - `lib/domain/services/shift_fact_builder.dart`
- Add repository interfaces in `domain/repositories/`.
- Add explicit restaurant scope in canonical models.
- Keep `lib/services/labor_model.dart` as a domain-level pure formula service, or move it under `domain/services/`.

### Data / Infrastructure Split

- `lib/data/database_helper.dart`
  - Split into:
    - SQLite database bootstrap
    - shift DAO
    - week DAO
    - baseline-selection DAO
    - import-run DAO
    - raw-import DAO
    - target-profile DAO
    - seed/import helpers
- `lib/data/shift_service.dart`
  - Split into:
    - close-shift use case
    - week rollup query/use case
    - history pattern query/use case
    - import replay orchestration where appropriate
- `lib/data/baseline_manager_service.dart`
  - Move toward an application use case built on repositories and target-profile services.
- `lib/data/shift_data_source.dart`
  - Keep temporarily as a bridge.
  - Long term, replace with query services and repositories rather than one broad data-source interface.

### Fixture Material

- `lib/data/demo_data.dart`
  - Keep as fixture source material only.
  - Move under an infrastructure fixtures area.
  - Do not let production screens import it directly.
- `lib/data/meridian_data.dart`
  - Split aggressively:
    - restaurant config
    - fixture demo snapshot content
    - lever copy/content
    - baseline and OPZ calculation services
    - schedule defaults
    - active target profile state

### App Models and Read Models

- `lib/models/shift_record.dart`
  - Decide whether this remains a canonical operational persistence model or becomes a SQLite row model.
  - If it stays canonical, create a separate row mapper for SQLite.
  - Ensure closed records carry locked historical target truth, either inline or by durable reference.
  - Add restaurant scope.
- `lib/models/week_data.dart`
  - Remove direct imports of `BaselineData` and `MeridianConfig`.
  - Either:
    - inject an `ActiveTargetProfile`, or
    - compute through a query service before constructing the read model.
- `lib/models/week_record.dart`
  - Same refactor as `WeekData`.
  - Historical target-hour displays must come from locked historical target context, not current active targets.
- `lib/models/baseline_candidate_shift.dart`
  - Fine as a read model for the manager flow.
- `lib/models/history_pattern_record.dart`
  - Fine as a derived history-teaching input model.

### In-Memory App State

- `lib/data/week_data_notifier.dart`
  - Keep as shared query state, but have it read from repositories/use cases instead of broad data-source abstractions over time.
- Add future state holders such as:
  - `ShiftDashboardNotifier`
  - `ActiveTargetProfileNotifier`
  - `CurrentWeekNotifier`
  - `ImportStatusNotifier`
  - `OpenShiftNotifier`

Expected ownership:

- `ShiftDashboardNotifier`
  - exposes live/current shift UI state
- `ActiveTargetProfileNotifier`
  - exposes the current effective target profile and source mode
- `CurrentWeekNotifier`
  - exposes WTD and projected week state
- `ImportStatusNotifier`
  - exposes last sync, replay mode, stale or failed state
- `OpenShiftNotifier`
  - exposes currently open daypart/service records

### Screens and Widgets

- `lib/screens/shift_dashboard.dart`
  - Replace static `ShiftSnapshot` and `ShiftMetrics` reads with query state from providers/notifiers.
- `lib/widgets/zone_status_card.dart`
  - Feed current shift facts from provider state, not static snapshot constants.
- `lib/screens/variance_report.dart`
  - Keep WTD and History paths.
  - Replace Full Week direct reads of `DemoData.currentWeekShifts` with repository-backed current-week state.
- `lib/screens/settings_screen.dart`
  - Split actions clearly:
    - import fixture bundle
    - reseed fixtures
    - clear canonical data
    - clear target state
    - inspect import status
- `lib/screens/baseline_tracker.dart`
  - Keep as the source-of-truth tab for target visibility, but point it at `ActiveTargetProfile` and `BaselineBuild` rather than a static global.
- `lib/screens/schedule_builder.dart`
  - Use active target profile from app state rather than direct static reads.
- `lib/screens/week_detail_screen.dart`
  - Ensure historical numbers come from locked snapshots or derived historical records, not active target globals.

## Tab Read Contracts

At implementation time, each tab should have a narrow read contract.

- Shift
  - `OpenShiftSnapshot`
  - `ShiftDashboardReadModel`
  - `ActiveTargetProfile`
- Variance -> This Week
  - `CurrentWeekState`
  - `ActiveTargetProfile`
- Variance -> Full Week
  - current-week repository query returning closed + open/projected shifts
- Variance -> History
  - `WeekRollup` records with locked target context
- Learn
  - historical pattern query output built from closed shifts
- Schedule
  - forecast input state
  - `ActiveTargetProfile`
  - optional current import freshness state
- Baseline
  - `BaselineBuild`
  - `ActiveTargetProfile`
  - manager override metadata
- Settings
  - `ImportStatus`
  - replay/import actions
  - clear/reset actions separated by layer

### Presentation-Only Assets

- `lib/theme/app_theme.dart`
  - Fine to remain presentation-only.
- `lib/utils/formatters.dart`
  - Fine to remain presentation-only.
- `lib/widgets/daypart_table.dart`
  - Fine once fed from repository-backed read models.
- `lib/widgets/input_metric_card.dart`
  - Fine once fed from repository-backed read models.
- `lib/widgets/lever_card.dart`
  - Fine; move lever copy source away from giant mixed data files.
- `lib/widgets/schedule_day_row.dart`
  - Fine.
- `lib/widgets/source_quote_block.dart`
  - Fine and optional.
- `lib/widgets/variance_banner.dart`
  - Already close to the target direction because it reads shared state.
- `lib/widgets/week_history_tile.dart`
  - Fine once fed from repository-backed history queries.

## Execution Waves

### Wave 0 - Protect Current Scope

Goal:

- Finish Phases 5 to 7 without making Phase 7.5 harder.

Rules:

- Do not add new production reads of `DemoData`, `ShiftSnapshot`, or similar screen constants.
- Prefer provider/query boundaries when touching data flow.
- Do not use mixed demo-backed screens as the only proof that target propagation works.
- When finishing Phase 5 or Phase 6, require prompts to call out:
  - what logic is being verified
  - which surfaces are trusted proof now
  - which surfaces remain mixed until Phase 7.5

### Wave 1 - Introduce New Contracts Without Breaking UI

Goal:

- Add the missing abstractions while keeping current screens working.

Actions:

- Add `ActiveTargetProfile`
- Add `BaselineBuild`
- Add repository interfaces
- Add import-run tracking concepts
- Add restaurant scope concepts
- Add locked historical target contracts
- Add a temporary compatibility layer where needed

### Wave 2 - Separate Persistence Responsibilities

Goal:

- Remove the `DatabaseHelper` bottleneck.

Actions:

- Extract DAOs
- Extract repository implementations
- Move seeding helpers out of raw DB bootstrap
- Add storage for raw imports and target-profile metadata
- Add restaurant-scoped persistence columns
- Add historical target snapshot or target-profile version persistence

### Wave 3 - Remove Static Global Target Reads

Goal:

- Make app models and screens depend on target-profile state, not `BaselineData`.

Actions:

- Refactor `WeekData`
- Refactor `WeekRecord`
- Refactor schedule computations
- Introduce an active-target provider/notifier
- Stop historical views from deriving targets from current globals

### Wave 4 - Remove Screen-Owned Demo Truth

Goal:

- Make fixtures enter through import/replay paths instead of widget constants.

Actions:

- Replace `ShiftSnapshot` usage
- Replace `ShiftMetrics` usage
- Replace `DemoData.currentWeekShifts` usage in production surfaces
- Route fixture material through repository-backed state
- Introduce explicit open/current-state models where screens currently have no backing app state

### Wave 5 - Fixture Replay Harness

Goal:

- Prove the app can run like a live system before Phase 8.

Actions:

- Define fixture formats that resemble POS and labor payloads
- Add import/replay use cases
- Persist imported results into SQLite
- Persist raw import records and import-run metadata
- Support replay modes:
  - historical-only
  - partial current week
  - intraday updates
  - close-shift replacement
  - manager override applied or cleared

### Wave 6 - Alignment Audit and Readiness Sign-Off

Goal:

- Close the Phase 7.5 gate.

Actions:

- Trace every major UI number
- Classify each object as:
  - source fact
  - canonical normalized fact
  - derived baseline/target state
  - locked historical snapshot
  - fixture-only compatibility data
  - legacy demo-only UI state
- Remove or quarantine anything still in the wrong bucket

## Implementation Flow Sketches

### Finalize Shift Flow

```text
receive final vendor data
-> load active restaurant scope
-> load current active target profile
-> create immutable target-profile version or locked snapshot
-> map vendor data to ClosedShiftInput
-> build ShiftFact
-> transaction:
   - mark related raw import records applied
   - remove or supersede matching open shift snapshot
   - upsert closed shift record
   - update week rollup
   - persist locked target truth
-> if eligible history changed:
   - rebuild baseline
   - refresh active target profile when no manager override is active
-> notify current-week, shift, baseline, and import-status state
```

### Onboarding / Initial Backfill Flow

```text
create restaurant scope
-> save connector config
-> start import_run(initial_backfill)
-> fetch 60-day closed history
-> fetch current-week open/projected state
-> persist raw import records
-> map to canonical records
-> write closed history
-> write open/current state
-> build baseline
-> set active target profile
-> mark onboarding complete
-> expose last successful sync
```

## Validation Requirements

Before Phase 8 starts, the repo should prove:

- imported fixture bundles can drive Baseline, Schedule, Shift, Variance, History, and Learn
- no production screen requires direct screen-level demo constants for truth
- target profile changes update open and future state immediately
- historical closed-shift views do not rewrite when overrides change later
- close-shift ingest still locks targets at close time
- historical target truth is explicitly persisted
- canonical records are restaurant-scoped
- raw import runs, dedupe, and import-status records exist
- first-target vendors have written capability profiles and source-ownership rules
- the app can clearly surface:
  - no data
  - partial data
  - stale data
  - import failed
  - fixture mode

## Concrete Readiness Checks

- `shift_dashboard.dart` reads provider-backed live or replayed shift state
- `zone_status_card.dart` reads provider-backed live or replayed shift state
- `variance_report.dart` Full Week reads repository-backed current-week state
- `settings_screen.dart` can distinguish fixture import from hard reset
- `week_data.dart` and `week_record.dart` no longer pull active targets from static globals
- `DatabaseHelper` is no longer the place where raw DB bootstrapping, seed logic, and app behaviors all meet
- closed historical records have durable target truth
- canonical persistence carries restaurant scope
- raw import and import-status storage exists

## First Implementation Steps

When Phase 7.5 begins, start here:

1. Extract `ActiveTargetProfile` and make it the explicit target source.
2. Define restaurant scope and add it to canonical contracts before adapter work begins.
3. Split `DatabaseHelper` into DB bootstrap plus DAOs/repositories.
4. Persist locked historical target truth for closed records.
5. Remove `BaselineData` reads from `WeekData`, `WeekRecord`, and schedule calculations.
6. Replace `ShiftSnapshot` / `ShiftMetrics` with provider-backed shift state.
7. Replace `DemoData.currentWeekShifts` reads in Variance Full Week.
8. Add fixture import and replay plumbing that writes both raw-import and canonical SQLite layers.
9. Run the post-Phase-7 audit and classify every major visible number.

Recommended prompt breakdown for execution:

1. `Prompt 7.5a`
   - restaurant scope
   - repository interfaces
   - SQLite split
   - raw import tables
2. `Prompt 7.5b`
   - active target profile extraction
   - locked historical target persistence
   - remove static global target reads
3. `Prompt 7.5c`
   - open/current-state models
   - remove screen-owned demo truth
   - fixture replay and readiness audit
4. `Prompt 8.1`
   - restaurant onboarding flow
   - location setup
   - connector mapping/auth
5. `Prompt 8.2`
   - initial 60-day backfill
   - baseline bootstrap
6. `Prompt 8.3`
   - continuous sync
   - live shift updates
   - close/finalization handling
   - rolling 60-day maintenance

## Non-Goals During This Refactor

- Do not redesign target math.
- Do not build vendor-specific optimizations yet.
- Do not let adapter DTOs leak into widget code.
- Do not rewrite the app in one giant move.

## Success Definition

This refactor is complete when:

- the app runs end to end from imported fixture bundles
- the active target profile is explicit and traceable
- persistence is cleanly separated
- screen-owned demo truth is gone from production flows
- historical target truth is stable and reconstructable
- canonical records are restaurant-scoped
- raw import and replay behavior is traceable
- Phase 8 can focus on vendor connectors without changing screen logic
