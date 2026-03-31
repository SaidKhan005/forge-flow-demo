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

## Current Data Truth Clarification

- The app is not connected to a live POS or labor vendor yet.
- Current visible app data still comes from fixture, replay, or demo-seeded input.
- That input now flows through the same internal app-side path that live vendor data is expected to use:
  - canonical models
  - SQLite persistence
  - app state, providers, and notifiers
  - UI
- This means the internal architecture is ready for live adapters even though transport is still fixture or replay backed.
- Phase 8 should replace transport with live vendor feeds, not create a second UI-facing truth path.

## Active Focus

- Current phase: Phase 7.52 cleanup + private build + Barrio shell preparation
- Current prompt: Prompt 7.52d - private Barrio boundary
- Current goal: create the internal Barrio layer inside the same repo for private docs, assets, routes, and future content without forking core Forge & Flow logic
- Phase 7.5a status: complete
- Phase 7.5b status: complete
- Phase 7.5c status: complete
- Phase 7.51d status: complete
- Phase 7.51e status: complete - 28-file corpus rerun passed (re-verified post-7.52c: 28/28); Phase 8 blocked on vendor selection only
- Phase 7.52a status: complete
- Phase 7.52b status: complete
- Phase 7.52 status: current
- Phase 7.5 gate status: complete on the app side
- Phase 8 status: blocked on vendor selection only
- Current live-integration scope: one restaurant or location, not multi-location org management
- Do not drift into: multi-location org management, cross-device sync, or new target math beyond baseline-derived selection truth
- Baseline naming freeze: keep internal and visible Baseline naming unchanged during this alignment pass
- Completed prompt history, detailed progress notes, and older decisions now live in `PROJECT_TRACKER_ARCHIVE.md`
- Execution contract for `7.52` is locked in `docs/phase_7_52_execution_plan.md`

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
- [x] Phase 7.5 - Data Alignment + Decoupling + Fixture Replay
  Complete: persistence scope, locked target truth, and live/current-state replay-backed reads now align under repository-backed app state.
- [x] Phase 7.51 - Phase 8 App-Side Gate Closeout
  Complete on the app side: structural alignment is done, the 28-file Flutter corpus rerun passed, and the only remaining Phase 8 blocker is vendor selection.
- [ ] Phase 7.52 - Cleanup + Product Identity + Private Barrio Build
  Clean up repo naming and legacy files, establish Forge & Flow as the shared product identity, create the private Barrio build boundary, and build the Barrio shell plus structured internal content surfaces before Phase 9 auth.
- [ ] Phase 8 - Live POS + Labor Adapters
  Add connectors that feed the canonical input model for one restaurant/location after the Phase 7.51 readiness closeout passes.
- [ ] Phase 9 - Restaurant Auth + Login
  Add restaurant-scoped login, onboarding-created credentials, roles, permissions, and Admin user control.
- [ ] Phase 10 - Shared Multi-Device Sync
  Add cross-device shared restaurant state so actions like manager override propagate across all devices for that restaurant.
- [ ] Phase 11 - Corporate / Franchise Layer
  Add a future placeholder for multi-store hierarchy, corporate permissions, and cross-store visibility above the restaurant-level truth boundary.

## Phase 7.5 / 7.51 / 7.52 Status

- `7.5a` complete:
  - restaurant scope added to canonical persistence models and SQLite rows
  - SQLite bootstrap split from DAOs and repository implementations
  - additive migration/backfill path landed
  - fixture replay import-run and raw-import tracking landed
  - `DatabaseHelper` is now compatibility-only
- `7.5b` complete:
  - active target profile persistence landed
  - immutable target profile versions now lock closed-shift target truth
  - historical shift and week reads no longer depend on current-global target state
  - WTD models now consume explicit injected target state instead of reading `BaselineData` directly
- `7.5c` complete:
  - open/current-state persistence and read models landed
  - Shift and Zone status hero now read repository-backed current state instead of screen-owned demo truth
  - fixture replay can now drive aligned WTD, Shift, Full Week, History, and Learn read paths end to end
- post-`7.5` repo audit found the following `7.51` closeout items before Phase 8 can begin:
  - `variance_report.dart` closed-shift detail still reads current `BaselineData` targets instead of locked shift targets
  - `BaselineData` still drives app-shell rebuilds and several production active-target surfaces
  - written vendor capability profiles and source-ownership docs still need to be checked into the repo
  - final deterministic test/replay sign-off still needs to happen in a runnable Flutter environment
- post-7.51 verification found:
  - 7.51a verified complete: closed-shift Full Week detail reads locked target truth
  - 7.51b verified complete: app-shell authority moved off BaselineData.revision; remaining bridge usage frozen and documented
  - 7.51c verified complete: gate artifacts checked in; vendor profiles remain TBD
  - 7.51d verified complete: projected/open Variance uses active target profile; Shift empty-state renders truthfully; connector config persistence boundary exists; Clear All Data actually clears; Schedule visible surface uses injected targets; compatibility bridge scope frozen
  - a fresh repo-wide code audit verified the app is structurally ready for Phase 8 connector work
  - the tracked test corpus is now 28 test files, and the checked-in runner or manifest should be used for the next runnable Flutter proof pass
  - 7.51e verified complete: 28-file corpus rerun passed (28/28)
  - Phase 8 remains blocked on vendor selection only
- 7.52 current scope:
  - keep Forge & Flow as the shared product and keep the restaurant name runtime-scoped inside the app
  - treat current fixture or replay transport as unchanged while cleanup and private-build work proceeds
  - clean up repo, product identity, and legacy/demo-heavy file naming
  - move private Barrio-only docs and assets out of the shared product root
  - create a private Barrio layer inside the same repo without forking the core product
  - add the dual-build foundation so Forge & Flow and Barrio can become separate app identities from one codebase
  - build the Barrio shell and content surfaces before Phase 9 auth begins
  - prepare the repo to move into Phase 9 and Phase 10 cleanly while Phase 8 vendor work remains pending

## Phase 7.52 Breakdown

- `7.52a` tracker lock + scope:
  - freeze the naming contract:
    - Forge & Flow = shared product
    - restaurant display name = runtime restaurant scope
    - Barrio = private internal build identity
  - freeze the execution boundary:
    - 7.52 builds shell, structure, content, and branding
    - Phase 9 owns login, permissions, and real gating
    - Phase 10 owns cross-device shared state
- `7.52b` product identity + naming cleanup:
  - rename public product-facing package, module, and platform-visible strings away from `forge_flow_demo`, `Forge & Flow Demo`, and public `Barrio` naming
  - resolved hotspots included:
    - `pubspec.yaml`
    - `forge_and_flow.iml`
    - `README.md`
    - `android/app/src/main/AndroidManifest.xml`
    - `ios/Runner/Info.plist`
    - `windows/runner/Runner.rc`
    - `windows/runner/main.cpp`
    - `windows/CMakeLists.txt`
- `7.52c` legacy file + asset cleanup:
  - `meridian_data.dart` renamed to `legacy_fixture_data.dart`
  - `demo_data.dart` renamed to `fixture_seed_data.dart`
  - private Barrio root files moved into `docs/internal/barrio/` and `assets/internal/barrio/branding/`
  - all imports and doc references updated to new paths
- `7.52d` private Barrio boundary:
  - create a private Barrio layer inside the same repo for internal-only docs, assets, routes, and content
  - shared product logic must remain in Forge & Flow core
  - Barrio must not become a forked codebase
- `7.52e` dual-build foundation:
  - prepare Forge & Flow and Barrio as separate app identities from the same codebase
  - different app names, icons, and future build flavors are allowed here
  - no auth enforcement or vendor work belongs in this step
- `7.52f` Barrio shell + navigation:
  - build the private Barrio home shell
  - include destination entry points for:
    - Forge & Flow
    - Company Handbook
    - Interview Playbook
    - Jim Taylor Labor Model
    - Preston Lee Model (`Coming Soon`)
    - future supervisor-specific content area
- `7.52g` structured interactive content surfaces:
  - treat PDFs and source documents as source material, not as the final app experience
  - handbook, playbooks, and model content should be built as beautiful structured in-app surfaces
  - content should be navigable, role-aware in structure, and ready for later gating
- `7.52h` Phase 9 handoff:
  - allow role-aware information architecture or preview structure if useful
  - do not implement real login or permissions yet
  - stop 7.52 after the shell, content, and build boundaries are ready for Phase 9 auth
- `7.52a` completion note:
  - the Barrio shell vision, role-aware pre-auth structure, structured-content rule, and stop-point before Phase 9 are now locked in `docs/phase_7_52_execution_plan.md`
- `7.52b` completion note:
  - public product identity now reads as Forge & Flow across `pubspec.yaml`, the root IntelliJ module, README, Android, iOS, and Windows visible app strings
  - the default demo restaurant scope now uses a restaurant-style display name instead of the product name
  - the app title is now fixed to `Forge & Flow` instead of reading restaurant scope as the product identity
  - stale persisted restaurant scope records using `Forge & Flow Demo` now auto-normalize back to the demo restaurant display name
- `7.52c` completion note:
  - `meridian_data.dart` renamed to `legacy_fixture_data.dart` — all Dart imports and doc references updated
  - `demo_data.dart` renamed to `fixture_seed_data.dart` — all Dart imports and doc references updated
  - `Barrio Legado Business Plan.pdf` moved to `docs/internal/barrio/barrio_legado_business_plan.pdf`
  - `jim_taylor_labor_model_deep_dive.html` moved to `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`
  - `Logo.png` moved to `assets/internal/barrio/branding/logo.png`
  - all three files removed from repo root

## Immediate Watchlist

- Minor Baseline Manager label-casing cleanup remains non-blocking
- Late-night override path is logic-supported; only add stronger real-history proof later if closed late-night records exist without adding new demo data
- Cross-device shared override behavior cannot rely on local SQLite alone; plan restaurant-scoped auth and sync as a later explicit phase
- Baseline and Learn still rely on the documented `BaselineData` compatibility bridge (intentionally frozen)
- Phase 8 gate artifacts exist, but vendor capability profiles are still placeholders until the first POS and labor vendors are chosen
- Phase 8 is blocked on vendor selection only
- Phase 7.52 should not change core Phase 8 data contracts while cleanup and private-layer work is underway
- Barrio should be added as a private internal layer inside Forge & Flow, not as a forked customer product
- 7.52 should build role-aware structure only; real login and permission enforcement belongs to Phase 9
- private source documents such as handbook PDFs or deep-dive HTML files should become structured in-app experiences, not remain the final runtime UX
- Forge & Flow customer builds must not accidentally ship Barrio-private content
- Android internal package namespace and applicationId in `android/app/build.gradle.kts` still use `com.forgeflow.forge_flow_demo` — this is a future cleanup item, not a v1.1.0 blocker, but should be renamed before public distribution

## Trusted Surfaces Before Phase 8 Sign-Off

Trusted proof surfaces after the structural `7.5` work but before `7.51` is complete:

- tests
- baseline manager preview and persistence behavior
- Baseline tab for active-target propagation
- Schedule tab for active-target propagation
- WTD views reading shared week state
- historical week detail and stored week rollups reading locked target truth
- Shift
- Zone status hero
- Variance Full Week closed detail is now a trusted locked-target proof surface after `7.51a`
- Baseline, Schedule, and Learn are still useful for feature behavior, but they remain compatibility-bridge surfaces until `7.51d` closes or freezes that scope

## Pre-Phase-8 Alignment Gate

- Phase 7.5 structural work completed
- Phase 7.51a-c completed
- Fixture replay now drives the aligned app read surfaces without direct screen-level demo constants
- Variance Full Week closed detail and historical drill-ins use locked target truth
- Active target propagation no longer depends on `BaselineData.revision` as the app-wide authority
- Written vendor capability profiles and source-ownership docs exist for the first Phase 8 vendors
- First POS and labor vendors are selected and their capability profiles are filled in beyond `TBD`
- replay-readiness required scenarios are closed or explicitly accepted for Phase 8
- Current 28-file Flutter manifest rerun recorded in a runnable Flutter environment
- Start Phase 8 from connector onboarding and adapter transport work, not from another internal state-boundary rewrite

## Working Prompt Tracker

Detailed completed prompt history was moved to `PROJECT_TRACKER_ARCHIVE.md`.

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 7.5a | Persistence and scope alignment | Done | Restaurant scope, SQLite boundaries, additive migrations, raw import tracking, and compatibility delegation are now in place |
| Prompt 7.5b | Target-state alignment | Done | Active target profiles, immutable target-profile versions, locked historical target truth, and explicit WTD target injection are now in place |
| Prompt 7.5c | Live-state and replay alignment | Done | Open/current-state models now back Shift and Full Week, and fixture replay can drive the app read surfaces end to end |
| Prompt 7.51a | Historical truth closeout | Done | Closed-shift Full Week detail now reads locked shift targets, and closed-history rewrite risk is covered by code/test evidence |
| Prompt 7.51b | Active-target bridge containment | Done | App-shell authority moved off `BaselineData.revision`; remaining bridge usage is explicitly frozen as compatibility scope |
| Prompt 7.51c | Vendor readiness docs + gate evidence | Done | Gate artifacts are checked in, source ownership is documented, and the remaining vendor fields are explicitly placeholder-only until vendor choice |
| Prompt 7.51d | Compatibility-bridge retirement + pending-state closure | Done | Projected/open target drift, Shift empty-state truth, connector-config persistence, Clear All Data, and Schedule target authority are all closed |
| Prompt 7.51e | Vendor selection + current-corpus gate rerun | Done | 28-file corpus rerun passed; only remaining Phase 8 blocker is vendor selection |
| Prompt 7.52a | Tracker lock + Barrio shell execution plan | Done | Naming rules, phase boundaries, Barrio shell destinations, and the pre-Phase-9 content contract are locked in `docs/phase_7_52_execution_plan.md` |
| Prompt 7.52b | Product identity + naming cleanup | Done | Public product identity now reads as Forge & Flow across package, module, README, Android, iOS, Windows, the app title no longer reads restaurant scope as product identity, and stale `Forge & Flow Demo` restaurant scope rows auto-normalize |
| Prompt 7.52c | Legacy file + private asset cleanup | Done | Renamed `meridian_data.dart` to `legacy_fixture_data.dart`, `demo_data.dart` to `fixture_seed_data.dart`, moved private Barrio root files into `docs/internal/barrio/` and `assets/internal/barrio/branding/` |
| Prompt 7.52d | Private Barrio boundary | Current | Create the internal Barrio layer inside the same repo for private docs, assets, routes, and future content without forking core Forge & Flow logic |
| Prompt 7.52e | Dual-build foundation | Future | Prepare Forge & Flow and Barrio as separate app identities from one shared codebase with distinct branding and future flavor support |
| Prompt 7.52f | Barrio shell + navigation | Future | Build the Barrio internal shell and destination entry points for Handbook, Forge & Flow, Interview Playbook, Jim Taylor, Preston Lee, and future supervisor content |
| Prompt 7.52g | Structured interactive content surfaces | Future | Convert source documents into beautiful structured in-app handbook, playbook, and model experiences rather than raw embedded document viewers |
| Prompt 7.52h | Phase 9 handoff | Future | Stop after shell and content structure are ready, optionally add role-aware preview structure, and hand off real gating to Phase 9 |
| Prompt 8.1 | Restaurant onboarding + connector setup | Future | Create location setup flow, connector mappings, and auth/validation paths after 7.51 closes the gate |
| Prompt 8.2 | Initial 60-day backfill + baseline bootstrap | Future | Pull the restaurant's initial historical window and build baseline/targets from canonical records |
| Prompt 8.3 | Continuous live sync + close/finalization | Future | Keep live shift state fresh, finalize shifts correctly, update weekly state, and maintain the rolling 60-day baseline |
| Prompt 9.1 | Restaurant identity + role model | Future | Define restaurant users, roles, permissions, and identity-link contracts |
| Prompt 9.2 | Login + admin user control | Future | Add restaurant login UX, onboarding-created app credentials, and admin-side permission management |
| Prompt 10.1 | Shared sync + audit | Future | Propagate overrides/settings across devices and track who changed what and when |
| Prompt 11 | Corporate / franchise layer | Future | Add org hierarchy and cross-store visibility while keeping restaurant id as the operational truth boundary |

## Risks To Watch

- Demo-shaped logic spreading into permanent architecture
- Derived metrics being treated like source facts
- Historical views drifting if locked target truth is not fully persisted before Phase 8
- Waiting too long to unwind demo-owned screen truth could make `7.5c` wider and riskier than it needs to be
- If close/finalization rules are not explicit, live data can be promoted into history too early and poison the rolling 60-day baseline
- Declaring Phase 8 started before the post-`7.5` audit items are actually closed would hide drift inside the connector phase
- Keeping `BaselineData` and persisted active-target state both authoritative would make propagation bugs harder to debug during live rollout
- Missing vendor capability profiles or field-ownership docs would push data-contract decisions into adapter code instead of keeping them explicit
- Letting the sign-off doc list fewer blockers than the replay-readiness matrix would make the gate internally inconsistent
- Treating placeholder vendor profiles as "done enough" would move vendor-data decisions into implementation instead of planning
