# Forge & Flow Project Tracker

Updated: 2026-04-10
Owner: You
Execution model: We think, Claude codes
Archive: `PROJECT_TRACKER_ARCHIVE.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> Baseline -> Targets -> Schedule -> Shift -> Variance -> Learn

## Product Split

- This Week = diagnose what lever matters first right now
- History = teach what leaks repeat over time
- Learn = summarize recurring leaks, benchmarks, and repeatable wins

## Current Data Truth Clarification

- The app is not connected to a live POS, labor, or reservation vendor yet.
- Current visible app data still comes from fixture, replay, or demo-seeded input.
- That input now flows through the same internal app-side path that live vendor data is expected to use:
  - canonical models
  - SQLite persistence
  - app state, providers, and notifiers
  - UI
- This means the internal architecture is ready for live adapters even though transport is still fixture or replay backed.
- Phase 8 / 8R should replace transport with live vendor feeds, not create a second UI-facing truth path.

## Active Focus

- Current phase: Phase 7.55 Release Stabilization / alignment planning + Phase 7.56 Reservation Book Signal verified + Phase 9 Auth Planning while Phase 8 Live POS + Labor Adapters remains blocked on vendor selection
- Current prompt: next execution prompt is `7.55g` Schedule sales card + Baseline cleanup
- Current goal: close the remaining Phase 7.55 architecture gaps before live integrations: 7.55e made day/daypart distribution data-driven and mock-integration-backed, 7.55f made Manager Override business-date-native with calendar navigation and a scenario-level mock replay clock, 7.55g/h clean up Schedule/Baseline/wage presentation, 7.55i retires the remaining non-airtight compatibility bridges by adding canonical Demand Forecast Context authority, shared SchedulePlan consumption, explicit WTD target semantics, and Learn migration off `BaselineData` benchmark context, 7.55j inventories every feature's required POS/labor/reservation capabilities before vendor-specific Phase 8 work begins, and 7.55k strengthens closed-history daypart semantics for Variance, History, and Learn without making Shift daypart-live
- Phase 7.5 status: complete
- Phase 7.51 status: complete on the app side
- Phase 7.52 status: complete
- Phase 7.53 status: complete
- Phase 7.54 status: complete
- Phase 7.55 status: active hotfix / alignment lane; `7.55a`, `7.55b`, `7.55c.2`, `7.55d`, `7.55e`, and `7.55f` are complete through scenario-level mock replay reset/advance; `7.55g` through `7.55k` remain planned to make presentation consistency, canonical demand, shared plan authority, WTD semantics, Learn benchmark context, integration requirements, and downstream daypart coaching semantics airtight
- Phase 7.56 status: complete on the app-side demo path; `7.56a` added and verified the Shift COVERS card `In the books` signal from seeded SQLite reservation-book cache; live reservation transport remains later official-integration work
- Phase 7.5 gate status: complete on the app side
- Phase 8 status: blocked on vendor selection only
- Phase 8R status: planned official reservation connector lane after official platform access and capability profile are available
- Phase 9 status: planning contract locked in `docs/phase_9_auth_plan.md`
- Current live-integration scope: one restaurant or location, not multi-location org management
- Do not drift into: multi-location org management, cross-device sync, or new target math beyond baseline-derived selection truth
- Do not drift into: unaudited visual redesign while shipping hotfixes or planning auth
- Baseline naming freeze: keep internal and visible Baseline naming unchanged during this alignment pass
- Completed prompt history, detailed progress notes, older summaries, and decision log now live in `PROJECT_TRACKER_ARCHIVE.md`
- Planning contracts:
  - `docs/phase_7_52_execution_plan.md`
  - `docs/phase_7_54_optimization_plan.md`
  - `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`
  - `docs/phase_7_55d_whole_day_shift_schedule_plan.md`
  - `docs/phase_7_55e_distribution_architecture_findings.md`
  - `docs/phase_7_55f_manager_override_calendar_plan.md`
  - `docs/phase_7_55g_schedule_sales_card_baseline_cleanup.md`
  - `docs/phase_7_55h_blended_wage_decimal_consistency.md`
  - `docs/phase_7_55i_canonical_demand_schedule_plan_authority.md`
  - `docs/phase_7_55j_integration_feature_endpoint_inventory.md`
  - `docs/phase_7_55k_daypart_variance_history_learn_plan.md`
  - `docs/phase_7_56_reservation_book_signal_plan.md`
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
  Small live-feedback hotfix lane for readability, tap-target size, low-risk UI issues, and presentation/logic clarity based on real device/use feedback.
- [x] Phase 7.56 - Reservation Book Signal Demo
  Complete on the app side: added a repository-backed reservation book signal to the Forge & Flow Shift COVERS card using app-owned canonical models, SQLite cache, seeded demo data, and focused tests. Displays `In the books` as unseated reservation covers beneath the existing forecast line. Live OpenTable/reservation API work remains out of this phase.
- [ ] Phase 8 - Live POS + Labor Adapters
  Add connectors that feed the canonical input model for one restaurant/location after the Phase 7.51 readiness closeout passes. Shift shows whole-day running totals during service; daypart split happens at close time when the adapter buckets by timestamp. Per-service-period live view deferred to Phase 10.5.
- [ ] Phase 8R - Official Reservation Connector
  Add official reservation-platform transport, capability profile, status mapping, and sync into the Phase 7.56 reservation book cache without changing Shift-screen math or UI ownership.
- [ ] Phase 9 - Restaurant Auth + Login
  Add one shared Firebase-backed auth, role, permission, and persistent-session system across Forge & Flow and Barrio.
- [ ] Phase 9.5 - El Podio Learning Identity
  Move El Podio from demo users to real authenticated learning data after the core auth and role system lands.
- [ ] Phase 10 - Shared Multi-Device Sync
  Add cross-device shared restaurant state so actions like manager override propagate across all devices for that restaurant.
- [ ] Phase 10.5 - Shift Daypart-Aware Service Period View + Primary Driver
  Currently Shift shows whole-day running totals (Phase 8 integration path) and the PRIMARY DRIVER teaching section is hidden. Future: auto-detect the current service period (lunch/dinner/late_night) from wall clock, show only that period's actuals and targets with daypart-specific coaching, and re-enable the primary lever teaching section once lever detection operates on aligned daypart actuals vs daypart targets. Requires per-daypart target profiles and adapter-side live daypart bucketing.
- [ ] Phase 11 - Corporate / Franchise Layer
  Add a future placeholder for multi-store hierarchy, corporate permissions, and cross-store visibility above the restaurant-level truth boundary.

## Immediate Watchlist

- Phase 8 is blocked on vendor selection only
- Phase 7.56 is app-side only and now verified: it added seeded/local reservation book cache and Shift UI rendering, but it must not claim live OpenTable/reservation integration.
- Phase 8R official reservation integration must use approved vendor access only; no scraping, no shared restaurant credentials in the Flutter client, and no direct mobile API secrets.
- `7.55c.2` is app-side implemented and verified: Covers always from POS 60-day history (`historicalWeeklyAvgCovers`); sales always derived as covers × target PPA. No vendor forecast inputs, no manager editing on Schedule. Manager influence is Baseline target profile override only. The old `1200` remains only as demo fallback when no historical data exists. Phase 8 replaces the transport (fixture → live POS) but not the derivation logic.
- `7.55d` is closed through `7.55d.3c`: SchedulePlan now combines baseline-derived demand context with ActiveTargetProfile standards; Shift uses whole-business-day plan-vs-actual; Manager Override preview/audit paths show downstream planning impact; follow-ups corrected BOH actual-sales model-hour paths for WTD and closed Variance detail, then backfilled static/demo locked targets without weakening strict historical getters.
- `7.55e` is complete through `7.55e.6a`: distribution weights are data-driven, Schedule consumes day/daypart weights, SQLite operational seed truth comes from deterministic mock POS/labor replay, production runtime dependence on `DemoData` operational lists has been retired, and every seeded `open_shift_snapshots` row now carries mock replay source provenance.
- `7.55e.4` non-blocking live-polish note: `ScheduleDistributionWeightsNotifier` loads on app startup, but there is not yet a refresh hook after new shifts close during the same app session. Keep this for Phase 8 / live-integration polish or the post-close refresh path; it does not block 7.55e.4 verification.
- `7.55f` is complete through verified `7.55f.4`: `business_date` exists on closed ShiftRecords, Manager Override uses a true 60-day business-date window with historical actual labor %, calendar navigation is DST-safe, suggested/selected star-day states and copy polish landed, lever chips preserve full canonical meaning, and mock replay reset/advance now reseeds coherent scenario truth across `shift_records`, `week_records`, `open_shift_snapshots`, and `reservation_book_snapshots`. Non-blocking note: some test/preview compatibility surfaces still intentionally read `MockIntegrationReplaySeed.output`, so they remain fixed to the default scenario while runtime SQLite-backed surfaces move with the mock replay clock.
- `7.55i` is now the explicit catch-all for the remaining non-airtight architecture: canonical Demand Forecast Context authority, shared SchedulePlan read service, retiring production-facing `BaselineData` plan/demand reads, deciding WTD target semantics, and migrating Learn benchmark context to repository-backed state.
- `7.55j` is planned as the integration feature/endpoint inventory: walk the whole codebase, list every feature that consumes operational truth, and map it to the official POS, labor, and reservation capabilities needed so Phase 8 / Phase 8R fully uses the integrations instead of under-pulling data.
- `7.55k` is planned as the downstream daypart-semantics and separation phase: define the long-term `restaurantId + businessDate + daypart` service-period boundary, identify decoupling/refactor work, decide what waits for official API capability profiles, clearly distinguish closed/open/projected daypart rows in Variance, move History Benchmark Dayparts from frequency labels to evidence-backed summaries, and make Learn Repeatable Wins explain why wins repeat while Shift remains whole-business-day until Phase 10.5.
- Commit hygiene: the current dirty worktree contains Phase 7.55 stabilization edits, the `7.55b` Schedule BOH sales-first seam/test, the `7.55c.2` Schedule forecast demand-source model/test, Phase 7.56 reservation signal work, tracker/docs edits, and one stale OPZ test-contract cleanup. Before committing or PR review, split by phase where practical or use an explicit commit message that names the mixed scope.
- Phase 9 auth is now planned in detail, but `9a.1` and `9a.2` still need user-confirmed Firebase project setup and trusted admin-backend choices before implementation can honestly begin
- `7.55a`/`7.55b`/`7.55c.2` presentation changes should be visually spot-checked on a real device, especially dense tables like daypart, week detail, the Schedule table with the new SALES column, and the Schedule forecast-source line
- Final iOS build/run verification for the asset-catalog split still needs a macOS/Xcode pass
- Baseline and Learn still rely on the documented `BaselineData` compatibility bridge (intentionally frozen)
- Barrio home-shell runtime heat pass is complete, but real device profiling on lower-end phones is still worth doing before release confidence is claimed
- ForgeFlow still bundles about 2 MB of Barrio-private runtime assets due to Flutter's lack of flavor-conditional asset bundling in `pubspec.yaml`; eliminating this would require a larger package restructure
- Barrio auth-dependent gaps, role-enforcement rules, and El Podio learning identity scope now live in `docs/phase_9_auth_plan.md`
- Future restaurant-count scale should be treated as a data/query problem, not as a reason to add tenant-specific source-code forks
- Shift clock is static (frozen at seed time: `'7:42 PM'`, `'3h 14m into service'`). Phase 8 should add a real `shiftStartTime` to `OpenShiftSnapshot`, compute elapsed from `DateTime.now()`, and add a periodic refresh timer so the Shift header ticks live during an open shift.

## Working Prompt Tracker

Completed prompt history, detailed phase summaries, and older decision notes now live in `PROJECT_TRACKER_ARCHIVE.md`.

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 7.54a | Barrio thermal/render-cost pass | Done | Repaint containment, lifecycle/ticker cleanup, merged animation listeners, and cache-sized image decode paths landed with focused Barrio widget coverage passing |
| Prompt 7.54b | Release-size and asset-compression pass | Done | Dynamic IconData blockers removed, heavy PNGs converted to JPEG, icon tree shaking restored, release split APK build succeeds, focused Barrio tests passing |
| Prompt 7.54c | Flavor asset-bundle containment + space hygiene | Done | handbook_icon moved to Barrio-private dir, non-runtime assets verified excluded, Flutter flavor-conditional limitation documented with APK evidence, README updated with size/containment docs |
| Prompt 7.55a | Font size / readability / accessibility pass | Done | Theme floor raised, Manager Override button enlarged, Barrio inline sizes fixed, layout overflow fixes landed, El Podio full-width, tests passing |
| Prompt 7.55b | Schedule FOH/BOH demand-source clarity | Done | Schedule now presents COVERS and SALES separately; FOH hours remain cover-driven, BOH hours now route through a sales-first `LaborModel.modelBohHoursFromSales` seam with the covers/PPA helper preserved as compatibility. Codex verification: `flutter analyze`, focused `labor_model_boh_sales` + OPZ tests, full `flutter test` with 533 tests, and `git diff --check` passed. |
| Prompt 7.55c | Schedule forecast demand-source model | Done | Covers always from POS 60-day history (historicalWeeklyAvgCovers); sales always derived as covers × target PPA. Removed vendor forecast, manager editing, and sales-to-covers derivation paths. Enum simplified to 5 values: `appDerivedFromHistoricalAverage`, `appDerivedFromCoversAndPpa`, `appDerivedFromReservationAndWalkInModel`, `demoFallback`, `unavailable`. Resolver waterfall: historical avg → demo → unavailable. Schedule is read-only. Manager influence is Baseline target profile override only. 8 focused tests, full suite 541 pass, analyzer clean. |
| Prompt 7.55d.1 | Shared SchedulePlan math contract | Done | Added SchedulePlan/ScheduleDayPlan and SchedulePlanResolver; Schedule now delegates weekly/day planning math through the resolver; later follow-ups made plan unavailable states honest and reconciled day covers/FOH/BOH totals exactly. |
| Prompt 7.55d.2 | Whole-day Shift dashboard alignment | Done | Shift loads all current business-date snapshots, consumes the matching SchedulePlan day row, compares whole-day scheduled hours against plan hours, and keeps reservations contextual as `In the books`. |
| Prompt 7.55d.3 | Manager Override impact preview + audit proof | Done | Manager Override preview and Data Alignment Audit now show downstream SchedulePlan impact; follow-ups corrected actual-sales BOH model-hour paths in WTD, ShiftFact, WeekRecord, and closed Variance detail, then `7.55d.3c` backfilled static/demo locked targets so strict Variance getters remain safe. |
| Prompt 7.55e.1 | Distribution weight builder | Done | Added immutable `ScheduleDistributionWeights` and pure `DistributionWeightBuilder` from closed `ShiftRecord`s, with availability diagnostics and minimum-history guardrails. |
| Prompt 7.55e.2 | SchedulePlan distribution weights | Done | `SchedulePlanResolver` accepts optional distribution weights for weekly-to-day allocation while preserving weekly math and fallback defaults. |
| Prompt 7.55e.3 | Schedule daypart distribution | Done | `ScheduleForecastNotifier` and Schedule daypart subrows consume day x daypart weights with largest-remainder reconciliation and safe fallback. |
| Prompt 7.55e.4 | Runtime distribution weight wiring | Done | Added `ScheduleDistributionWeightsNotifier`, wired it into `ForgeFlowScope`, and passed closed-shift-derived weights into Schedule at runtime. Non-blocking follow-up: add a refresh hook after new shifts close during the same app session in the live-integration polish path. |
| Prompt 7.55e.5 | Mock integration replay seed | Done | Replaced hardcoded historical/current operational seed rows with deterministic mock POS/labor replay into SQLite, including realistic day/daypart variation, coherent labor/sales fields, source provenance, derived week records, and open Friday dinner replay state. |
| Prompt 7.55e.6 | Retire fixture-runtime dependence | Done | App runtime now proves it reads mock-imported SQLite operational data instead of `DemoData` fixture lists; `StaticShiftDataSource` is test/preview compatibility and now backed by `MockIntegrationReplaySeed`. |
| Prompt 7.55e.6a | Open snapshot provenance hardening | Done | All seeded projected/open/closed `open_shift_snapshots` rows now carry mock replay source system and deterministic source shift ids; guard tests prove non-empty provenance for every seeded snapshot row. |
| Prompt 7.55f | Manager Override calendar + business_date | Done | `7.55f.1` through `7.55f.4` are verified: Manager Override now uses true `business_date` windows, shows candidate actual labor %, supports calendar/day-detail navigation with suggested/selected star-day semantics, preserves full lever meaning, and mock replay reset/advance now reseeds coherent scenario truth across all runtime operational tables. |
| Prompt 7.55f.1 | business_date foundation + true date-range querying | Done | Persisted `business_date` on closed `ShiftRecord`s, added SQLite migration/backfill, stamped mock replay shifts, and added true closed-shift date-range DAO/repository queries. |
| Prompt 7.55f.1a | malformed-row business_date hardening | Done | V12 backfill now leaves malformed legacy week/day rows null instead of fabricating sentinel dates. |
| Prompt 7.55f.1b | strict week-id parsing + sentinel cleanup | Done | App-owned business-date helpers now require strict `YYYY-W##` shape and no lib business-date path returns `1970-01-01`. |
| Prompt 7.55f.2 | Manager Override true 60-day candidates + actual labor % | Done | Manager Override candidate loading now uses a true latest-closed-date anchored 60-day window; candidate tiles can carry historical actual labor %; draft-only Clear All exists. |
| Prompt 7.55f.3 | Manager Override calendar navigation UI | Done | Replaced the flat candidate list with a 60-day calendar -> day-detail flow anchored to candidate `businessDate`, while preserving preview and selection semantics. |
| Prompt 7.55f.3a | DST-safe calendar grid hardening | Done | Removed DST-sensitive calendar iteration and added focused regression proof around the spring-forward boundary. |
| Prompt 7.55f.3b | suggested-star-day legend + Manager Override copy polish | Done | Added available/suggested/selected calendar states + legend, human-friendly date copy, natural-language lever/date presentation, and a larger Clear All touch target without shrinking the candidate pool. |
| Prompt 7.55f.3c | Manager Override lever-meaning preservation | Done | Lever chips now show full canonical lever meaning (for example `CPLH ABOVE TARGET`, `SPLH BELOW TARGET`) instead of collapsing distinct levers into generic metric buckets. |
| Prompt 7.55f.4 | mock replay reset/advance scenario-level | Done | Added persistent mock replay business-date state, scenario-driven replay generation, reset/advance controls, scenario-aware Manager Override anchoring, and coherent reseeding across `shift_records`, `week_records`, `open_shift_snapshots`, and `reservation_book_snapshots`. |
| Prompt 7.55g | Schedule sales card + Baseline cleanup | Next | Add Forecasted Sales to Schedule and remove confusing Weekly Avg Covers / forecast-source presentation while preserving the underlying provenance model. |
| Prompt 7.55h | Blended wage + decimal consistency | Planned | Add target blended wage/wage visibility where needed and standardize PPA/CPLH precision across Baseline, Schedule, Shift, and Variance surfaces. |
| Prompt 7.55i | Canonical demand + shared SchedulePlan authority | Planned | Create the canonical demand/read-service layer not covered by e-h: retire production-facing `BaselineData` plan/demand reads, make Schedule/Shift/Audit consume one SchedulePlan authority, decide WTD target semantics, and migrate Learn benchmark context to repository-backed state. |
| Prompt 7.55j | Integration feature + endpoint inventory | Planned | Walk the full codebase and product surface, then map each feature to required official POS/labor/reservation capabilities, fields, freshness needs, source ownership, fallback behavior, and Phase 8 / Phase 8R connector-readiness gaps. |
| Prompt 7.55k | Daypart semantics + separation plan | Planned | Define the long-term service-period boundary and decoupling plan; audit downstream daypart scope; strengthen Variance Full Week row semantics, History Benchmark Dayparts, and Learn Repeatable Wins with closed-shift daypart evidence while keeping Shift whole-day until Phase 10.5. |
| Prompt 7.55 follow-up | Additional live-feedback hotfixes | Optional | Open only if real store/release feedback justifies another small stabilization pass |
| Prompt 7.56a | Reservation Book Signal Demo | Done | Added `ReservationBookSnapshot`, SQLite cache/repository, seeded demo data, Shift read-model field, and COVERS card UI line for `In the books`; no live vendor transport. Codex verification: `flutter analyze`, focused reservation/notifier/widget tests, OPZ contract test, and full `flutter test` passed. |
| Prompt 8.1 | Restaurant onboarding + connector setup | Blocked | Blocked on vendor selection |
| Prompt 8.2 | Initial 60-day backfill + baseline bootstrap | Future | Pull initial historical window and build baseline/targets |
| Prompt 8.3 | Continuous live sync + close/finalization | Future | Keep live shift state fresh, finalize shifts, maintain rolling 60-day baseline |
| Prompt 8R.1 | Reservation connector capability profile | Future | Document official reservation platform access, available fields, status mapping, polling/webhook support, rate limits, source ownership, and fallback behavior. |
| Prompt 8R.2 | Official reservation connector | Future | Map official reservation API data into canonical reservation records/snapshots and update the Shift COVERS card from live synced data through the existing cache/read-model path. |
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
