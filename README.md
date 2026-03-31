# Forge & Flow

Flutter prototype for labor coaching and shift decision support.

The current product flow is:

`POS + Labor Systems -> Canonical Shift Facts -> Baseline -> Targets -> Schedule -> Shift -> Variance -> Learn`

## Main Surfaces

- `This Week`: diagnose what matters first right now
- `History`: show what has repeated across tracked weeks
- `Learn`: teach recurring leaks, benchmark patterns, and coaching focus
- `Baseline`: manage benchmark/star-shift selection and target context
- `Schedule` and `Shift`: operational planning and in-shift teaching surfaces

## Repo Guide

- [PROJECT_TRACKER.md](PROJECT_TRACKER.md): active roadmap, current prompt, and next execution block
- [PROJECT_TRACKER_ARCHIVE.md](PROJECT_TRACKER_ARCHIVE.md): completed prompt history and archived progress notes
- [DATA_ALIGNMENT_TRACKER.md](DATA_ALIGNMENT_TRACKER.md): trusted vs mixed-surface notes and data-alignment watchpoints
- [REFACTOR_AND_DECOUPLING.MD](REFACTOR_AND_DECOUPLING.MD): Phase 7.5 alignment contract
- [docs/CODEX_PROMPT_GENERATION_STANDARD.md](docs/CODEX_PROMPT_GENERATION_STANDARD.md): operating standard for Codex planning, Claude prompt generation, verification, and tracker ownership
- [docs/phase_7_52_execution_plan.md](docs/phase_7_52_execution_plan.md): Phase 7.52 cleanup, private-build, and Barrio shell contract
- [docs/phase_8_gate/](docs/phase_8_gate/README.md): Phase 8 readiness gate artifacts (vendor profiles, source ownership, replay evidence, signoff)
- [jim_taylor_labor_model_deep_dive.html](docs/internal/barrio/jim_taylor_labor_model_deep_dive.html): local teaching/model reference used throughout the app

## Current Status

- Phase 7.5 structural alignment is complete (restaurant scope, locked target truth, fixture replay)
- Phase 7.52 cleanup and private-build prep is in progress
- Phase 8 gate artifacts are checked in at `docs/phase_8_gate/`
- Phase 8 (live POS + labor adapters) is blocked only on vendor selection

## Local Development

```bash
flutter pub get
flutter run
flutter test
```

## Notes

- The app is in the pre-adapter alignment gate phase
- Current displayed data is still fixture/replay-backed at the transport layer, but it already flows through the intended internal app path
- `BaselineData` remains as a temporary compatibility bridge for Baseline, Schedule, and Learn; persisted `ActiveTargetProfile` is the canonical authority
- Vendor selection for Phase 8 connectors is TBD
