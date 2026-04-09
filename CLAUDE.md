# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
flutter clean && flutter pub get          # Clean rebuild dependencies

# Run flavors
flutter run --flavor forgeflow -t lib/main_forgeflow.dart
flutter run --flavor barrio -t lib/main_barrio.dart

# Build release APKs
flutter build apk --flavor forgeflow -t lib/main_forgeflow.dart --release
flutter build apk --flavor barrio -t lib/main_barrio.dart --release

# Build app bundles
flutter build appbundle --flavor forgeflow -t lib/main_forgeflow.dart --release
flutter build appbundle --flavor barrio -t lib/main_barrio.dart --release

# Tests
flutter test                                          # Full suite
flutter test test/<file>.dart                          # Single test file

# Phase 8 gate corpus rerun (PowerShell)
scripts/run_phase8_gate_tests.ps1              # Full suite
scripts/run_phase8_gate_tests.ps1 -GateOnly    # Gate tests only
```

## Two-Flavor Architecture

The repo produces two apps from the same codebase. The visible product name is **Forge & Flow**; `forgeflow` is used only as the flavor/scheme key and package ID.

- **Forge & Flow** (`com.forgeflow.app`) — standalone labor coaching app. Entry: `lib/main_forgeflow.dart`.
- **Barrio** (`com.forgeflow.barrio`) — private internal shell that wraps Forge & Flow and adds extra screens (handbook, leaderboard, interview playbook, Jim Taylor model). Entry: `lib/main_barrio.dart`, app shell: `lib/barrio_app.dart`. Barrio-specific Dart lives primarily under `lib/internal/barrio/`, with `main_barrio.dart` and `barrio_app.dart` at the lib root. Barrio-specific assets and docs live under `assets/internal/barrio/` and `docs/internal/barrio/`.

Barrio reuses all shared domain, services, and persistence. It embeds Forge & Flow via `forge_and_flow_destination_screen.dart` using `ForgeFlowScope(child: AppShell(embeddedInBarrio: true))`.

Flutter does not support flavor-conditional asset bundling, so Barrio-private runtime assets (~2 MB in `assets/internal/barrio/`) are included in both builds.

## Architecture

**Clean Architecture layers:**
- `lib/domain/models/` — immutable domain entities (ClosedShiftInput, TargetSnapshot, ShiftFact, ActiveTargetProfile)
- `lib/domain/repositories/` — abstract repository interfaces
- `lib/domain/services/` — domain services (ShiftFactBuilder, TargetSnapshotBuilder)
- `lib/models/` — persisted records and read models (ShiftRecord, WeekRecord, WeekData, CurrentWeekState, ShiftDashboardReadModel)
- `lib/infrastructure/persistence/sqlite/` — SQLite DAOs and repository implementations
- `lib/data/` — ChangeNotifier state holders, application services, compatibility/demo/fixture sources (legacy_fixture_data.dart, fixture_seed_data.dart, shift_data_source.dart, app_data_status_service.dart)
- `lib/screens/`, `lib/widgets/` — presentation layer

**State management:** Provider with ChangeNotifier. Key notifiers:
- `ActiveTargetProfileNotifier` — canonical authority for app-wide target profile
- `ShiftDashboardNotifier` — live shift state
- `WeekDataNotifier` — weekly aggregates
- `RestaurantScopeNotifier` — current restaurant context

**Data flow:**
```
POS/Labor adapters → ClosedShiftInput + TargetSnapshot (locked at close)
  → ShiftFact (all derived metrics are getters, never stored)
  → ShiftRecord (SQLite) → WeekData / HistoryPatternBuilder → UI
```

## Key Design Rules

- **`LaborModel` (`lib/services/labor_model.dart`) is the single formula source.** Pure static methods. Never duplicate formulas elsewhere.
- **Target authority**: `ActiveTargetProfileNotifier` (`lib/data/active_target_profile_notifier.dart`) is the runtime authority for the current active target profile. Historical targets are locked at shift close via `TargetSnapshot` (`lib/domain/models/target_snapshot.dart`) — never re-derive from current state.
- **`MeridianConfig` (`lib/data/legacy_fixture_data.dart`) is a legacy compatibility/default bridge**, not the runtime authority. It provides fallback wage and config defaults for demo/fixture paths.
- **Do not mix source facts with derived metrics.** Raw inputs (covers, hours, sales) are source facts. PPA, CPLH, SPLH, labor %, dollar gap are always derived.
- **Daypart is the atomic truth unit.** Analysis should trace to individual daypart shifts, not just weekly rollups.

## Domain Vocabulary

| Term | Meaning |
|------|---------|
| CPLH | Covers Per Labor Hour (FOH productivity) |
| SPLH | Sales Per Labor Hour (BOH productivity) |
| PPA | Per Person Average (check average) |
| OPZ | Optimization zone — CPLH floor/ceiling bounds |
| Lever | Primary driver of variance (covers_up, cplh_down, foh_wage_up, etc.) |
| Dollar Gap | Actual labor cost minus theoretical (positive = over model) |
| Theoretical Labor % | Expected labor cost as percentage of sales |
| ShiftFact | Pure computed view over ClosedShiftInput + TargetSnapshot |
| TargetSnapshot | Targets frozen at shift close (immutable historical record) |

Jim Taylor labor model chapters: Ch.5 (CPLH/SPLH, schedule), Ch.9 (theoretical labor %), Ch.10 (variance, dollar gap), Ch.11 (OPZ bounds).

## Naming Conventions

- Notifiers: `*Notifier` (ChangeNotifier subclasses)
- Services: `*Service` with `ShiftService.instance` static singleton accessor
- Repositories: `*Repository` (abstract), `Sqlite*Repository` (implementation)
- DAOs: `*Dao`
- Read models: `*ReadModel` (view-optimized data)
- Screens: `*Screen`
- Singletons: `SqliteDatabase.instance`, `SqliteRestaurantScopeRepository.instance`, etc.

## Codex/Claude Workflow

This repo follows a **Codex-plans, Claude-executes** model (see `docs/CODEX_PROMPT_GENERATION_STANDARD.md`):

- **Always read `PROJECT_TRACKER.md` first** — it defines the current phase, current prompt, and roadmap. Currently: Phase 7.55 (release stabilization) with Phase 9a.1 (auth) paused.
- **Auth planning authority**: `docs/phase_9_auth_plan.md` (Firebase Auth + Firestore).
- **Claude owns**: code implementation, localized refactors, tests, and docs when requested by the prompt.
- **Claude does NOT own**: roadmap changes, marking phases complete, redefining scope, tracker updates (unless explicitly delegated).
- **Do not broaden scope** beyond what the current prompt requests.

## Design Tokens

- `AppColors` — 15 semantic colors (deep/mid/surface backgrounds; primary/secondary/muted text; positive/negative/warning/neutral directional)
- `AppTextStyles` — three font families: Playfair Display (headings), IBM Plex Mono (technical), IBM Plex Sans (body)
- Material 3 dark theme throughout
