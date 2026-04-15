# Docs Layout

Updated: 2026-04-14

This repo now keeps docs in four main buckets:

## 1. Root authority docs

These stay at the top level because they are the fastest-entry authority docs:

- `PROJECT_TRACKER.md` (repo root)
- `docs/DATA_ALIGNMENT_TRACKER.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`

## 2. Contracts

`docs/contracts/`

These are the active architecture and timing rules that other live docs should
point to instead of restating from scratch.

Current examples:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`

## 3. Live phase docs

`docs/phases/`

These are still-live lane docs grouped by phase family instead of sitting loose
in the docs root.

Current live groups:

- `docs/phases/phase_8/`
- `docs/phases/phase_8_gate/`
- `docs/phases/phase_8R/`
- `docs/phases/7_55j/`
- `docs/phases/7_55o/`
- `docs/phases/7_55q/`
- `docs/phases/7_56/`
- `docs/phases/phase_9/`
- `docs/phases/phase_10/`
- `docs/phases/phase_10_5/`

## 4. Archive

`docs/archive/`

This is where completed phase slices, retired reference docs, and tracker
history live.

Useful archive areas:

- `docs/archive/phases/7_55i/`
- `docs/archive/phases/7_55j/`
- `docs/archive/phases/7_55k/`
- `docs/archive/phases/7_55n/`
- `docs/archive/phases/7_55p/`
- `docs/archive/phases/7_55l/`
- `docs/archive/phases/7_55m/`
- `docs/archive/internal/`
- `docs/archive/trackers/`
- `docs/archive/reference/`

## Other folders

- `docs/internal/` - internal company / product reference material
- `docs/app_store_release/` - release collateral

## Working rule

If a doc is:

- an active architecture rule -> put it in `docs/contracts/`
- an active planning lane doc -> put it in `docs/phases/<lane>/`
- completed and no longer part of the live working spine -> move it to
  `docs/archive/`

If a phase family is still live but an individual slice inside it is already
complete, archive that slice under `docs/archive/phases/<lane>/` and keep only
the still-live planning docs in `docs/phases/<lane>/`.

The goal is simple: the docs root should stay quiet, and the live authority
path should be easy to scan.

Temporary synthesis or reconciliation notes should be archived once their
decisions are absorbed into the active trackers and phase docs.
When that happens, prefer `docs/archive/internal/` for internal temp notes
that are no longer part of the live working spine.
