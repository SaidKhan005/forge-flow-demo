# Forge & Flow Project Tracker

Updated: 2026-03-30
Owner: You
Execution model: We think, Claude codes
Archive: `PROJECT_TRACKER_ARCHIVE.md`

## North Star

POS + Labor Systems -> Canonical Shift Facts -> Baseline -> Targets -> Schedule -> Shift -> Variance -> Learn

## Product Split

- This Week = diagnose what lever matters first right now
- History = teach what leaks repeat over time
- Learn = summarize recurring leaks, benchmarks, and repeatable wins

## Active Focus

- Current phase: Phase 7 complete; Phase 7.5 alignment gate next
- Current prompt: Prompt 7.5a - Persistence and scope alignment
- Current goal: begin persistence and scope alignment so fixture-replay and live-adapter work can run from canonical app truth instead of screen-owned demo inputs
- Current live-integration scope: one restaurant or location, not multi-location org management
- Do not drift into: live adapters, restaurant auth/sync work, or new target math beyond selection-driven baseline updates
- Planned pre-Phase-8 gate: Phase 7.5 - Data Alignment, Decoupling, and Fixture Replay Readiness
- Baseline naming freeze: keep internal and visible Baseline naming unchanged during this stabilization pass
- Completed prompt history, detailed progress notes, and older decision history now live in `PROJECT_TRACKER_ARCHIVE.md`

## Phase Roadmap

- [x] Prompt 0 - Software engineering plan
- [x] Phase 1 - Foundation
  Add canonical domain models for raw closed-shift input, target snapshots, and normalized shift facts.
- [x] Phase 2 - History From Real Facts
  Replace seeded teaching inputs with history derived from real tracked closed shifts.
- [x] Phase 3 - Close Shift / Ingest Path
  Implement the real shift-close pipeline from raw input to stored facts and week rollups.
- [x] Phase 4 - Target Consistency + OPZ
  Finish remaining target cleanup and address OPZ ceiling issues using Jim Taylor Chapter 11.
- [x] Phase 5 - Baseline Manager From History
  Make baseline shift selection visible and powered by tracked historical data.
- [x] Phase 6 - Variance Visual Overhaul
  Redesign Variance so a manager can see the top weekly lever and daypart drivers instantly.
- [x] Phase 7 - Learn Layer
  Build benchmark and recurring-pattern teaching beyond History.
- [ ] Phase 7.5 - Data Alignment + Decoupling + Fixture Replay
  Run the post-Phase-7 alignment pass so imported fixture bundles can drive the app end to end without screen-owned demo truth.
- [ ] Phase 8 - Live POS + Labor Adapters
  Add connectors that feed the canonical input model for one restaurant/location after the Phase 7.5 readiness gate passes.
- [ ] Phase 9 - Restaurant Auth + Login
  Add restaurant-scoped login, onboarding-created credentials, roles, permissions, and Admin user control.
- [ ] Phase 10 - Shared Multi-Device Sync
  Add cross-device shared restaurant state so actions like manager override propagate across all devices for that restaurant.
- [ ] Phase 11 - Corporate / Franchise Layer
  Add a brief future placeholder for multi-store hierarchy, corporate permissions, and cross-store visibility above the restaurant-level truth boundary.

## Immediate Watchlist

- [ ] Minor Baseline Manager label-casing cleanup can wait and does not block stabilization
- [ ] Late-night override path is logic-supported; only add stronger real-history proof later if closed late-night records exist without adding new demo data
- [ ] User bug review should finish before Phase 7.5 starts
- [ ] The post-Phase-7 alignment pass must remove remaining screen-owned demo truth before any live adapter work begins
- [ ] Phase 7.5 must explicitly add persisted historical target truth, restaurant scope, and raw import tracking before adapter work starts
- [ ] Cross-device shared override behavior cannot rely on local SQLite alone; plan restaurant-scoped auth and sync as a later explicit phase

## Stabilization Sequence

### Prompt 7.11 - Shift Dynamic Truth Alignment

Status: Done

- Shift hero-card emphasis now follows the runtime active lever
- Shift bottom teaching line now follows the same runtime active lever
- supporting display cleanup landed in Prompt 7.12

### Prompt 7.12 - Shift Readability + OPZ Presentation Polish

Status: Done

- increase readability of top Shift labels and key headers
- improve OPZ gauge composition, including wider visual green-zone treatment and clearer target-label placement
- add a clearer `Labor % Variance` header and tighten theoretical vs actual spacing/layout
- improve card arrangement, visual emphasis of the main issue, and action/teaching container presentation
- keep Shift truth aligned to the runtime active lever from Prompt 7.11

### Prompt 7.13 - Variance Coaching Layout Cleanup

Status: Done

- rename the main WTD table heading to benchmark language
- remove repeated or low-value wording such as duplicate dollar-gap labeling and noisy footnotes
- replace `Inputs / Outputs` grouping with:
  - Conditions
  - Execution
  - Outcomes
- move PPA into Execution for coaching clarity
- relabel the second table toward full-week projection language
- improve contrast/readability issues in History and simplify low-value labels like faint side badges if they add no teaching value
- keep dollar-impact sign/color handling consistent with existing over-model vs under-model conventions

### Prompt 7.14 - Learn Depth From Structured Teaching Sources

Status: Done

- Learn now teaches both recurring leaks and repeatable wins from structured analyzer outputs plus existing lever-card content
- benchmark-pattern identity now flows from History summaries into Learn without adding UI-authored teaching prose
- deeper Learn cards landed while keeping This Week and History behavior unchanged

### Prompt 7.15 - History + Learn Premium Surface Alignment

Status: Done

- History tab, week-history list, and tapped week-detail screens now use the same premium Variance family language as This Week
- historical week drill-in no longer relies on the old flat summary table as its main treatment and now uses grouped premium table structure
- Learn presentation now feels in-family with This Week without changing analyzer-owned or lever-card-owned teaching content

### Prompt 7.15a - History Drill-In Dollar-Impact Sign Fix

Status: Done

- fixed the annualized sign-formatting inconsistency in the History drill-in `DOLLAR IMPACT` card
- kept all 7.15 table and styling changes intact

## Trusted vs Mixed Surfaces Until 7.5

Trusted proof surfaces during stabilization:

- tests
- baseline manager preview and persistence behavior
- Baseline tab
- Schedule tab
- WTD views reading shared week state

Treat these as mixed and non-authoritative until Phase 7.5 removes their demo-owned inputs:

- Shift
- Zone status hero
- Variance Full Week
- any history surface still comparing against current active globals

## Pre-Phase-8 Alignment Gate

This is a required gate between Phase 7 and Phase 8.

- Complete the stabilization sequence first
- Run the data-alignment and decoupling pass documented in `REFACTOR_AND_DECOUPLING.MD`
- Validate with fixture replay that mimics future POS and labor feeds
- Start Phase 8 only after the app can run end to end from imported fixture bundles without direct screen-level demo constants

## Phase 7.5 Implementation Contract

Phase 7.5 is not a vague cleanup pass. It should land concrete implementation boundaries.

- Add restaurant or location scope to canonical models and persistence
- Split SQLite responsibilities into:
  - raw import layer
  - canonical operational layer
  - target/profile layer
- Persist locked historical target truth for closed shifts
- Extract explicit active target profile state
- Introduce open/current-state models for Shift and current-week surfaces
- Remove screen-owned demo truth from production flows
- Add import-run, raw import, dedupe, and import-status tracking
- Prove the app can run end to end from replayed fixtures before any live vendor transport work begins

Minimum implementation targets:

- `restaurant_locations`
- `connector_configs`
- `import_runs`
- `raw_import_records`
- `sync_watermarks`
- `open_shift_snapshots`
- `shift_records`
- `week_rollups`
- `baseline_builds`
- `active_target_profiles`
- `target_profile_versions` or equivalent locked-target persistence
- provider-backed state for Shift, current week, targets, and import status

## Working Prompt Tracker

Completed prompt history was moved to `PROJECT_TRACKER_ARCHIVE.md`.

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 7.12 | Shift readability + OPZ presentation polish | Done | Shift readability, OPZ teaching widget, and labor-variance strip polished on top of the runtime truth pass |
| Prompt 7.13 | Variance coaching layout cleanup | Done | WTD grouping/wording cleaned up, duplicate dollar wording removed, and dollar-impact sign handling kept consistent |
| Prompt 7.14 | Learn depth from structured teaching sources | Done | Learn now carries benchmark-pattern teaching depth using structured analyzer outputs plus existing lever-card content |
| Prompt 7.15 | History + Learn premium surface alignment | Done | History drill-ins now use the newer grouped premium table system and Learn/History styling now matches the upgraded This Week surface |
| Prompt 7.15a | History drill-in dollar-impact sign fix | Done | Fixed annualized sign formatting in the History detail `DOLLAR IMPACT` card without reopening the broader 7.15 pass |
| Prompt 7.5a | Persistence and scope alignment | Next | Add restaurant scope, split DB responsibilities, and introduce raw import tracking plus repository interfaces |
| Prompt 7.5b | Target-state alignment | Planned | Persist locked historical target truth, extract active target profiles, and remove current-global target reads from historical flows |
| Prompt 7.5c | Live-state and replay alignment | Planned | Replace screen-owned demo truth, add open/current-state models, and prove fixture-replay end-to-end behavior |
| Prompt 8.1 | Restaurant onboarding + connector setup | Planned | Create location setup flow, connector mappings, and auth/validation paths |
| Prompt 8.2 | Initial 60-day backfill + baseline bootstrap | Planned | Pull the restaurant's initial historical window and build baseline/targets from canonical records |
| Prompt 8.3 | Continuous live sync + close/finalization | Planned | Keep live shift state fresh, finalize shifts correctly, update weekly state, and maintain the rolling 60-day baseline |
| Prompt 9.1 | Restaurant identity + role model | Future | Define restaurant users, roles, permissions, and identity-link contracts |
| Prompt 9.2 | Login + admin user control | Future | Add restaurant login UX, onboarding-created app credentials, and admin-side permission management |
| Prompt 10.1 | Shared sync + audit | Future | Propagate overrides/settings across devices and track who changed what and when |
| Prompt 11 | Corporate / franchise layer | Future | Add org hierarchy and cross-store visibility while keeping restaurant id as the operational truth boundary |

## Future Execution Blocks

### Prompt 8.1 - Restaurant Onboarding + Connector Setup

- create restaurant scope
- save location metadata and timezone
- map vendor location ids
- validate connector auth and connectivity

### Prompt 8.2 - Initial 60-Day Backfill + Baseline Bootstrap

- pull at least 60 days of closed history
- pull current-week open/projected state
- persist raw import data and canonical records
- build baseline and active target profile

### Prompt 8.3 - Continuous Sync + Live/Close Maintenance

- keep live shift state fresh
- finalize closed shifts correctly
- update week rollups
- maintain the rolling 60-day baseline

### Prompt 9.1 - Restaurant Identity + Role Model

- add restaurant-scoped user accounts and identity links
- define role levels such as supervisor, manager, and owner or operator admin
- define permission rules such as manager-only override access
- make onboarding seed the initial restaurant users and role assignments
- keep app authentication and authorization app-owned

### Prompt 9.2 - Login + Admin User Control

- implement login UX as `restaurant id -> username -> password`
- create app credentials during onboarding using the same username style and role setup as the restaurant's POS workflow
- support restaurant-managed app passwords or temporary credentials rather than depending on vendor credential reuse
- add admin-screen user control for roles, permissions, and identity mappings

### Prompt 10.1 - Shared Sync + Audit

- make restaurant-scoped overrides and settings propagate across installed devices
- keep local SQLite as the device cache rather than the only shared authority
- add audit metadata such as who changed what and when
- surface sync freshness, failures, and permission errors truthfully

### Prompt 11 - Corporate / Franchise Layer

- add organization or franchise hierarchy above restaurant scope
- keep restaurant id as the truth boundary for operational records, baseline, targets, and overrides
- add corporate-level read models, permissions, and cross-store visibility without flattening restaurant-level truth

## Blockers

- No active blockers

## Risks To Watch

- Demo-shaped logic spreading into permanent architecture
- Derived metrics being treated like source facts
- Weekly summaries hiding daypart truth
- OPZ target drifting too close to the ceiling
- UI changes happening before domain contracts stabilize
- Waiting too long to unwind demo-owned screen truth during stabilization could make Phase 7.5 wider and riskier than it needs to be
- If locked target snapshots are not persisted before Phase 8, historical views can drift when active targets change
- If restaurant scope is not added before adapters, single-store assumptions will leak into canonical models and persistence
- If raw import, dedupe, and import-status tracking are skipped, Phase 8 will force transport concerns into app logic
- If close/finalization rules are not explicit, live data can be promoted into history too early and poison the rolling 60-day baseline
