# Forge & Flow

Flutter prototype for labor coaching and shift decision support.

The current product flow is:

`POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn`

## Main Surfaces

- `This Week`: diagnose what matters first right now
- `History`: show what has repeated across tracked weeks
- `Learn`: teach recurring leaks, benchmark patterns, and coaching focus
- `Baseline`: manage benchmark/star-shift selection and target context
- `Schedule` and `Shift`: operational planning and in-shift teaching surfaces

## Repo Guide

- [PROJECT_TRACKER.md](PROJECT_TRACKER.md): active roadmap, current prompt, and next execution block
- [docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md](docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md): archived tracker history
- [docs/DATA_ALIGNMENT_TRACKER.md](docs/DATA_ALIGNMENT_TRACKER.md): active alignment notes and current source-of-truth watchpoints
- [docs/archive/README.md](docs/archive/README.md): archived trackers, completed phase docs, and background reference material
- [docs/archive/reference/REFACTOR_AND_DECOUPLING.MD](docs/archive/reference/REFACTOR_AND_DECOUPLING.MD): archived Phase 7.5 alignment contract
- [docs/CODEX_PROMPT_GENERATION_STANDARD.md](docs/CODEX_PROMPT_GENERATION_STANDARD.md): operating standard for Codex planning, Claude prompt generation, verification, and tracker ownership
- [docs/archive/phases/phase_7_52_execution_plan.md](docs/archive/phases/phase_7_52_execution_plan.md): archived Phase 7.52 cleanup, private-build, and Barrio shell contract
- [docs/archive/phases/phase_8_gate/](docs/archive/phases/phase_8_gate/README.md): archived Phase 8 readiness gate artifacts (vendor profiles, source ownership, replay evidence, signoff)
- [jim_taylor_labor_model_deep_dive.md](docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md): local teaching/model reference used throughout the app

## Current Status

Active work routes through [PROJECT_TRACKER.md](PROJECT_TRACKER.md). Snapshot as of 2026-05-08:

- V1 launch prep: production cutover gates `cutover.0`–`cutover.5` and the operator punchlist. See `docs/_execution/2026-05-06_v1_operator_punchlist_execution.md`.
- Phase 8 spine-bridge fanout is well underway: 17 INTEGRATE adapters at lifecycle `documented`; per-vendor Postgres sinks landed; `*.live.sandbox` lanes fire as vendor credentials arrive (rolling, parallel, doesn't block V1).
- Phase 11a advisor infrastructure: live cloud Postgres host is Azure Database for PostgreSQL Flexible Server (`Canada Central`, PG 16) with Apache AGE, pgvector, and `pg_diskann` (locked 2026-04-26).
- Phase 7.55 architecture (Layers 1–12) is canonical; see [docs/contracts/core_app_architecture.md](docs/contracts/core_app_architecture.md).
- Demo mode is a writer-side switch (HP #2): same SQLite tables, same reads, same UI under `kDemoMode=true` or vendor-live. See [docs/contracts/demo_mode_contract.md](docs/contracts/demo_mode_contract.md).

Earlier phases (7.5 alignment, 7.52/7.53/7.54, 7.55o extraction, 7.61 driver-key gate, Phase 8 gate) are complete; their artifacts live under `docs/archive/`.

## Local Development

```bash
flutter pub get
flutter run
flutter test
```

## Android Flavor Commands

Current Android flavors:

- `forgeflow`
- `barrio`

Basic cleanup and dependency refresh:

```bash
flutter clean
flutter pub get
```

Run either flavor on a connected device or emulator:

```bash
flutter run --flavor forgeflow -t lib/main_forgeflow.dart
flutter run --flavor barrio -t lib/main_barrio.dart
```

Local dev with the Anthropic Settings check enabled:

```powershell
scripts/run_flutter_dev.ps1 -App forgeflow
scripts/run_flutter_dev.ps1 -App barrio
```

That launcher reads `$HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1` and passes the
local dev-only `ANTHROPIC_API_KEY` as a Flutter `--dart-define`. Production
provider keys remain server-side only.

If multiple devices are connected, specify one explicitly:

```bash
flutter run --flavor forgeflow -t lib/main_forgeflow.dart -d <deviceId>
flutter run --flavor barrio -t lib/main_barrio.dart -d <deviceId>
```

Build APKs:

```bash
flutter build apk --flavor forgeflow -t lib/main_forgeflow.dart --debug
flutter build apk --flavor forgeflow -t lib/main_forgeflow.dart --release

flutter build apk --flavor barrio -t lib/main_barrio.dart --debug
flutter build apk --flavor barrio -t lib/main_barrio.dart --release
```

Build Android App Bundles:

```bash
flutter build appbundle --flavor forgeflow -t lib/main_forgeflow.dart --release
flutter build appbundle --flavor barrio -t lib/main_barrio.dart --release
```

Clean the Android Gradle build directly if needed:

```bash
cd android
./gradlew clean
cd ..
```

Typical APK output path:

- `build/app/outputs/flutter-apk/`

Important note:

- the repo currently has Android flavor names and source folders in place, but `pubspec.yaml` still contains one shared `flutter_launcher_icons` block and one shared `flutter_native_splash` block
- until flavor-specific generator config files are added, icon and splash generation still behaves like a single-brand setup
- the two flavors now use separate Dart entrypoints:
  - `lib/main_forgeflow.dart`
  - `lib/main_barrio.dart`

## Build Size and Local Disk Usage

Local workspace size, debug build size, and release package size are three different things:

| Metric | What it measures | Typical size |
|---|---|---|
| Local workspace (`build/` + `.dart_tool/`) | Cached build artifacts, intermediate outputs, debug symbols | ~4–5 GB |
| Debug APK | Unstripped, unoptimized, includes debug overhead | ~150–160 MB |
| Release split APK (per ABI) | Shipped payload, stripped, tree-shaken, compressed | ~20–25 MB |

`flutter clean` removes cached build artifacts and reclaims local disk space. It does not change the shipped release size — that is controlled by asset declarations, code tree-shaking, and release build flags.

Cleanup commands:

```bash
flutter clean          # removes build/ and .dart_tool/
flutter pub get        # re-fetches dependencies after clean
cd android && ./gradlew clean && cd ..   # cleans Android Gradle cache directly
```

## Flavor Asset Containment

The repo has two asset directories:

- `assets/images/` — shared assets used by ForgeFlow and/or both flavors (launcher icons, splash images, logo)
- `assets/internal/barrio/` — Barrio-private runtime assets (background photos, handbook icon)

Barrio-private **non-runtime** reference material (`branding/`, `inspiration/` subdirectories) is stored under `assets/internal/barrio/` on disk but is **not** declared in `pubspec.yaml` subdirectory listings and is therefore **not bundled** into any APK.

### Known limitation: Flutter does not support flavor-conditional asset bundling

Flutter's `pubspec.yaml` asset declarations apply globally to all build flavors. There is no built-in mechanism to conditionally include or exclude asset directories per flavor. This means:

- **ForgeFlow APKs currently include Barrio-private runtime assets** (~1.1 MB of background images + handbook icon)
- This is a Flutter toolchain limitation, not a configuration oversight
- The ForgeFlow Dart entrypoint never references or loads these assets — they are dead payload in ForgeFlow builds
- Eliminating this would require extracting Barrio into a separate Flutter package with its own asset declarations, which is a larger restructure outside the scope of the current optimization block

### What is contained

- Barrio non-runtime reference assets (`branding/`, `inspiration/`) are **not bundled** in either flavor
- All Barrio-private runtime assets are consolidated under `assets/internal/barrio/`, clearly separated from shared assets
- `handbook_icon.png` was moved out of `assets/images/` into `assets/internal/barrio/` since it is only used by Barrio screens

## Notes

- Vendor selection for Phase 8 connectors is locked: 17 INTEGRATE adapters across POS / Labor / Reservation. Folder catalog: [docs/integrations/](docs/integrations/README.md).
- Demo mode (`--dart-define=kDemoMode=true`) writes to the same SQLite tables as production via `MockReplayDataSourceProvider`; reader paths do not branch.
- `BaselineData` remains as a temporary compatibility bridge for Baseline, Schedule, and Learn; persisted `ActiveTargetProfile` is the canonical authority.
