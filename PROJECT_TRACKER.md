# Forge & Flow Project Tracker

Updated: 2026-04-01
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

- Current phase: Phase 8 Live POS + Labor Adapters (blocked on vendor selection)
- Current prompt: Next prompt is `8.1 - Restaurant onboarding + connector setup`, but it remains blocked until the first POS and labor vendors are selected
- Current goal: Phase 7.53 is complete (a through f plus polish). Keep the repo ready for `8.1` while waiting on vendor selection
- Phase 7.5 status: complete
- Phase 7.51 status: complete on the app side
- Phase 7.52 status: complete
- Phase 7.53 status: complete (a through f plus polish); final iOS build/run verification should still happen on macOS/Xcode before release confidence is claimed
- Phase 7.5 gate status: complete on the app side
- Phase 8 status: blocked on vendor selection only
- Current live-integration scope: one restaurant or location, not multi-location org management
- Do not drift into: multi-location org management, cross-device sync, or new target math beyond baseline-derived selection truth
- Baseline naming freeze: keep internal and visible Baseline naming unchanged during this alignment pass
- Completed prompt history, detailed progress notes, and older decisions now live in `PROJECT_TRACKER_ARCHIVE.md`
- The completed `7.52` execution contract now lives in `docs/phase_7_52_execution_plan.md`

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
- [x] Phase 7.52 - Cleanup + Product Identity + Private Barrio Build
  Clean up repo naming and legacy files, establish Forge & Flow as the shared product identity, create the private Barrio build boundary, and build the Barrio shell plus structured internal content surfaces before Phase 9 auth.
- [x] Phase 7.53 - Native Dual-Build Hardening
  Split Forge & Flow and Barrio into separate native build identities with flavor/scheme setup, separate ids, icons, and splash assets, then keep Barrio consuming an extracted shared Forge & Flow runtime boundary rather than depending on `lib/main.dart`.
- [ ] Phase 8 - Live POS + Labor Adapters
  Add connectors that feed the canonical input model for one restaurant/location after the Phase 7.51 readiness closeout passes.
- [ ] Phase 9 - Restaurant Auth + Login
  Add restaurant-scoped login, onboarding-created credentials, roles, permissions, and Admin user control.
- [ ] Phase 10 - Shared Multi-Device Sync
  Add cross-device shared restaurant state so actions like manager override propagate across all devices for that restaurant.
- [ ] Phase 11 - Corporate / Franchise Layer
  Add a future placeholder for multi-store hierarchy, corporate permissions, and cross-store visibility above the restaurant-level truth boundary.

## Phase 7.53 Summary (complete — detail in ARCHIVE)

All sub-prompts (7.53a through 7.53f plus polish) are complete. Detailed completion notes, UI change logs, and file lists are in `PROJECT_TRACKER_ARCHIVE.md`.

Key outcomes:
- Dual native build identities (ForgeFlow + Barrio) with separate Android flavors, iOS schemes, icons, and splash
- Shared Forge & Flow runtime boundary extracted; Barrio consumes it
- Premium teaching UI: PageView carousel, 3D perspective, card press/glass/expand, worm dots, enhanced sparkle, photo backgrounds
- All content complete from source PDFs/HTML: 86 units across 13 chapters/sections/modules, zero placeholders
- Answer positions shuffled (A=10, B=9, C=8), unique badgeHint per unit, 13 rail icons verified from Flutter SDK
- El Podio scoreboard with Phase-9-ready PodioEntry model + home screen button
- Preston Lee cleaned for UI consistency; Phase 9 Barrio requirements documented
- Performance: film grain removed, carousel breathing removed, blur radii halved
- Colour-temperature scrim breathing on home screen (12s warm↔cool loop)
- 513 tests passing, 0 errors
- Final iOS build/run verification still needs a macOS/Xcode pass before release confidence

## Immediate Watchlist

- Phase 8 is blocked on vendor selection only
- Final iOS build/run verification for the asset-catalog split still needs a macOS/Xcode pass
- Baseline and Learn still rely on the documented `BaselineData` compatibility bridge (intentionally frozen)
- Forge & Flow customer builds must not accidentally ship Barrio-private content
- Future restaurant-count scale should be treated as a data/query problem, not as a reason to add tenant-specific source-code forks

Barrio NOT DONE — deferred to Phase 9 (requires user auth):
- Mastery/completion tracking is in-memory only — all progress lost on exit
- Streak tracker uses global SharedPreferences keys — not user-scoped
- No user identity passed to any Barrio screen constructor
- El Podio scoreboard uses demo seed data — needs real user completion data
- Role preview dimming is visual-only — no real access enforcement

## Working Prompt Tracker

Completed prompt history (Prompts 0 through 7.53f) moved to `PROJECT_TRACKER_ARCHIVE.md`.

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 8.1 | Restaurant onboarding + connector setup | Blocked | Blocked on vendor selection |
| Prompt 8.2 | Initial 60-day backfill + baseline bootstrap | Future | Pull initial historical window and build baseline/targets |
| Prompt 8.3 | Continuous live sync + close/finalization | Future | Keep live shift state fresh, finalize shifts, maintain rolling 60-day baseline |
| Prompt 9.1 | Restaurant identity + role model | Future | User identity, roles, permissions; Barrio needs: user-scoped persistence, real role gating, scoreboard identity, streak ownership |
| Prompt 9.2 | Login + admin user control | Future | Login UX, credentials, admin permissions, Barrio role enforcement |
| Prompt 10.1 | Shared sync + audit | Future | Cross-device propagation and audit trail |
| Prompt 11 | Corporate / franchise layer | Future | Multi-store hierarchy and cross-store visibility |

## Phase 9 Barrio Requirements

What Barrio needs from Phase 9 (restaurant auth + login):

Persistence (currently in-memory, lost on exit):
- All 3 learning screens track completion in `Set<String> _completedUnits` — purely ephemeral
- Needs: SharedPreferences keyed by `'{screen}_completed_{userId}'` (same pattern as streak tracker)
- Mastery % should persist per user so progress shows on re-open
- Streak tracker (`barrio_streak_tracker.dart`) currently uses global keys — needs userId parameter to isolate per-user streaks
- El Podio scoreboard (`PodioEntry` model) already has userId field — needs to query real completion data instead of demo seed

Auth integration points:
- All screen constructors need `userId` parameter: `CompanyHandbookScreen`, `InterviewPlaybookScreen`, `JimTaylorModelScreen`, `PrestonLeeModelComingSoonScreen`
- `BarrioRouteMap.navigateTo()` needs to pass userId from auth context to screen constructors
- `BarrioStreakService.recordActivity(String userId)` — userId scopes the SharedPreferences keys
- `BarrioBubbleHub` is presentation-only — no userId needed (role determines dimming)

Role enforcement:
- Preview role system (dimming) must be replaced by real auth role from login session
- `BarrioPreviewRole` enum maps cleanly to `BarrioAudience` — same model, just needs real source
- Audience tags and access intent banners were intentionally removed from all screens during 7.53f — Phase 9 should add real gating systematically, not screen-by-screen
- `BarrioDestination.audiences` already defines who should see each destination — enforcement just needs auth context

## Risks To Watch

- If close/finalization rules are not explicit, live data can be promoted into history too early and poison the rolling 60-day baseline
- Missing vendor capability profiles or field-ownership docs would push data-contract decisions into adapter code instead of keeping them explicit
- Shipping without a final macOS/Xcode verification pass would leave the iOS flavor asset wiring unproven
- Treating future restaurant-count growth as a reason for source-code forking would solve the wrong problem; scaling pressure comes from data volume and query design
- Barrio mastery/completion being in-memory only means no user progress survives app restart until Phase 9 auth lands
