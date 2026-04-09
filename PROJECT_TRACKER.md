# Forge & Flow Project Tracker

Updated: 2026-04-02
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

- Current phase: Phase 7.55 Release Stabilization + Phase 9 Auth Planning while Phase 8 Live POS + Labor Adapters remains blocked on vendor selection
- Current prompt: `7.55a` is complete; next planned execution prompt is `9a.1`
- Current goal: keep live-feedback fixes small and safe while starting Phase 9 from the locked auth plan instead of ad hoc login work
- Phase 7.5 status: complete
- Phase 7.51 status: complete on the app side
- Phase 7.52 status: complete
- Phase 7.53 status: complete
- Phase 7.54 status: complete
- Phase 7.55 status: active hotfix lane; `7.55a` complete
- Phase 7.5 gate status: complete on the app side
- Phase 8 status: blocked on vendor selection only
- Phase 9 status: planning contract locked in `docs/phase_9_auth_plan.md`
- Current live-integration scope: one restaurant or location, not multi-location org management
- Do not drift into: multi-location org management, cross-device sync, or new target math beyond baseline-derived selection truth
- Do not drift into: unaudited visual redesign while shipping hotfixes or planning auth
- Baseline naming freeze: keep internal and visible Baseline naming unchanged during this alignment pass
- Completed prompt history, detailed progress notes, older summaries, and decision log now live in `PROJECT_TRACKER_ARCHIVE.md`
- Planning contracts:
  - `docs/phase_7_52_execution_plan.md`
  - `docs/phase_7_54_optimization_plan.md`
  - `docs/phase_9_auth_plan.md`

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
  Complete on the app side: structural alignment is done, the tracked Flutter corpus rerun passed, and the only remaining Phase 8 blocker is vendor selection.
- [x] Phase 7.52 - Cleanup + Product Identity + Private Barrio Build
  Clean up repo naming and legacy files, establish Forge & Flow as the shared product identity, create the private Barrio build boundary, and build the Barrio shell plus structured internal content surfaces before Phase 9 auth.
- [x] Phase 7.53 - Native Dual-Build Hardening
  Split Forge & Flow and Barrio into separate native build identities with flavor/scheme setup, separate ids, icons, and splash assets, then keep Barrio consuming an extracted shared Forge & Flow runtime boundary rather than depending on `lib/main.dart`.
- [x] Phase 7.54 - Runtime + Footprint Optimization
  Reduce Barrio thermal cost and trim flavor/package footprint without changing the visual contract, product split, or app-side architecture.
- [ ] Phase 7.55 - Release Stabilization
  Small live-feedback hotfix lane for readability, tap-target size, and other low-risk UI issues based on real device/use feedback.
- [ ] Phase 8 - Live POS + Labor Adapters
  Add connectors that feed the canonical input model for one restaurant/location after the Phase 7.51 readiness closeout passes.
- [ ] Phase 9 - Restaurant Auth + Login
  Add one shared Firebase-backed auth, role, permission, and persistent-session system across Forge & Flow and Barrio.
- [ ] Phase 9.5 - El Podio Learning Identity
  Move El Podio from demo users to real authenticated learning data after the core auth and role system lands.
- [ ] Phase 10 - Shared Multi-Device Sync
  Add cross-device shared restaurant state so actions like manager override propagate across all devices for that restaurant.
- [ ] Phase 11 - Corporate / Franchise Layer
  Add a future placeholder for multi-store hierarchy, corporate permissions, and cross-store visibility above the restaurant-level truth boundary.

## Immediate Watchlist

- Phase 8 is blocked on vendor selection only
- Phase 9 auth is now planned in detail, but `9a.1` and `9a.2` still need user-confirmed Firebase project setup and trusted admin-backend choices before implementation can honestly begin
- `7.55a` font size changes should be visually spot-checked on a real device, especially dense tables like daypart, week detail, and schedule
- Final iOS build/run verification for the asset-catalog split still needs a macOS/Xcode pass
- Baseline and Learn still rely on the documented `BaselineData` compatibility bridge (intentionally frozen)
- Barrio home-shell runtime heat pass is complete, but real device profiling on lower-end phones is still worth doing before release confidence is claimed
- ForgeFlow still bundles about 2 MB of Barrio-private runtime assets due to Flutter's lack of flavor-conditional asset bundling in `pubspec.yaml`; eliminating this would require a larger package restructure
- Barrio auth-dependent gaps, role-enforcement rules, and El Podio learning identity scope now live in `docs/phase_9_auth_plan.md`
- Future restaurant-count scale should be treated as a data/query problem, not as a reason to add tenant-specific source-code forks

## Working Prompt Tracker

Completed prompt history, detailed phase summaries, and older decision notes now live in `PROJECT_TRACKER_ARCHIVE.md`.

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 7.54a | Barrio thermal/render-cost pass | Done | Repaint containment, lifecycle/ticker cleanup, merged animation listeners, and cache-sized image decode paths landed with focused Barrio widget coverage passing |
| Prompt 7.54b | Release-size and asset-compression pass | Done | Dynamic IconData blockers removed, heavy PNGs converted to JPEG, icon tree shaking restored, release split APK build succeeds, focused Barrio tests passing |
| Prompt 7.54c | Flavor asset-bundle containment + space hygiene | Done | handbook_icon moved to Barrio-private dir, non-runtime assets verified excluded, Flutter flavor-conditional limitation documented with APK evidence, README updated with size/containment docs |
| Prompt 7.55a | Font size / readability / accessibility pass | Done | Theme floor raised, Manager Override button enlarged, Barrio inline sizes fixed, layout overflow fixes landed, El Podio full-width, tests passing |
| Prompt 7.55 follow-up | Additional live-feedback hotfixes | Optional | Open only if real store/release feedback justifies another small stabilization pass |
| Prompt 8.1 | Restaurant onboarding + connector setup | Blocked | Blocked on vendor selection |
| Prompt 8.2 | Initial 60-day backfill + baseline bootstrap | Future | Pull initial historical window and build baseline/targets |
| Prompt 8.3 | Continuous live sync + close/finalization | Future | Keep live shift state fresh, finalize shifts, maintain rolling 60-day baseline |
| Prompt 9a.1 | Firebase project setup + native app registration | Future | Guide Firebase project/auth/firestore setup, register both Android and both iOS app ids, and place Firebase config files correctly in the repo |
| Prompt 9a.2 | Trusted admin backend decision | Future | Lock Cloud Functions/Admin SDK or another trusted backend path for admin-created user and reset flows |
| Prompt 9b.1 | Restaurant user identity model | Future | Add shared `Restaurant`, `RestaurantUser`, and external-identity-link shape with Firebase `uid` as the app identity key |
| Prompt 9b.2 | Seeded roles + custom roles + fixed permission catalog | Future | Seed `staff/supervisor/manager/admin` with recommended defaults, allow edits/custom roles, keep permission keys app-defined |
| Prompt 9c.1 | Firebase auth wiring + session bootstrap | Future | Add shared auth bootstrap and persistent session handling for both app flavors |
| Prompt 9c.2 | Login / logout / password reset UX | Future | Build the user-facing auth flow with email/password and persistent login until logout |
| Prompt 9d.1 | Trusted admin user management flows | Future | Implement backend-backed create/deactivate/reset flows safely; depends on `9a.2` |
| Prompt 9d.2 | In-app admin console | Future | Let admins manage users, edit seeded roles, create custom roles, and assign permissions from one console |
| Prompt 9e.1 | Forge & Flow runtime enforcement | Future | Apply permissions to standalone Forge & Flow screens and sensitive actions without disturbing Phase 8 data flow |
| Prompt 9e.2 | Barrio runtime enforcement | Future | Replace preview-only role behavior with real auth-driven destination and route access; Barrio admin remains the superset role |
| Prompt 9.5a | User-scoped learning persistence | Future | Replace in-memory completion/mastery/streak state with real auth-scoped persistence |
| Prompt 9.5b | Shared El Podio learning leaderboard | Future | Move El Podio from demo users to shared authenticated learning data; keep sales/PPA/CPLH ranking out of this block |
| Prompt 10.1 | Shared sync + audit | Future | Cross-device propagation and audit trail |
| Prompt 11 | Corporate / franchise layer | Future | Multi-store hierarchy and cross-store visibility |
