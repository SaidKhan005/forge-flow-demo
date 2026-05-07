# Forge & Flow Tracker Archive

Archived from `PROJECT_TRACKER.md` on 2026-03-30 so the working tracker can stay concise.

Use this file for:
- completed prompt history
- detailed progress notes
- older implementation decisions that still matter later

The active roadmap, watchlist, and next prompts now live in [PROJECT_TRACKER.md](C:/Git%20Local%20Repos/forge_flow_demo/PROJECT_TRACKER.md).

## Archived 7.52 Detail

Detailed `7.52` scope, destination contracts, completion notes, and the post-`7.52` handoff context now live in [phase_7_52_execution_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/phase_7_52_execution_plan.md).

Use this archive plus that execution-plan doc together when you need to revisit how the private Barrio shell and content phase was delivered.

## 11A Accepted Detail

### `11A.5` Debug Console

Accepted 2026-05-03 in worktree `claude/nifty-colden-5621fa`.

- Promoted the admin Debug route from placeholder to a live
  `DebugConsoleAdminScreen` with Request log, Graph debug stub, and MFA
  diagnostics stub tabs.
- Added request-log models, filter/time-window matching, full-content opt-in
  projection, and the `DebugConsoleAdminGateway` interface with HTTP and
  in-memory demo implementations.
- Wired `lib/main_admin.dart` so live admin builds resolve
  `HttpDebugConsoleAdminGateway` for `/v1/admin/debug/*`; in-memory seed data
  stays limited to demo/missing-proxy contexts.
- Preserved the PII discipline: request meta is visible by default, while raw
  full content requires both `super_admin` and the operator
  `debug_console_full_content_enabled` feature-flag opt-in.
- Runtime posture is accepted: cheap initial render, live-tail off by default,
  no stacked tail requests, and entry merges clamped to
  `kDebugConsoleListLimit`.
- Verification reported clean analyzer plus 45 passing focused tests across
  debug gateway, debug screen, and admin shell route coverage.

Evidence:

- Walkthrough: `docs/_walkthroughs/11A.5.md`.
- Active plan closeout:
  `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.

Residuals:

- `11A.6` still owns cost/dependency observability over the delivered
  B44/B45/B47 health producers and live evidence.
- Graph debug and MFA diagnostics are mounted as future extension stubs; they
  do not reopen the accepted 11A.5 request-log scope.

## 7.57 Stabilization Accepted Detail

### `7.57.3a` Provider Abstraction Foundation

Accepted 2026-04-25.

- Added provider interfaces for embeddings, rerank, advisor answers, and data
  sources.
- Added concrete Voyage, Claude, and mock-replay adapters with injected
  gateways for fake-tested behavior.
- Fixed advisor model routing after review:
  - quick defaults to `claude-haiku-4-5`
  - nuanced defaults to `claude-sonnet-4-6`
  - dev overrides persist via `SharedPreferences`
  - Settings exposes debug-only `ADVISOR MODELS`
  - Anthropic model check is update-aware and segment-orders model ids
- Verified by `dart analyze`,
  `test/provider_abstraction_test.dart`,
  `test/runtime_fixture_retirement_test.dart`,
  `test/advisor_corpus_manifest_test.dart`, and
  `test/settings_screen_widget_test.dart`.

### `7.57.3b` Corpus Embedding Provider Wiring

Accepted 2026-04-25.

- Routed `CorpusEmbeddingExecutor` vector generation through
  `VoyageEmbeddingProvider`.
- Preserved the existing `AdvisorEmbeddingGateway` fake/HTTP seam,
  `VOYAGE_API_KEY` behavior, batch/token accounting, SQL output, and
  execution manifest fields.
- Added wrong-dimension regression coverage proving provider contract checks
  reject bad gateway output.
- Verified by full `dart analyze`,
  `test/advisor_corpus_manifest_test.dart`, and
  `test/provider_abstraction_test.dart`.

### `7.57.3c` Static DataSourceProvider Wiring

Accepted 2026-04-25.

- Routed `StaticShiftDataSource` mock-replay reads through
  `MockReplayDataSourceProvider`.
- Added an injectable `MockReplayProvider` seam for tests while preserving
  default static/demo output.
- Verified by `dart analyze`,
  `test/runtime_fixture_retirement_test.dart`,
  `test/provider_abstraction_test.dart`,
  `test/wtd_variance_logic_test.dart`, and
  `test/variance_visual_widget_test.dart` (107 tests passed).

### `7.57.3d` LLM Provider Rename + Capability

Accepted 2026-04-25.

- Renamed the advisor-specific answer seam to `LLMProvider.complete(...)`.
- Renamed `AdvisorTier` / `AdvisorAnswer` to `LLMTier` / `LLMCompletion`.
- Renamed `ClaudeAnswerProvider` to `ClaudeLLMProvider`.
- Added `LLMProviderCapability.promptCaching`.
- Preserved Haiku/Sonnet routing, default quick tier, dev overrides, Settings
  model-routing behavior, and fake-gateway injection.
- Verified by `dart analyze`,
  `test/provider_abstraction_test.dart`, and
  `test/settings_screen_widget_test.dart` (59 tests passed).

`7.57.3` provider abstraction parent is accepted.

### `7.57.4` AGE Projection Artifacts

Accepted 2026-04-25.

- Added deterministic `prepare-age-projection` artifacts for the advisor corpus:
  AGE projection SQL, CPLH smoke-traversal SQL, and a projection manifest.
- Projection reads from `public.advisor_graph_node_seeds` and
  `public.advisor_graph_edge_hints`.
- Generated SQL carries an explicit `AGE_BLOCKER` path when AGE is unavailable.
- Codex local verification could not run Supabase because the `supabase` CLI is
  unavailable in this environment; live AGE apply remains a pre-`11b` gate in an
  AGE-enabled Supabase/Postgres environment.
- Verified by `dart analyze` and `test/advisor_corpus_manifest_test.dart`
  (21 tests passed).

`7.57` stabilization is complete. `11a` resumes at `11a.8`.

## 11a Accepted Detail

### `11a.8` Vector Search Schema + Function

Accepted 2026-04-25.

- Added `supabase/migrations/202604250003_advisor_vector_search.sql`.
- Added versioned embedding metadata columns on `advisor_source_chunks`:
  `embedding_provider_id`, `embedding_model_id`, and `embedding_dimension`.
- Added HNSW cosine partial index for ready Voyage `voyage-4-large`
  `vector(1024)` rows.
- Added `public.advisor_search_chunks(...)` for scoped top-K candidate
  retrieval with citation/provenance metadata.
- Updated generated embedding SQL to write both legacy `embedding_model` and
  the provider/model/dimension triple.
- Verified by `dart analyze` and `test/advisor_corpus_manifest_test.dart`
  (22 tests passed).

### `11a.9` Rerank Smoke Through Provider

Accepted 2026-04-25.

- Added a corpus rerank smoke runner that consumes vector-search-style
  candidate rows.
- Routed ordering through `RerankProvider` using fake-tested
  `VoyageRerankProvider`.
- Preserved chunk citation/provenance metadata plus original vector
  similarity/distance.
- Verified by `dart analyze`,
  `test/advisor_corpus_manifest_test.dart`, and
  `test/provider_abstraction_test.dart` (69 tests passed).

### `11a.10a` Proxy Infrastructure Scaffold

Accepted 2026-04-25.

- Added `tool/advisor_proxy/` with a pure Dart, Cloud Run-ready HTTP scaffold.
- Proxy config validates required secret names and keeps values out of
  diagnostics/logging.
- Added interface-based JWT verification, hard-fail-closed default verifier,
  bearer extraction, and operator/location scope guard.
- Added unauthenticated `GET /healthz` and protected `GET /v1/scope` smoke
  route. No provider, Supabase, Firebase, or Flutter runtime calls.
- Verified by `dart analyze` and `test/advisor_proxy_test.dart`
  (21 tests passed).

## Archived Active Tracker Summaries (moved 2026-04-02)

These summaries previously lived in the active tracker and were moved here to keep `PROJECT_TRACKER.md` focused on current work and next prompts.

### Phase 9 Planning Baseline

Detailed Phase 9 execution planning now lives in [phase_9_auth_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9/phase_9_auth_plan.md).

The active tracker should only carry:

- current Phase 9 status
- the next prompt in the Phase 9 ladder
- immediate prerequisites or blockers

The following planning truths were moved out of the active tracker and should now be read from the dedicated auth plan instead:

- one shared email/password Firebase Auth system across Forge & Flow and Barrio
- Firestore as the canonical profile, role, permission, and later shared learning-data store
- SQLite remains local operational/cache data only
- login persists until explicit logout
- no guest mode
- no PIN auth
- no biometrics
- Forge & Flow is the commercial baseline app
- Barrio is the internal superset shell
- Forge & Flow does not depend on Barrio
- Barrio consumes the shared Forge & Flow runtime
- permission keys stay fixed and app-defined
- seeded roles ship with recommended defaults, remain editable, and admins may create custom roles
- Phase 9 implementation is broken into `9a` through `9e` plus `9.5`
- Firebase setup and trusted admin-backend setup are explicit checkpoints and must be confirmed before implementation is treated as complete

## Archived Active Tracker Notes (moved 2026-04-14)

These notes previously lived in the active tracker's guardrails section. They
were moved here once `7.55p.5` was complete and `7.55q` became the active lane,
so `PROJECT_TRACKER.md` could stay focused on the current conformance work and
next prompts.

### `7.55p.5` Closeout Detail

- `7.55p.5` landed through `7.55p.5j`:
  - `7.55p.5b` confirmed the current OPZ width is honest selected-range truth
  - `7.55p.5c` / `5d` / `5e` locked the target-package split and verified
    Variance/the blended-wage paths
  - `7.55p.5f1` simplified wage setup without creating a second
    wage-authority path
  - `7.55p.5g` / `5h` landed the app-owned recommendation service plus honest
    graph fallback behavior
  - `7.55p.5i` / `5j` landed the planned labor package contract and Schedule
    wiring without altering Benchmark / Variance theoretical ownership

### `7.55p.5f1` Wage Authority UX Note

- `7.55p.5f1` landed the Settings whole-mix wage setup flow without creating a
  second wage authority path:
  - one simple whole-mix setup flow for FOH / BOH / management roles
  - still persist/resolve through the same wage authority seam
  - widget tests now drive the real save path and prove the override trickles
    into target/theoretical wage consumers the same way the fallback-role
    editor did

### Recommendation Service / Graph Follow-up Note

- the parked benchmark-recommendation issue was integrated into the plan:
  - the default recommended benchmark set can visually degenerate toward the
    full historical range
  - treat this as a recommendation/data-selection problem, not a
    graph-rendering problem
  - recommendation logic should live in an app/domain service, not widget code
  - preferred statistical direction:
    - eligibility gates
    - daypart-first stratification
    - robust outlier labeling (median + MAD, IQR sanity checks)
    - stable high-performance cluster selection
    - trimmed-mean or median target derivation
  - `7.55p.5g` landed the app-owned recommendation service, cycle write-path
    seam, and explicit restaurant-scope routing fix
  - `7.55p.5h` landed the Benchmark graph/explainer fallback so weak /
    insufficient / wide-union recommendation states now teach honestly and
    survive fresh load

### Planned Package Follow-up Note

- the planned-package follow-up was integrated into the plan:
  - add a scope-aware planned labor package for daypart / day / week planning
    surfaces
  - derive planned labor % from planned labor dollars divided by forecast sales
    at the same scope
  - do not average percentages across rows; aggregate dollars and sales, then
    recompute %
  - use this for planning/day tables and full-week planning/projection
    surfaces without replacing Variance's theoretical package
  - `7.55p.5i` landed the contract for planned labor % as a planning metric at
    daypart / day / week scope with explicit aggregation, degradation, and
    surface-ownership rules
  - `7.55p.5j` landed the app-owned planned labor package seam and wired it
    into Schedule's planning-facing week/day/daypart surfaces without touching
    Benchmark / Variance theoretical ownership

### Phase 7.53 Summary

All sub-prompts (`7.53a` through `7.53f` plus polish) are complete.

## Archived Active Tracker Cleanup (moved 2026-04-25)

These notes previously lived in the active tracker. They were moved here once
`7.57` became the active stabilization lane so `PROJECT_TRACKER.md` could stay
focused on current gates, next prompts, and live guardrails.

### Completed Phase Summary Moved From Active Tracker

| Phase | Archived completion summary |
| --- | --- |
| `7.55l` | `TargetCycle` + `WeeklyPlanSnapshot` runtime architecture landed. |
| `7.55m` | Runtime-truth cleanup landed. |
| `7.55k` | Daypart / Variance / History / Learn plan landed through `7.55k.8a`. |
| `7.55n` | Restaurant timing + service-period runtime foundation landed through `7.55n.6a`; freshness / live-data extension landed through `7.55n.13`. |
| `7.55p.1` | Shift driver trust audit landed against Chapter 10. |
| `7.55p.2` | Variance WTD target alignment and Full Week target-package / carry-forward cleanup landed through `7.55p.2a`. |
| `7.55p.3` | Dollar Impact accumulation model landed through `7.55p.3a`. |
| `7.55p.4a` | App-owned refresh / invalidation policy landed through `7.55p.4a1`. |
| `7.55p.4b` | Connector-fed live freshness propagation landed through `7.55p.4b1`. |
| `7.55p.4c` | Replay integrity / mock-to-live transition audit landed through `7.55p.4c1`. |
| `7.55p.4d` | Persisted passive notifications landed through `7.55p.4d1`. |
| `7.55p.5` | Benchmark OPZ / graph honesty audit, OPZ-width research, target-labor package contract, Variance theoretical-package verification, blended-wage audit, recommendation-statistics contract cleanup, wage-mix setup UX, app-owned recommended benchmark selection, Benchmark graph fallback/explainer cleanup, and planned labor package wiring landed through `7.55p.5j`. |
| `7.55q` | Architecture-conformance lane landed through `7.55q.10`: single-plan / single-benchmark-target contract, non-closed Variance 1:1 rewiring, History locked-target truth, planned labor cleanup, whole-day Shift target alignment, cycle-backed Benchmark override wiring, and Dollar Impact parity. |
| `7.55o` | Shared-surface extraction completed through `7.55o.6`: shared comparison primitives, Variance shell split, Schedule planning separation, Settings surface split, Baseline Manager decomposition, and SQLite bootstrap breakup. |
| `7.55r` | Foundation closeout completed through `7.55r.2`: dev-only audit read service, locked-week / target-cycle provenance, UTC metadata and WTD audits, service-period runtime wiring verification. |
| `7.56` | Reservation-book signal verified in `7.56a`; `7.56b` closed benchmark-selection-summary replay stability; `7.56c.0` and follow-ups aligned Full Week Plan / Benchmark authority; `7.56c.1` expanded the dev-only audit into live/actual + Plan/Benchmark source-alignment checks. |

### Completed `7.57` Sub-Slice Detail Moved From Active Tracker

- `7.57.0` codified the service-layer split, RLS-ready schema rule,
  phase-doc hygiene rule, and five hard architectural promises in
  `CLAUDE.md`.
- `7.57.1` legacy fixture extraction accepted:
  - `7.57.1a` moved runtime defaults, lever metadata, and pure value types to
    `lib/data/app_defaults.dart`.
  - `7.57.1b` moved demo sample-data definitions to
    `lib/dev/demo_fixture_data.dart` and swept production importers off
    `legacy_fixture_data.dart`.
  - `7.57.1c` migrated tests off the shim and deleted
    `lib/data/legacy_fixture_data.dart`.
- `7.57.2a` moved state holders and refresh coordination to `lib/state/`.
- `7.57.2b` moved `fixture_seed_data.dart` to `lib/dev/` and
  `database_helper.dart` to SQLite infrastructure.
- `7.57.2c` moved nine runtime read/orchestration services from `lib/data/`
  to `lib/services/`.
- `7.57.2d` moved the baseline / benchmark service cluster:
  `baseline_manager_service.dart`, `baseline_selection_analytics_service.dart`,
  and `benchmark_tracker_read_service.dart` to `lib/services/`, and
  `recommended_benchmark_selection_service.dart` to `lib/domain/services/`.
- `7.57.2e` moved `TargetCycleService` from `lib/data/` to
  `lib/services/`, preserving TargetCycle logic and rewiring imports only.
- `7.57.2f` moved `ShiftService` from `lib/data/` to `lib/services/`,
  preserving Shift runtime logic and rewiring imports only.
- `7.57.2g` moved `ShiftDataSource` from `lib/data/` to `lib/services/`,
  leaving `lib/data/` with only `app_defaults.dart` and
  `mock_integration_replay_seed.dart`.
- `7.57.2` parent closed: state holders live in `lib/state/`, runtime
  orchestration in `lib/services/`, pure deterministic domain services in
  `lib/domain/services/`, demo fixtures in `lib/dev/`, and SQLite
  infrastructure in `lib/infrastructure/persistence/sqlite/`.

### Archived Carry-Forward Notes

- `7.56c.1` retained the rule: do not compare live operating results against
  targets as drift.
- UX shell work is landed: shared sticky/fading headers, Shift header/live-time
  polish, Variance / History / Learn shell cleanup, Plan / Benchmark header-stat
  cleanup, and Settings visual rework.
- `7.55j.3` vendor endpoint checklist template and `7.55j.4` gap report remain
  the pre-Phase-8 vendor-readiness historical authority.
- `docs/internal/status_ledger_post_7_55p_deep_check.md` remains the reference
  sheet for older asks, post-`7.55o` naming/copy/refactor audit ideas, and later
  readiness-check context.
- Pre-launch sequencing truth remains: Phase 10a is pre-launch shared
  multi-device state; Phase 10.5 owns additive whole-day + daypart Shift
  behavior; advisor work ships before Phase 9.75 Barrio V1.1; Phase 10b sits
  between `11b.2` and Phase 8.
- `DataAlignmentAuditPanel` cycle/week provenance landed in `7.55r.1`.
- Persisted timing/service-period wiring closeout verified in `7.55r.2`.
- UTC metadata timestamp normalization and non-locked WTD membership audit are
  documented in `7.55r` as closed / no-patch findings.
- Legacy q-lane contract notes remain authoritative in the active contract
  docs, not in the working tracker: `TargetCycle` locks 60-day standards;
  locked weekly plan is the in-force comparison authority; Benchmark sets the
  standard, Plan decides the week, Shift manages now, Variance compares plan vs
  actual, History preserves closed truth, and Learn teaches repeated closed
  results.

Key outcomes:

- Dual native build identities (ForgeFlow + Barrio) with separate Android flavors, iOS schemes, icons, and splash
- Shared Forge & Flow runtime boundary extracted; Barrio consumes it
- Premium teaching UI: PageView carousel, 3D perspective, card press/glass/expand, worm dots, enhanced sparkle, photo backgrounds
- All content complete from source PDFs/HTML: 86 units across 13 chapters/sections/modules, zero placeholders
- Answer positions shuffled (A=10, B=9, C=8), unique badgeHint per unit, 13 rail icons verified from Flutter SDK
- El Podio scoreboard with Phase-9-ready `PodioEntry` model + home screen button
- Preston Lee cleaned for UI consistency; Phase 9 Barrio requirements documented
- Performance: film grain removed, carousel breathing removed, blur radii halved
- Colour-temperature scrim breathing on home screen (12s warm↔cool loop)
- 513 tests passing, 0 errors
- Final iOS build/run verification still needs a macOS/Xcode pass before release confidence

### Phase 7.54 Summary

All sub-prompts (`7.54a` through `7.54c`) are complete.

Key outcomes:

- `7.54a`: Repaint boundaries, lifecycle animation gating, merged animation listeners, cache-sized image decode paths on hottest Barrio surfaces
- `7.54b`: Dynamic `IconData` blockers replaced with constant icon mappings for release icon tree shaking; heavy PNG backgrounds converted to JPEG; `handbook_icon.png` recompressed; release split APK build succeeds without `--no-tree-shake-icons`; focused Barrio tests passing
- `7.54c`: `handbook_icon.png` moved from shared `assets/images/` to `assets/internal/barrio/`; confirmed `branding/` and `inspiration/` subdirectories not bundled; documented Flutter toolchain limitation — `pubspec.yaml` does not support flavor-conditional asset bundling, so ForgeFlow still carries ~2 MB of Barrio-private runtime assets as dead payload; README updated with build-size/cleanup/containment documentation

### Phase 7.55a Summary

Font size, readability, and accessibility pass based on real user feedback that text was too small on mobile devices and the Manager Override button in Baseline was too small.

Key outcomes:

- Raised floor on core text styles and bottom-nav labels
- Manager Override button enlarged with larger text, stronger padding, larger icon, and clearer fill/border treatment
- Barrio inline font-size floor raised across multiple files
- Dense Forge & Flow widgets received spacing/overflow fixes
- Shift dashboard, schedule cards, zone-status label, and El Podio home button received targeted layout fixes
- Tests remained green

### Phase 7.55b Summary

Schedule demand-source clarity pass based on the presentation issue that the Schedule table implied covers drove both FOH and BOH hours.

Key outcomes:

- Kept `LaborModel` as the single formula source.
- Added `LaborModel.modelBohHoursFromSales(forecastSales, targetSPLH)` as the primary BOH required-hours formula.
- Kept `LaborModel.modelBohHours(covers, ppa, targetSPLH)` as a compatibility helper that derives sales as covers * PPA.
- Added `forecastedSales` to `ScheduleForecastNotifier`.
- Added `forecastSales` to Schedule day and daypart row view models.
- Updated Schedule BOH required hours to calculate from forecast sales, not directly from covers.
- Updated the Schedule table from `DAY | COVERS | FOH HRS | BOH HRS` to `DAY | COVERS | SALES | FOH HRS | BOH HRS`.
- Added short manager-facing Schedule copy: `FOH plans from covers. BOH plans from forecast sales.`
- Added focused `test/labor_model_boh_sales_test.dart` coverage for the sales-first BOH seam and Schedule notifier behavior.
- Did not add live POS, labor, OpenTable, or reservation transport.
- Did not change active target profile behavior, labor math, Shift math, Variance math, or database schema.

Verification recorded on 2026-04-09:

- `flutter analyze` passed.
- `flutter test test/labor_model_boh_sales_test.dart test/target_consistency_opz_test.dart` passed.
- Full `flutter test` passed with 533 tests.
- `git diff --check` reported no whitespace errors; only expected CRLF warnings.

### Phase 7.55c Summary

Schedule forecast demand-source planning and the first app-side implementation are documented in `docs/phase_7_55c_schedule_forecast_demand_source_plan.md`.

Key outcomes:

- Baseline supplies standards and exposes the POS-history context used by Schedule.
- POS 60-day history supplies forecast demand through historical weekly average covers.
- `LaborModel` combines standards and demand.
- Added `ForecastDemandSource` and `ScheduleForecastDemand` as app-owned demand/provenance models.
- Added `ScheduleForecastDemandResolver` with an explicit waterfall: POS 60-day historical weekly average covers, demo fallback only when enabled, then unavailable.
- Forecast sales is always derived as forecast covers * target PPA.
- Forecast covers always come from POS 60-day history (historicalWeeklyAvgCovers ÷ (60/7) weeks). Sales always derived as covers × target PPA. No vendor forecast inputs, no manager editing on Schedule — manager influence is Baseline target profile override only.
- Historical weekly average covers is now the normal Schedule seed when no explicit forecast exists; the old `1200` value remains only as an explicit demo fallback.
- Schedule displays `Forecast source: 60-day weekly average` as read-only provenance.
- No live POS, forecast, labor, OpenTable, or reservation transport was added.

Remaining integration caveat:

- Schedule render state is now resolver-backed, but it is still fed by the compatibility BaselineData bridge. Future Phase 8 work should replace fixture transport with live POS closed-shift history feeding the same 60-day historical context, not introduce vendor-provided forecast values.

Verification recorded on 2026-04-10:

- `flutter analyze` passed.
- `flutter test test/schedule_forecast_demand_resolver_test.dart test/labor_model_boh_sales_test.dart test/target_consistency_opz_test.dart` passed with 63 tests.
- Full `flutter test` passed with 541 tests.
- `git diff --check` reported no whitespace errors; only expected CRLF warnings.

### Phase 7.55 In-Progress Stabilization Notes

Phase 7.55 remains in progress. The following hotfix/stabilization work has landed or is currently being carried inside the 7.55 lane, but the phase should not be treated as complete until final verification and tracker review are done.

Dashboard layout restructure:

- Reordered the Shift dashboard flow from OPZ -> Variance -> Inputs -> Hours -> Driver to Sales -> Labor% -> Inputs -> Productivity -> Driver.
- Added a new Sales vs Forecast card with a fill-toward-goal progress bar.
- Placed Sales and Labor% side by side in a consolidated output row.
- Moved Covers and Blended Wage into the new SHIFT OUTPUTS section.
- Moved FOH HRS and BOH HRS into SHIFT INPUTS alongside PPA, CPLH, and SPLH.

Card standardization:

- Standardized card anatomy across metric cards: label -> value -> target reference -> delta pill.
- Standardized card padding, border accents, and label color treatment.
- Removed progress bars from Labor% and Hours while keeping the Sales progress bar.
- Renamed visible "Model" references to "Target" for blended wage and hours contexts.

OPZ / productivity simplification:

- Removed sub-label text from `ZoneStatusCard`.
- Repositioned CPLH value and OPZ status onto one row with right-justified status.
- Added `FittedBox` overflow safety for the OPZ label.
- Renamed the section label to FOH PRODUCTIVITY.

Section labels:

- Added SHIFT OUTPUTS section header.
- Added SHIFT INPUTS section header.
- Added PRIMARY DRIVER section header with a lightbulb icon.

Visual design overhaul:

- Warm palette and readability improvements are represented in commit `c7baced`.

Hours lever logic:

- Added four new lever types: `foh_hours_over`, `foh_hours_under`, `boh_hours_over`, and `boh_hours_under`.
- Added +/-10% threshold handling in `LaborModel.determineLever()` with lowest priority.
- Added four new `LeverCardData` cards with manager-speak narratives.
- Wired the new lever family through dashboard, WTD, historical, and shift-close call sites.
- Updated `LaborModel.isFavorableLever()` for the new hour levers.

Schedule demand-source alignment:

- Clarified Schedule presentation so COVERS and SALES are distinct columns.
- Preserved FOH required hours as forecast-covers driven.
- Moved Schedule BOH required hours onto a forecast-sales-first formula seam.
- Kept forecast sales derived from forecast covers * target PPA.
- Added focused coverage proving the sales-first BOH helper and existing covers/PPA helper stay numerically aligned.
- Planned and implemented the first app-side forecast-demand source model so POS-history forecast covers, derived forecast sales, historical weekly-average fallback, demo fallback, and provenance can be handled explicitly.

Removed / cleaned up:

- Removed `_LaborOverviewCard`.
- Removed `_LaborOverviewPanel`.
- Removed `_HoursSection`.
- Removed `_SideSummaryCard`.
- Removed `_VarianceBannerDelegate`.
- Removed the variance banner import from the Shift dashboard.

### Phase 7.56a Summary

Phase 7.56a is complete on the app-side demo path. It does not implement live OpenTable or reservation-platform transport; official live integration remains Phase 8R.

Key outcomes:

- Added `ReservationBookSnapshot` as the app-owned aggregate for one restaurant, business date, and daypart.
- Added repository, SQLite DAO, and SQLite repository boundaries for reservation-book snapshots.
- Bumped SQLite schema to v11 and added the `reservation_book_snapshots` table.
- Seeded the demo Friday dinner open shift with `72` unseated covers and `18` unseated parties.
- Wired the Shift dashboard notifier/service to fetch reservation snapshots by `restaurantId`, `businessDate`, and `daypart`.
- Added optional `inTheBooksCovers` to the Shift dashboard read model.
- Rendered `In the books 72` under the COVERS card forecast line when a reservation snapshot exists.
- Kept the support line hidden when no reservation snapshot exists.
- Kept reservation-book data out of actual covers, forecast covers, labor math, OPZ math, and lever math.
- Added repository, notifier, and widget coverage for the reservation signal.

Verification:

- `flutter analyze` passed.
- `flutter test test/reservation_book_snapshot_repository_test.dart` passed.
- `flutter test test/shift_dashboard_notifier_test.dart` passed.
- `flutter test test/shift_visual_widget_test.dart` passed.
- `flutter test test/target_consistency_opz_test.dart` passed after stale 7.55 OPZ sub-label expectation was aligned with the current `ZoneStatusCard` contract.
- Full `flutter test` passed with 525 tests.
- `git diff --check` reported no whitespace errors; only expected CRLF warnings.

Commit hygiene note:

- The working tree currently mixes Phase 7.55 stabilization edits, the `7.55b` Schedule BOH sales-first seam/test, Phase 7.56 reservation signal work, tracker/docs updates, and the stale OPZ test-contract cleanup.
- Before committing or opening review, prefer separate commits by phase and purpose:
  - 7.55 dashboard/readability/hours-lever stabilization
  - 7.55b Schedule demand-source alignment
  - 7.56 reservation book signal demo
  - tracker/docs updates
  - OPZ stale-test cleanup
- If the work is committed together, the commit message should explicitly name the mixed scope so future archaeology does not treat the whole diff as only `7.56a` or only `7.55b`.

### Superseded Phase 9 Barrio Requirements

The earlier tracker-only Barrio auth notes have now been superseded by the full Phase 9 auth contract in `docs/phases/phase_9/phase_9_auth_plan.md`.

The important carry-forward points were:

- learning completion was still in-memory only
- streak tracking was global and not user-scoped
- no real user identity flowed into Barrio learning screens
- El Podio was still demo-backed
- preview-role dimming was still visual-only and not real enforcement

## Archived Phase Board (moved 2026-05-06)

Retired from the active Phase Board once each phase reached ACCEPT/closed with
no remaining work tracked under that label. Phase docs marked under
`docs/archive/phases/` were retired per CLAUDE.md "Phase Doc Hygiene"; longer
plans referenced under `docs/phases/**` remain available for the dependent
lifecycle / fanout / cutover work that is still open in the active tracker.

| Phase | Final state | Plan |
| --- | --- | --- |
| `7.58` | closed 2026-05-05 — advisor-depth-complete; all 5 depth-wave slices ACCEPT | `docs/archive/phases/phase_7_58/` |
| `7.61` | closed — all 4 non-deferred slices accepted | `docs/archive/phases/phase_7_61/` |
| `10.5` | closed — all 4 slices accepted | `docs/archive/phases/phase_10_5/` |
| `10a` | closed for V1 2026-05-06 — `.0`/`.1`/`.2`/`.3`/`.4`/`.5` + `UX.0`/`UX.1` ACCEPT | `phase_10a/*` |
| `8.spine-bridge` | ACCEPT 2026-05-05 — 11 sub-lanes + `.4` proof v2 PASS 27/27 | `phase_8/phase_8_spine_bridge_plan.md`, `docs/_execution/2026-05-05_8_integration_mobile_proof_v2_execution.md` |
| `8.spine-bridge-live` | ACCEPT 2026-05-06 — `OpenShiftSnapshotProjector` + Lane 4 mobile/proxy enrichment + closed-timing provenance components landed; first-connect wire-in exercises the post-commit projector under fixture proof. Live provider/device proof remains future lifecycle/E2E work. | `phase_8/phase_8_spine_bridge_plan.md`, `phase_business_timing_live/business_timing_live_plan.md`, `docs/_execution/2026-05-06_8_live_and_closed_truth_proof_execution.md` |
| `8.first-connect-backfill-wire-in` | ACCEPT 2026-05-06 — closes Doc 1 first-connection path under fixture proof: connect -> first backfill job -> adapter.backfill -> canonical facts -> closed rows/open snapshots -> proxy/mobile cache | `docs/contracts/mobile_core_first_connection_backfill_contract.md`, `docs/_execution/2026-05-06_mobile_core_first_connection_backfill_sprint_plan.md`, `docs/_execution/2026-05-06_8_first_connection_backfill_proof.md`, `docs/_walkthroughs/8.first-connect-backfill.md` |

## Completed Prompt History

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 0 | Software engineering plan | Done | Architecture and sequencing defined |
| Prompt 1 | Canonical domain foundation | Done | Foundation files added; no UI adoption yet |
| Prompt 2 | History from real tracked shift facts | Done | Runtime teaching summary now flows through stored closed-shift records |
| Prompt 3 | closeShift ingest path | Done | Canonical ingest path landed; one WTD follow-up remains |
| Prompt 3.1 | WTD source-fact plumbing fix | Done | WTD now carries stored closed-shift labor dollars with fallback preserved |
| Prompt 4 | Target consistency + OPZ cleanup | Done | Core target swaps landed across Schedule, Shift, and OPZ surfaces |
| Prompt 4.1 | OPZ source-of-truth + test stabilization | Done | ZoneStatusCard gauge centralized and Prompt 4 tests hardened |
| Prompt 4.2 | Baseline OPZ graph catch-up | Done | Attempted graph catch-up, but visual intent was clarified afterward |
| Prompt 4.3 | Baseline target-line visual correction | Done | Direction improved, but Chapter 9 to 12 intent was clarified again afterward |
| Prompt 4.4 | Baseline range + OPZ + recommended target visual correction | Done | Direction tightened, but runtime OPZ source mismatch remained |
| Prompt 4.5 | Baseline graph visual refinement | Done | Graph moved closer to intended composition |
| Prompt 4.6a | Baseline graph semantics truth pass | Done | Added truthful range graph model from existing historical source set |
| Prompt 4.6b | Baseline graph paint pass | Done | Widget now paints from the graph model, but OPZ source still diverged across tabs at that point |
| Prompt 4.7 | Historically derived OPZ unification | Done | Baseline, Shift, and the range graph now read the same OPZ source from selected historical records |
| Prompt 4.8 | Baseline graph visual polish | Done | Full-width graph and Shift-graph-style palette/emphasis landed without changing logic |
| Prompt 5 | Baseline Manager from history | Done | History-backed selection flow landed with persisted selection and runtime override path |
| Prompt 5.1 | Baseline manager screen contract fix | Done | Draft preview and zero-selection clear behavior are in place |
| Prompt 5.2 | Phase 5 continuation under propagation/debug guardrails | Done | Override visibility and cross-tab propagation now behave through the existing revision-based update path |
| Prompt 6 | Variance visual overhaul | Done | Variance readability, typography, and visual hierarchy improved without changing formulas or data sourcing |
| Prompt 7.53a | Native config split + runtime-boundary hardening | Done | Android flavors, iOS schemes/configurations, ids, display-name wiring, thin entrypoints, extracted shared runtime boundary |
| Prompt 7.53b | iOS per-flavor asset catalog split | Done | ForgeFlow vs Barrio iOS app icon sets, launch storyboards, launch asset references |
| Prompt 7.53c | Premium teaching UI + learning surface overhaul | Done | PageView carousel, 3D perspective, card press/glass/expand, worm dots, enhanced sparkle, photo backgrounds, colour-temperature breathing, perf optimizations |
| Prompt 7.53d | Content fix + answer shuffle + icon alignment | Done | Shuffled answers (A=10 B=9 C=8), filled all 4 scaffolded areas, badgeHint on all 86 units, 13 rail icons verified from Flutter SDK |
| Prompt 7.53e | El Podio scoreboard + home screen integration | Done | Premium podium top-3, demo users (Brian/Emily/Amy/Priya), Phase-9-ready PodioEntry with userId, frosted glass home button |
| Prompt 7.53f | Preston Lee + UI consistency + Phase 9 prep | Done | Removed audience tags/banner, fixed icon mismatch, increased comingSoon dimming, documented Phase 9 Barrio requirements |
| Prompt 7.54a | Barrio thermal/render-cost pass | Done | Repaint boundaries, lifecycle animation gating, merged animation listeners, cache-sized image decode paths on hottest Barrio surfaces |
| Prompt 7.54b | Release-size and asset-compression pass | Done | Dynamic IconData blockers replaced with constant icon mappings; heavy PNGs converted to JPEG; handbook_icon recompressed; release split APK builds without --no-tree-shake-icons; 47 focused tests passing |
| Prompt 7.54c | Flavor asset-bundle containment + space hygiene | Done | handbook_icon.png moved to Barrio-private dir; branding/inspiration confirmed not bundled; Flutter flavor-conditional limitation documented with real APK evidence; README updated with build-size/cleanup/containment docs; 47 focused tests passing |
| Prompt 7.55a | Font size / readability / accessibility pass | Done | Theme floor raised, Manager Override button enlarged, Barrio inline sizes fixed, layout overflow fixes landed, El Podio full-width, tests passing; Phase 7.55 remains open as a stabilization lane |
| Prompt 7.55b | Schedule FOH/BOH demand-source clarity | Done | Schedule now presents COVERS and SALES separately; FOH required hours remain cover-driven; BOH required hours use the new sales-first `LaborModel.modelBohHoursFromSales` seam; compatibility wrapper preserved; analyzer and full 533-test suite pass |
| Prompt 7.55c | Schedule forecast demand-source model | Done | Covers always from POS 60-day history; sales always derived as covers × PPA. Removed vendor forecast inputs, manager editing, and sales-to-covers derivation. Enum simplified to 5 values. Resolver waterfall: historical avg → demo → unavailable. Schedule is read-only with provenance display. Manager influence is Baseline target profile override only. Analyzer clean, 541 tests pass. |
| Prompt 7.56a | Reservation Book Signal Demo | Done | App-side `ReservationBookSnapshot` model/repository/SQLite cache added, demo Friday dinner seeded with 72 unseated covers, Shift read model and COVERS card render optional `In the books`; no live vendor transport; analyzer and full 525-test suite pass |
| Prompt 6.1 | Baseline context + benchmark-range alignment | Done | Historical context metrics are separated, best/worst cards removed, and Baseline range-quality messaging now uses benchmark-range states |
| Prompt 6.2 | Baseline historical-range honesty pass | Done | Baseline graph now keeps historical outer anchors, renders the benchmark range inside that context, and displays total covers as a count |
| Prompt 7 | Learn layer | Done | Variance now includes a Learn tab that combines recurring history patterns with active Baseline benchmark truth |
| Prompt 7.1 | Learn teaching-copy alignment | Done | Learn copy now stays pinned to analyzer-owned text and existing Jim-aligned repo teaching sources |
| Prompt 7.11 | Shift dynamic truth alignment | Done | Shift hero-card emphasis and the bottom teaching line now follow the runtime active lever instead of static demo wiring |
| Prompt 7.12 | Shift readability + OPZ presentation polish | Done | Shift presentation now reads more clearly while preserving the runtime active-lever truth from Prompt 7.11 |
| Prompt 7.13 | Variance coaching layout cleanup | Done | Variance now uses cleaner coaching groupings, stronger readability, and a single consistent dollar-summary treatment |
| Prompt 7.14 | Learn depth from structured teaching sources | Done | Learn now teaches deeper recurring-leak and benchmark-pattern guidance from analyzers plus existing lever-card content |
| Prompt 7.15 | History + Learn premium surface alignment | Done | History drill-ins now use the grouped premium Variance table language and Learn/History styling now matches the upgraded This Week surface |
| Prompt 7.15a | History drill-in dollar-impact sign fix | Done | Fixed the annualized sign-formatting issue in the History detail `DOLLAR IMPACT` card |
| Prompt 7.5a | Persistence and scope alignment | Done | Restaurant scope, SQLite bootstrap/DAO/repo split, additive migration/backfill, raw import tracking, and compatibility delegation landed |
| Prompt 7.5a.1 | 7.5a correctness follow-up | Done | Fixed destructive v7 migration behavior and explicit restaurantId propagation through the close-shift domain path |
| Prompt 7.5a.2 | week_records scoped migration fix | Done | Upgraded pre-v7 week_records now rebuild into restaurant-scoped uniqueness with real upgrade-path coverage |
| Prompt 7.5a.3 | 7.5a contract completion cleanup | Done | DatabaseHelper now delegates and fixture replay raw import metadata carries true business-date semantics |
| Prompt 7.5a.4 | raw import businessDate fallback fix | Done | Fixture replay business_date now always resolves to a real ISO date string |
| Prompt 7.5b | Target-state alignment | Done | Active target profile persistence, immutable target-profile versions, locked historical target truth, and explicit WTD target injection landed |
| Prompt 7.5b.1 | historical target fallback removal | Done | WeekRecord, week rollups, and WeekData no longer drift back to current-global target state |
| Prompt 7.5b.2 | target provenance backfill + upgrade coverage | Done | Legacy historical shifts now receive compat target-profile provenance and pre-v8 upgrade coverage was added |
| Prompt 7.5b.3 | partial migration provenance repair | Done | Partially migrated rows now repair missing target-profile identity and upgrade-path tests rehydrate migrated model rows |
| Prompt 7.5c | Live-state and replay alignment | Done | Open/current-state persistence, Shift dashboard read models, and repository-backed Full Week state landed |
| Prompt 7.5c.1 | live current-week + open-row semantics fix | Done | Live WTD now resolves the persisted current week and open rows stay open in merged Full Week state |
| Prompt 7.5c.2 | final current-state contract cleanup | Done | Current-week fallback is deterministic and repository-backed, and open rows no longer show projected-only copy |

## Archived Progress Log

Use one line per meaningful session.

| Date | Phase | What changed | Result | Next |
| --- | --- | --- | --- | --- |
| 2026-04-10 | Phase 7.55c.2 | Schedule forecast demand-source model implemented and Codex-verified | `ScheduleForecastDemand` + resolver now seed Schedule from POS-history weekly average covers; forecast sales derives as covers * target PPA; source provenance displays in Schedule; analyzer, focused run, full 541-test suite, and diff check pass | Preserve commit hygiene; Phase 8 should replace fixture transport with live POS closed-shift history feeding this same derivation |
| 2026-04-09 | Phase 7.55b | Schedule demand-source presentation and BOH architecture seam implemented and Codex-verified | Schedule table now separates COVERS from SALES; BOH required hours flow through forecast sales while forecast sales derives from covers * PPA; analyzer, focused tests, full 533-test suite, and diff check pass | Preserve commit hygiene, visually spot-check the denser Schedule table on device, then continue toward `9a.1` when 7.55 closeout is acceptable |
| 2026-04-09 | Phase 7.55c planning | Schedule forecast demand-source model documented | Captured the original forecast-source gap and led to the corrected 7.55c.2 rule: forecast covers come from POS 60-day history, forecast sales derives as covers * target PPA, Schedule is read-only, and manager influence stays in Baseline target profile override | Implemented and superseded by 7.55c.2 |
| 2026-04-09 | Phase 7.56a | Reservation Book Signal Demo implemented and Codex-verified | App-side reservation snapshot cache feeds `In the books` on the Shift COVERS card; no live vendor transport; analyzer and full 525-test suite pass | Preserve commit hygiene, then move toward `9a.1` after remaining 7.55 stabilization review |
| 2026-04-09 | Phase 7.55 / 7.56 hygiene | Dirty tree reviewed after Claude work | Worktree currently mixes 7.55 stabilization, 7.56 reservation demo, docs/tracker edits, and one stale OPZ test-contract cleanup | Split commits by phase/purpose where practical, or explicitly label mixed scope in commit message |
| 2026-03-28 | Planning | Software plan completed | Prompt order revised around integration foundation | Run Prompt 1 |
| 2026-03-28 | Phase 1 | Canonical domain foundation added | ClosedShiftInput, TargetSnapshot, ShiftFact, and builders landed without UI rewiring | Run Prompt 2 |
| 2026-03-28 | Phase 2 | History teaching pipeline rewired to stored closed shifts | Runtime History summary now reads pattern records through the data layer instead of seeded manual pattern records | Run Prompt 3 |
| 2026-03-28 | Phase 3 | closeShift ingest path landed | Raw closed-shift input now persists source facts, replaces projected slots, and can create completed week records | Run Prompt 3.1 |
| 2026-03-28 | Phase 3 | WTD source-fact plumbing completed | This Week now carries stored closed-shift labor dollars through WeekData instead of config-only fallback math | Run Prompt 4 |
| 2026-03-28 | Phase 4 | Target consistency and OPZ framework landed | Schedule and Shift now use baseline-derived targets; OPZ validation is centralized, but one gauge/test follow-up remains | Run Prompt 4.1 |
| 2026-03-28 | Phase 4 | OPZ source-of-truth and test stabilization completed | ZoneStatusCard gauge now routes through BaselineData and Prompt 4 tests now validate framework behavior with widget coverage | Run Prompt 5 |
| 2026-03-28 | Verification | Full test suite completed | 209 tests passed (23 Prompt 4/4.1 related, 186 pre-existing) | Run Prompt 5 |
| 2026-03-28 | Phase 4 | Baseline OPZ graph drift identified | BaselineTracker message/rows are OPZ-aware, but the graph still needed a hybrid model: 60-day low/high scale with OPZ band and selected target overlaid | Run Prompt 4.2 |
| 2026-03-28 | Phase 4 | Baseline graph visual intent clarified | The primary graph should be a 60-day low-to-high line with a recommended target marker; OPZ should support the recommendation rather than dominate the graph | Run Prompt 4.3 |
| 2026-03-28 | Phase 4 | Jim Taylor Chapters 9 to 12 re-read applied | The graph should show the full 60-day lived range, define the sustainable OPZ within that range, and place the recommended target in that context | Run Prompt 4.4 |
| 2026-03-28 | Phase 4 | Baseline graph semantics corrected | Added a truthful graph read-model using true historical CPLH min/max while keeping the existing derived target intact | Run Prompt 4.6b |
| 2026-03-28 | Phase 4 | Baseline graph paint pass landed | Baseline graph now renders from the read-model, but exposed that OPZ was still config-driven while baseline range was historical-derived | Run Prompt 4.7 |
| 2026-03-28 | Phase 4 | Historically derived OPZ unification completed | Baseline, Shift, and the graph now share the same OPZ source from selected historical records | Run Prompt 4.8 |
| 2026-03-28 | Phase 4 | Baseline graph visual polish completed | The graph now reads full-width and aligns more closely with the Shift graph palette while keeping the math frozen | Run Prompt 5 |
| 2026-03-28 | Phase 5 | Baseline manager selection flow landed | Dedicated manager page, stored-history candidate pool, persistence, and cross-tab rebuild path are in place; one UI-contract follow-up remained | Run Prompt 5.1 |
| 2026-03-29 | Planning | Pre-Phase-8 alignment gate formalized | Added explicit Phase 7.5 and created repo-wide refactor plan so live adapters remain transport-only work | Finish Prompt 5.1, then Phases 6, 7, and 7.5 |
| 2026-03-29 | Planning | Phase 7.5 and 8 implementation details expanded | Trackers now define onboarding, backfill, continuous sync, raw import tracking, restaurant scope, and live/finalization lanes at implementation level | Finish Prompt 5.1, then Phases 6, 7, 7.5a-c, and 8.1-8.3 |
| 2026-03-29 | Planning | Pre-7.5 debugging guardrails added for Phases 5-6 | Current feature work now has trusted-surface rules so mixed demo-backed UI does not create false negatives while logic is still being finished | Continue Prompt 5.2, then Phase 6 under the same guardrails |
| 2026-03-29 | Phase 5 | Baseline manager flow completed | Stored-history candidate selection, persisted manager override, override banner, and revision-based propagation now work end to end; only minor button-label casing cleanup remains | Run Prompt 6 |
| 2026-03-29 | Phase 6 | Variance visual overhaul completed | Variance is easier to scan with larger type, stronger blue/teal hierarchy, and cleaner table/layout treatment while formulas stayed frozen | Run Prompt 6.1 |
| 2026-03-30 | Phase 6 | Baseline context split and benchmark-range validation landed | Historical context is now separate from active selected star shifts, Baseline top cards use historical context, and Baseline range-quality messaging replaced live Shift-style OPZ wording; one honesty follow-up remained for graph anchors and total-cover formatting | Run Prompt 6.2 |
| 2026-03-30 | Phase 6 | Baseline historical-range honesty pass completed | Baseline graph now keeps the 60-day historical outer range visible, shows the active benchmark range inside it, and renders total covers as a count | Run Prompt 7 |
| 2026-03-30 | Phase 7 | Learn layer landed with one teaching-copy follow-up | Variance now has a Learn tab that combines recurring history patterns with Baseline benchmark truth, but one narrow pass remained to remove newly authored prose where fixed Jim-aligned copy already existed | Run Prompt 7.1 |
| 2026-03-30 | Phase 7 | Learn teaching-copy alignment completed | Learn now stays pinned to analyzer-owned text and existing lever-card teaching copy, with no new UI-authored teaching prose in the Learn surface | Pause for bug review, then start Prompt 7.11 |
| 2026-03-30 | Stabilization | Shift dynamic truth alignment completed | Shift now derives its active lever, hero card, and bottom teaching line from runtime lever truth; small delta-format cleanup can roll into 7.12 | Run Prompt 7.12 |
| 2026-03-30 | Stabilization | Shift readability and OPZ presentation polish completed | Shift header, OPZ teaching widget, metric cards, and labor-variance strip are easier to read while keeping the runtime truth from 7.11 intact | Run Prompt 7.13 |
| 2026-03-30 | Stabilization | Variance coaching layout cleanup completed | WTD now reads as Conditions / Execution / Outcomes, duplicate dollar wording was removed, and History readability improved | Run Prompt 7.14 |
| 2026-03-30 | Stabilization | Learn depth pass completed | Learn now teaches deeper recurring-leak and repeatable-win patterns from History summaries, Baseline truth, and existing lever-card content | Start Phase 7.5 alignment gate |
| 2026-03-30 | Stabilization | History + Learn premium alignment completed | History list, week-detail drill-ins, and Learn now visually match the upgraded This Week Variance system without changing the underlying logic | Fix one tiny History dollar-impact sign issue in 7.15a |
| 2026-03-30 | Stabilization | History drill-in dollar-impact sign fix completed | The annualized value in the History detail `DOLLAR IMPACT` card now follows the same sign-format convention as the weekly value | Resume Phase 7.5 alignment gate |
| 2026-03-30 | Phase 7.5a | Persistence and scope alignment completed in small follow-ups | Restaurant scope, repository/DAO boundaries, additive migrations, import tracking, compatibility delegation, and raw-import date accuracy now align with the 7.5a contract | Run Prompt 7.5b |
| 2026-03-30 | Phase 7.5b | Target-state alignment completed in small follow-ups | Active target profile persistence, immutable target-profile versions, locked historical target truth, provenance backfill, and explicit WTD target injection now align with the 7.5b contract | Run Prompt 7.5c |
| 2026-03-30 | Phase 7.5c | Live-state and replay alignment completed in small follow-ups | Shift, Zone status hero, and Variance Full Week now read repository-backed current state, and fixture replay can drive the aligned app end to end | Run Prompt 8.1 |
| 2026-03-30 | Audit | Post-7.5 readiness review reopened the Phase 8 gate | Structural alignment landed, but remaining closed-shift drift, `BaselineData` bridge authority, missing vendor docs, and missing runnable-env proof require a short `7.51` closeout first | Run Prompt 7.51a |
| 2026-03-30 | Audit | Post-7.51 verification refined the remaining blockers | `7.51a` verified complete, but `7.51b/c` remained only partially closed due compatibility-bridge scope, pending replay states, TBD vendor profiles, and missing runnable Flutter proof | Run Prompt 7.51d |
| 2026-03-30 | Audit | Final code-side Phase 8 readiness pass completed | Connector-config persistence is safe, visible restaurant identity is scope-backed, Shift empty-state is truthful, and the repo is structurally ready for connector work; the remaining gate work is vendor selection plus rerunning the current 28-file corpus from the checked-in manifest | Run Prompt 7.51e |
| 2026-03-30 | Planning | Shift from 7.51e to 7.52 cleanup and private-build prep | 7.51e is complete on the app side; while Phase 8 waits on vendor selection, the next useful work is repo cleanup, product identity clarification, and a private Barrio layer inside the same repo | Run Prompt 7.52 |
| 2026-03-30 | Planning | Expanded 7.52 into an execution sequence for Barrio shell and private content | 7.52 is now broken into tracker lock, product identity cleanup, private boundary creation, dual-build prep, Barrio shell work, structured interactive content, and a clean Phase 9 handoff | Run Prompt 7.52a |
| 2026-03-30 | Planning | 7.52a execution contract locked | Added `docs/archive/phases/phase_7_52_execution_plan.md` so the Barrio shell vision, pre-auth role-aware structure, structured-content rule, and handoff into 7.52b-h are frozen in one place | Run Prompt 7.52b |
| 2026-03-30 | Phase 7.52b | Public product identity cleanup completed | Forge & Flow now appears as the public product across package/module naming, README, Android, iOS, and Windows visible app strings; the app title no longer reads restaurant scope as product identity; stale `Forge & Flow Demo` restaurant scope rows now normalize back to the demo restaurant name | Run Prompt 7.52c |
| 2026-03-30 | Phase 7.52c | Legacy naming cleanup and private root file relocation completed | `meridian_data.dart` renamed to `legacy_fixture_data.dart`, `demo_data.dart` renamed to `fixture_seed_data.dart`, private Barrio root files (`Barrio Legado Business Plan.pdf`, `jim_taylor_labor_model_deep_dive.html`, `Logo.png`) moved into `docs/internal/barrio/` and `assets/internal/barrio/branding/`; all imports and doc references updated | Run Prompt 7.52d |
| 2026-03-31 | Planning | Barrio shell vision reorganized for clean execution | The private Barrio app is now framed as a hospitality-driven operating shell with a living-system-map home hub; 7.52f-h were split into shell IA, handbook experience, manager-learning surfaces, and a Phase 9 handoff so execution stays narrow | Run Prompt 7.52f |
| 2026-03-31 | Phase 7.52d | Private Barrio boundary completed | `lib/internal/barrio/` now defines the internal Barrio code boundary with dormant destination/source-material scaffolding and no public runtime wiring | Run Prompt 7.52e |
| 2026-03-31 | Phase 7.52f | Barrio shell IA and home navigation completed | Barrio now has a real private shell root, living-system-map bubble hub, typed route map, and destination placeholder screens; focused shell tests passed and the public Forge & Flow runtime was not touched | Run Prompt 7.52g |
| 2026-03-31 | Phase 7.52g | Company Handbook experience completed | Barrio now has a real all-staff handbook screen with native structured chapter content, interactive lesson cards, chapter rail switching, and focused handbook widget coverage; the public Forge & Flow runtime remained untouched | Run Prompt 7.52h |
| 2026-03-31 | Phase 7.52h | Manager/admin learning surfaces completed | Barrio now has real Interview Playbook and Jim Taylor learning surfaces with typed native content, scenario/checkpoint interactions, and focused widget coverage; Preston Lee remains Coming Soon, supervisor content remains light, and the public Forge & Flow runtime remained untouched | Run Prompt 7.52i |
| 2026-03-31 | Phase 7.52i | Phase 9 handoff and role-preview polish completed | Barrio now has typed preview-role behavior, preview-aware shell emphasis, preview-role context flowing into destination screens, and a shared access-intent banner; focused preview-role and destination tests passed and the public Forge & Flow runtime remained untouched | Recontextualize next build step |
| 2026-03-31 | Planning | Inserted 7.53 native split before Phase 9 auth | The repo should complete separate Forge & Flow vs Barrio native app identities before restaurant auth work begins, so the next block shifted from `9.1` to `7.53` | Run Prompt 7.53 |
| 2026-03-31 | Phase 7.53a | Native config split completed | Android flavors plus iOS schemes/configurations, ids, and display-name wiring now exist for Forge & Flow and Barrio while preserving one shared Dart runtime; the remaining blocker is iOS per-flavor app icon and splash asset-catalog separation on macOS/Xcode | Run Prompt 7.53b |
| 2026-03-31 | Phase 7.53b | iOS per-flavor asset catalog split completed | ForgeFlow vs Barrio iOS app icon sets, launch storyboards, and launch asset references checked in; final Xcode verification still recommended | Run Prompt 7.53c |
| 2026-03-31 | Phase 7.53c | Premium teaching UI overhaul completed | PageView carousel replacing ListView, 3D perspective, card press/glass/expand polish, worm dots, enhanced sparkle, photo backgrounds, accent matching, ForgeFlow splash gradient | Run Prompt 7.53d |
| 2026-04-01 | Phase 7.53c | Performance polish | Removed film grain (4000-dot CustomPainter), removed carousel breathing glow, removed El Podio BackdropFilter, halved bubble hub blur radii, added colour-temperature scrim breathing (12s warm↔cool loop) | Continue 7.53d |
| 2026-04-01 | Phase 7.53d | Content fix + answer shuffle + icons completed | Shuffled all answers (A=10 B=9 C=8 across 27 units), filled all 4 scaffolded areas from source PDFs/HTML, fixed 2-option units, added grf_checkpoint, badgeHint on all 86 units, 13 rail icons verified from Flutter SDK | Run Prompt 7.53e |
| 2026-04-01 | Phase 7.53e | El Podio scoreboard completed | Premium glassmorphic podium with gold/silver/bronze top 3, demo users (Brian/Emily/Amy/Priya -42pts), Phase-9-ready PodioEntry model with userId, frosted glass home button | Run Prompt 7.53f |
| 2026-04-01 | Phase 7.53f | Preston Lee + Phase 9 prep completed | Removed audience tags and access intent banner (consistency), fixed icon mismatch, increased comingSoon dimming to 0.30, documented Phase 9 Barrio requirements | Phase 7.53 complete |
| 2026-04-01 | Housekeeping | Repo cleanup completed | Removed 5 dead placeholder files, 7 stray root files (~10 MB), cleaned redundant pubspec entry, fixed stale barrio_shell_widget_test.dart | 513/513 tests pass |
| 2026-04-01 | Phase 7.54a | Barrio thermal/render-cost pass completed | RepaintBoundary around static/animated islands, lifecycle animation gating, merged animation listeners, cache-sized image decode paths | Run Prompt 7.54b |
| 2026-04-01 | Phase 7.54b | Release-size and asset-compression pass completed | Dynamic IconData replaced with constant mappings for icon tree shaking; 4 heavy PNGs converted to JPEG; handbook_icon recompressed to 28KB; release split APK builds without --no-tree-shake-icons; 47 focused Barrio tests pass | Run Prompt 7.54c |
| 2026-04-01 | Phase 7.54c | Flavor asset-bundle containment completed | handbook_icon.png moved from shared assets/images/ to assets/internal/barrio/; branding/ and inspiration/ confirmed excluded from APK bundles; ForgeFlow still bundles ~2MB Barrio-private assets due to Flutter pubspec.yaml global asset declarations (documented limitation); README updated with size/cleanup/containment documentation; 47 focused Barrio tests pass | Phase 7.54 complete |

## Barrio Legado — UI Change Log (Phase 7.53c)

### Background & Atmosphere
- Full-bleed photo background (`home_bg.png`) as the base layer
- 5-stop editorial gradient scrim — dark at top (header legibility) → transparent in hub zone (photo breathes) → dark at bottom (cinematic depth)
- Teal bloom — radial glow anchored top-centre as a brand colour presence
- Gold warmth bloom — radial glow in bottom-right corner for hospitality warmth
- Edge vignette — radial darkness from all four corners for a cinematic feel
- Film grain — 4,000 static noise dots at 3.5% opacity, rendered once and cached via `RepaintBoundary` + `shouldRepaint: false` (zero runtime cost)

### Header Card
- Glassmorphism card — frosted `BackdropFilter` blur (sigmaX/Y 24) with white tint border
- Wordmark letterSpacing entrance — "Barrio" collapses from 6.0 → 2.0 and "Legado" from 6.0 → 1.0 over 700ms on screen entry (`Curves.easeOutQuart`) — a luxury "settle-in" motion pattern
- Gold double-rule divider — 88px primary rule + 44px secondary rule beneath the wordmark
- Role preview chips — animated `AnimatedContainer` with teal gradient on active chip, selectionClick haptic on tap

### Bubble Hub
- Staggered entrance bloom — center bubble pops first (elasticOut), each orbit bubble blooms 120ms after the previous
- Tap press feedback — `AnimatedScale` to 0.92 with spring-back (easeOutBack, 150ms), glow flares on press
- Idle breathing pulse — center bubble slowly scales ±2.5% after 4s of no interaction; resets on any tap
- Haptics — lightImpact on every tap-down, mediumImpact on primary Dashboard navigate, selectionClick on role chips
- Orbit ring track — faint `SweepGradient` ring in brand blue/orange (subtle, alpha 0.35) behind all bubbles
- Animated shimmer arc — independent 21s controller drives a traveling orange/blue arc along the ring (~0.3 rad/sec), simulating a physical light source
- Center Dashboard bubble — dual blue/orange glow (blue left, orange right), diagonal blue→orange gradient fill, orange border, rotating 120° arcs (one orange, one blue, 180° apart)
- 3-layer glassmorphism on all bubbles — dark base + accent radial from bottom + white specular from top
- Role-based access blocking — dimmed bubbles (staff/supervisor restricted) get no `GestureDetector` at all — truly non-interactive, not just visually disabled

### Ambient Leaves
- Parallax depth tiers — near tier (leaves 0–5): larger (12–22 px), faster (5–7s), 90% opacity hold; far tier (leaves 6–11): smaller (5–12 px), slower (9.1–12.75s), 45% opacity hold — genuine perceived depth
- Three-way colour cycle — warm gold, brand teal, deep navy
- Fade-in/hold/fade-out opacity envelope per leaf — seamless looping with no visible snap

### Colour Refresh
- `BarrioColors` palette — gold and teal variants boosted ~10% in saturation/brightness
- Destination accent colours — all five bubble accents made more vivid (handbook gold, playbook green, Taylor teal, Preston violet, Forge blue)
- Logo blue `#2864C8` → `#2E6EE0` — brighter royal blue throughout orbit ring and Dashboard glow
- Screen blooms — alpha bumped slightly (teal 20%→25%, gold 13%→17%)

### Destination Photo Backgrounds (7.53c)
All four destination screens now use premium 5-layer photo-backed composition matching the home screen pattern:

| Screen | Photo Asset | Accent Before | Accent After |
| --- | --- | --- | --- |
| Company Handbook | `handbook_bg.png` (red brick Barrio building) | Gold `#D4A04A` | Warm brick red `#D4584C` |
| Jim Taylor Model | `jim_taylor_bg.png` ("Bold by Design" book on dark wood desk) | Teal `#4FC3C3` | Royal blue `#3A6ED0` |
| Interview Playbook | `interview_bg.png` (jimador with agave pina) | Emerald `#2ECC71` | Unchanged |
| Preston Lee Model | `preston_lee_bg.png` ("Thirty Percent" book in restaurant) | Violet `#9B8FFF` | Warm amber `#CC8A3A` |

5-layer stack per screen: full-bleed photo → 6-stop dark gradient scrim → accent radial bloom → complementary navy bloom → edge vignette

### Learning Surface Premium Overhaul (7.53c)
- **Progress psychology:** mastery percentage + progress bar + "remaining distance" framing on all screens
- **Card expand/collapse:** interactive cards start collapsed (badge + title + 2-line preview), tap to expand — reduces cognitive load
- **Reading time estimates:** "~2 min" label on each interactive card
- **Staggered card entrance:** 80ms stagger, 350ms easeOutCubic slide-up + fade
- **Staggered option reveal:** options animate in 100ms apart with slide-up + fade
- **Hero entrance animation:** 700ms easeOutCubic fade-in
- **Correct answer sparkle:** 8-particle burst (600ms) + medium haptic
- **Module complete banner:** slide-up overlay with accent glow + heavy haptic
- **Premium badge redesign:** subtle gradient depth + soft shadow
- **Line-height:** body text increased from 1.7 to 1.8
- **Haptic rhythm:** light on section switch, medium on correct answer, heavy on module complete

### Chrome Cleanup (7.53c)
- Removed audience tags (All Staff / Manager / Admin) from all screen AppBars
- Removed streak flame chip from all screen AppBars
- Removed `BarrioAccessIntentBanner` from bottom of all screens
- Handbook bubble icon changed from Barrio logo to `handbook_icon.png` (glowing leaf, 2.4x scale, Stack layout)

### ForgeFlow Splash Screen (7.53c)
- Before: plain orange `#FF6B35` background, oversized rounded icon
- After: subtle warm peach-orange to ice blue gradient background + properly scaled 480px centered icon

### Files Created (7.53c)
- `lib/internal/barrio/widgets/barrio_celebration_overlay.dart` — celebration system (sparkle + module banner)
- `lib/internal/barrio/widgets/barrio_streak_tracker.dart` — streak service + widget (SharedPreferences)
- `assets/images/forge_flow_splash_bg.png` — ForgeFlow splash gradient
- `assets/images/forge_flow_splash_icon.png` — ForgeFlow splash icon (480px)
- `assets/internal/barrio/handbook_bg.png` — handbook screen background
- `assets/internal/barrio/jim_taylor_bg.png` — Jim Taylor screen background
- `assets/internal/barrio/interview_bg.png` — interview playbook screen background
- `assets/internal/barrio/preston_lee_bg.png` — Preston Lee screen background

### Dependencies Added (7.53c)
- `shared_preferences: ^2.3.0` — streak persistence

### Phase 7.55d Closeout

Phase 7.55d is closed through `7.55d.3c`.

Final outcomes:

- `7.55d.1` created the SchedulePlan/ScheduleDayPlan planning contract and moved Schedule planning math through the resolver path.
- `7.55d.1a` through `7.55d.1c` made unavailable demand honest, derived forecast sales from current target PPA, added immutable day rows, and reconciled day cover/FOH/BOH totals exactly to weekly totals.
- `7.55d.2` made Shift compare whole-business-day actuals against the matching SchedulePlan day row.
- `7.55d.2b` moved Shift LABOR % to the whole-day read model and removed the WTD dependency from that card.
- `7.55d.3` added Manager Override downstream plan impact and Data Alignment Audit proof.
- `7.55d.3a` corrected WTD, WeekRecord, and ShiftFact BOH model hours to use actual sales instead of target PPA.
- `7.55d.3b` corrected closed Variance detail to use locked actual-volume model-hour getters.
- `7.55d.3c` backfilled static/demo closed shifts with stable locked target defaults from `MeridianConfig`, preserving strict locked-target getters while preventing static/demo Variance expansion crashes.

Reported verification:

- `flutter analyze` clean.
- `flutter test test/wtd_variance_logic_test.dart` passed with 37 tests after `7.55d.3c`.
- Full `flutter test` passed with 622 tests after `7.55d.3c`.

Residual work intentionally moved out of 7.55d:

- 7.55e owns data-driven day/daypart distribution.
- 7.55f owns true `business_date` persistence and 60-day date-window querying.
- 7.55i owns canonical Demand Forecast Context, shared SchedulePlan read-service authority, WTD target semantics, and Learn migration off `BaselineData` benchmark context.

### Phase 7.55e Progress Note

Phase 7.55e is active, not closed.

Verified sub-prompts:

- `7.55e.1` added immutable `ScheduleDistributionWeights` and pure `DistributionWeightBuilder` from closed `ShiftRecord`s.
- `7.55e.2` made `SchedulePlanResolver` accept optional day distribution weights while preserving weekly-level planning math and fallback defaults.
- `7.55e.3` made Schedule daypart subrows consume day x daypart weights with largest-remainder reconciliation and fallback behavior.
- `7.55e.4` added `ScheduleDistributionWeightsNotifier`, wired it into `ForgeFlowScope`, and passed runtime closed-shift-derived weights into Schedule.

Reported verification:

- `flutter analyze` clean after `7.55e.4`.
- `flutter test test/schedule_distribution_weights_notifier_test.dart` passed with 8 tests after `7.55e.4`.
- `flutter test test/distribution_weight_builder_test.dart` passed with 16 tests after `7.55e.4`.
- `flutter test test/schedule_plan_resolver_test.dart` passed with 33 tests after `7.55e.4`.
- Full `flutter test` passed with 554 tests after `7.55e.4`.

Remaining before closeout:

- `7.55e.5` should replace hardcoded historical/current operational seed rows with deterministic mock POS/labor integration replay into SQLite.
- `7.55e.6` should make app runtime prove it reads mock-imported SQLite operational data instead of `DemoData` fixture lists, leaving fixtures only as tests, previews, or explicitly documented compatibility.

## Archived Decision Log

Record only decisions that affect future implementation.

| Date | Decision | Why it matters |
| --- | --- | --- |
| 2026-04-10 | Keep 7.55e open until mock integration replay replaces hardcoded operational seed truth | Distribution weights are wired, but the app should prove the Phase 8 shape by replaying mock POS/labor facts into SQLite instead of copying `DemoData` operational lists into runtime state |
| 2026-03-28 | Build canonical domain layer before more History/Learn work | Avoid rework when live POS/labor integrations arrive |
| 2026-03-28 | This Week stays decision-forward; History/Learn stay educator-forward | Keeps product roles clear |
| 2026-03-28 | For Prompts 5 to 7, let Claude lead visual direction while Codex focuses on logic, structure, and review | Keeps visual quality strong without loosening architectural discipline |
| 2026-03-29 | Treat data alignment and decoupling as a formal Phase 7.5 gate after feature completion and before live adapters | Keeps Phase 8 focused on connector transport instead of forcing a product-logic rewrite |
| 2026-03-29 | Execute Phase 7.5 and Phase 8 in narrower implementation blocks | Makes onboarding, backfill, and continuous sync trackable instead of leaving them implicit inside one large phase label |
| 2026-03-29 | Before Phase 7.5, use trusted-surface debugging instead of whole-UI debugging | Prevents mixed demo-backed screens from being mistaken for logic failures during Phase 5-6 work |
| 2026-03-29 | Keep Phase 8 focused on one restaurant/location and treat cross-device shared login and override sync as a later explicit phase | Prevents local SQLite assumptions from being mistaken for a full multi-device source of truth |
| 2026-03-29 | Keep Phase 9 auth fully app-managed, with onboarding-created credentials that mirror the restaurant's POS-style login setup | Keeps login simple for operators without depending on unsupported vendor credential flows |
| 2026-03-29 | Split future auth/login from future shared multi-device sync, and keep corporate structure as a later placeholder phase | Makes each future layer smaller, easier to reason about, and less likely to blur restaurant truth with cross-device or cross-store concerns |
| 2026-03-30 | Use 7.11 to 7.14 as a short stabilization sequence before Phase 7.5 | Keeps bug and polish work contained without diluting the larger alignment gate |
| 2026-03-30 | Keep Baseline naming frozen during stabilization | Avoids reopening a wide visible-label surface while focus stays on behavior and teaching accuracy |
| 2026-03-30 | Finish 7.5a fully before starting 7.5b | Avoid carrying persistence-contract debt into target-state alignment |
| 2026-03-30 | Finish 7.5b fully before starting 7.5c | Prevents mixed target-state fallback or weak migration coverage from leaking into live-state alignment |
| 2026-03-30 | Treat Phase 7.5 as the final internal state-boundary gate before connectors | Keeps Phase 8 focused on onboarding and adapter transport rather than another round of demo-truth unwinding |
| 2026-03-30 | Reopen the post-7.5 gate as `Phase 7.51` before starting live adapters | Keeps the tracker honest by closing the remaining historical-truth drift, `BaselineData` bridge authority, and vendor/gate artifact gaps before connector work begins |
| 2026-03-30 | Split the remaining post-7.51 work into `7.51d` and `7.51e` | Separates code-side bridge/pending-state cleanup from vendor-selection and final runnable gate proof so Phase 8 only starts once both are truly closed |
| 2026-03-30 | Track the live test corpus by the repo's actual *_test.dart file count and rerun it from checked-in tooling before marking the Phase 8 gate passed | Prevents stale test counts from making the gate docs say passed on an outdated corpus |
| 2026-03-30 | Keep Barrio as a private layer inside Forge & Flow rather than a forked repo | Lets future Forge & Flow updates and vendor integrations flow into the internal Barrio build without maintaining two divergent codebases |
| 2026-03-30 | Build the Barrio shell before Phase 9 auth, but keep real gating out of 7.52 | Lets the private internal app experience, information architecture, and visual system settle before login and permissions are added |
| 2026-03-30 | Treat handbook PDFs and source documents as source material rather than the final runtime UX | Keeps private content maintainable, interactive, searchable, and ready for later role-based access instead of locking the app into raw document viewers |
| 2026-03-30 | Prepare Forge & Flow and Barrio as separate build identities from one shared codebase | Supports different app names, icons, and private content without splitting the product into multiple repos |
| 2026-03-30 | Lock the Barrio shell and content contract in a dedicated 7.52 execution doc before renaming or build work begins | Keeps the cleanup/build sequence deterministic and prevents Phase 9 auth concerns from leaking into the shell/content phase |
| 2026-03-31 | Treat Barrio as a private in-restaurant operating system with Forge & Flow as one destination inside it | Keeps the internal app shell distinct from the shared commercial product and clarifies why shell IA must be designed before auth |
| 2026-03-31 | Split post-shell work into handbook first, then manager/admin learning surfaces | Keeps 7.52 execution small enough that the shell, handbook, and professional model surfaces can each be designed intentionally without one giant vague prompt |
| 2026-03-31 | Build the Company Handbook as native structured content instead of a document viewer | Keeps all-staff training approachable, interactive, and ready for later search or role gating without locking Barrio into raw PDF UX |
| 2026-03-31 | Build the manager/admin destinations as native teaching surfaces instead of placeholders or raw documents | Keeps playbook and model training interactive, professional, and ready for later Phase 9 gating without leaking document-viewer UX into the private build |
| 2026-03-31 | Finish 7.52 with preview-role context instead of real auth | Gives Phase 9 a clean handoff contract for role intent and destination visibility without leaking real permissions into the private shell phase |
| 2026-04-01 | Replace linear card scroll with PageView carousel for teaching screens | 3-5 cards per chapter is too few for a grid or journey map; full-width focus eliminates distraction; Masterclass/Headspace pattern |
| 2026-04-01 | Use badgeHint per unit instead of type-based labels | Prevents CONCEPT/CONCEPT/CONCEPT repetition; each card gets a contextually unique badge |
| 2026-04-01 | Defer mastery/completion persistence to Phase 9 | Requires user auth for user-scoped SharedPreferences keys; in-memory tracking is sufficient for the demo build |
| 2026-04-01 | Build El Podio as a standalone route, not a BarrioDestination | Scoreboard is a utility screen, not a learning destination; doesn't belong in the bubble hub |
| 2026-04-01 | Accept Flutter flavor-conditional asset limitation rather than extracting Barrio into a separate package | Full flavor-private asset exclusion requires a separate Flutter package with its own pubspec.yaml; the restructure cost is not justified while both flavors ship from the same repo and ForgeFlow's dead-payload cost is ~2 MB |
| 2026-04-01 | Remove audience tags and access intent banners from all screens | Inconsistent (only Preston Lee had them); Phase 9 will add real gating systematically |
| 2026-04-01 | Remove film grain and carousel breathing glow for performance | Film grain drew 4000 rects; carousel glow ran an infinite AnimationController; phone was heating up |
| 2026-04-02 | Standardize Phase 9 on one shared email/password Firebase Auth system with persistent login until logout | Keeps Forge & Flow and Barrio on one identity plane, avoids guest/PIN/biometric complexity, and fits the existing one-way product boundary |
| 2026-04-02 | Keep permission keys fixed and app-defined while allowing editable seeded roles and custom roles | Preserves flexibility for admins without turning runtime role data into an unbounded permission-schema system |
| 2026-04-02 | Treat Forge & Flow as the commercial baseline app and Barrio as the internal superset shell | Keeps permission design aligned with the current dependency boundary: Forge & Flow stays independent, Barrio adds on top |
| 2026-04-02 | Split Phase 9 into `9a` through `9e` plus `9.5` and require explicit Firebase setup checkpoints | Makes auth prompt-sized, forces honest Firebase/backend prerequisites, and separates learning El Podio identity from later operational ranking |
| 2026-04-09 | Keep Phase 7.56 as an app-owned reservation-book cache and Shift read-model surface | Lets demo/local reservation signals ship now while keeping official OpenTable/reservation transport, status mapping, and vendor capability work in Phase 8R |
| 2026-04-09 | Treat 7.55 stabilization and 7.56 reservation work as separate commit scopes even when they coexist in the working tree | Prevents future reviewers from mistaking dashboard/hours-lever stabilization, reservation signal plumbing, tracker docs, and test-contract cleanup as one undifferentiated phase |
| 2026-04-09 | Treat BOH Schedule demand as forecast-sales-first, with forecast sales derived from forecast covers * target PPA | Keeps the UI and code aligned with the labor model while preserving the current rule that POS history supplies covers and the app derives sales |
| 2026-04-09 | Treat forecast covers as POS-history-derived and forecast sales as app-derived | Aligns Schedule with the decision that Phase 8 supplies raw closed-shift history, not vendor-provided forecast values |

---

## 2026-05-07 closeout pass — phases retired from active board

The active `PROJECT_TRACKER.md` was trimmed to "open-only" on 2026-05-07.
The following accepted/closed rows were moved here from the active board:

- **Phase 9 framework + `9.0Σ.b-l` + `9.UX.*`** — ACCEPT.
- **Phase 9.5.0** — ACCEPT (`9.5.UX.*` paused under Barrio freeze).
- **Phase 11A foundation `0`–`7` / `UX.health`** — ACCEPT.
- **Phase 11A cross-operator parity `.12` / `.13` / `.14`** — ACCEPT 2026-05-06.
- **Phase 11W.0–.8** — ACCEPT 2026-05-06 (web shell A1, Account/Business
  Timing A2, Vendor Connections A3, parity `.1`–`.6`, live-wiring fix
  `11W.7.live-wire`).
- **Phase 8 / 8R / 8.S** — engineering-complete (PASS 2026-05-05 via
  `8.integration-mobile-proof.v2`). Wave B `documented` for all 17
  adapters; lifecycle promotion via `phase_8_live_rollout`.
- **`8.spine-bridge-sink-fanout`** — 14 of 14 sink lanes (AL, TC, HM,
  SQ, TS, PU, AG, CL, ADP, RV, SR, LSK, OT, SP) ACCEPT 2026-05-06/-07
  plus `.7S.upgrade` adapter capability extension.
- **`8.business_date_denorm`** — ACCEPT 2026-05-06 (`c61c2ea7`).
- **`8.first-connect-backfill-wire-in`** — ACCEPT 2026-05-06 (PR #195,
  `aa7a58d2`). Six lanes closed.
- **`business-timing-live` foundation + UI shell + closed timing label
  stability proof** — merged 2026-05-06.
- **`8.star-target-server-truth`** — ACCEPT 2026-05-06.
- **`8.weekly-plan-server-truth`** — MERGED 2026-05-07 (PR #226).
- **`8.business-scope-selector`** — mobile foundation MERGED 2026-05-07
  (PR #236).
- **Claude V1 closure dispatch — 7 of 7 lanes** — V1.A (PR #200), V1.B
  (PR #198), V1.C (folded into PR #226), V1.D (PR #236), V1.E (PR #202),
  V1.F (PR #201), V1.G (PR #199). Detail in
  `docs/archive/_execution/2026-05-06_v1_closure_dispatch_plan_CLOSED_2026-05-07.md`.
- **Phase 10a `.0`–`.5` + `UX.0`/`UX.1`** — ACCEPT 2026-05-06 (real-time
  webhook → NOTIFY → Pub/Sub bridge complete; `last_event_id` replay;
  Q22 tripwires + retention sweep). Phase 10b deferred post-launch.
- **Phase 7.58 depth wave** — closed 2026-05-05 on master `699a45f`. All
  five slices ACCEPT (`7.58.UX.6`, `.UX.8`, `.cross-axis.0`, `10.5.6`,
  `.UX.7+9`).
- **`9.8.email`** — ACCEPT (PR #88). Inbound-vendor T&Cs remain in
  scope; advisor + outbound paused.
- **CODE_HEALTH remediation** — closed 2026-05-07. 16 PRs across 5
  critical + ~22 high findings. Resolution log + addendum in
  `CODE_HEALTH.md`.
- **Production1 runtime** — live 2026-05-06. Cloud Run + Firebase +
  Postgres-CMK + production DNS for `app.forgeflow.app` and
  `mail.forgeflow.app` provisioned.
- **Phase 8 timing-provenance carry-forward closures (P1)** —
  closed-row proxy gap (V1.A), FK posture flip (V1.B), same-second
  prefix collision resolved.
- **Phase 7.61.2 / 7.61.3** — closed (`cd0b32d`, `f21baf4`).
