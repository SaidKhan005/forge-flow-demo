# Docs Layout

Updated: 2026-05-08

This repo keeps docs in five main buckets:

## 1. Root authority docs

These stay at the top level because they are the fastest-entry authority docs:

- `PROJECT_TRACKER.md` (repo root)
- `docs/contracts/core_app_architecture.md` (canonical Phase 7.55 architecture authority)
- `docs/DATA_ALIGNMENT_TRACKER.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`

## 2. Frameworks

`docs/frameworks/`

Repeatable execution frameworks for cross-cutting work that applies across
phases and surfaces.

Current active frameworks:

- `docs/frameworks/PERFORMANCE_FRAMEWORK.md`
- `docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md`
- `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`

The deploy procedure is operational and lives under
`runbooks/deploy_runbook.md`.

## 3. Contracts

`docs/contracts/`

Active architecture and timing rules. Other live docs should point here instead
of restating them.

Current examples:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/contracts/proxy_health_contract.md`

## 4. Live phase docs

`docs/phases/`

Still-live lane docs grouped by phase family.

Current live groups:

- `docs/phases/phase_8/`
- `docs/phases/phase_8R/`
- `docs/phases/phase_7_58/`
- `docs/phases/phase_7_61/`
- `docs/phases/phase_9/`
- `docs/phases/phase_9_5/`
- `docs/phases/phase_9_75/`
- `docs/phases/phase_9_8/`
- `docs/phases/phase_10a/`
- `docs/phases/phase_10_5/`
- `docs/archive/phases/phase_10b/`
- `docs/phases/phase_11a/`
- `docs/archive/phases/phase_11b/`

## 5. Archive

`docs/archive/`

Completed phase slices, retired reference docs, internal notes, and tracker
history live here.

Common archive areas:

- `docs/archive/phases/`
- `docs/archive/internal/`
- `docs/archive/reference/`
- `docs/archive/trackers/`

## Other folders

- `docs/app_store_release/` - release collateral

## Working rule

If a doc is:

- an active architecture rule -> put it in `docs/contracts/`
- a repeatable cross-surface execution framework -> put it in
  `docs/frameworks/`
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

2026-04-29 Phase 9 cleanup: completed closeout result reports now live under
`docs/archive/phases/phase_9/`; active Phase 9 docs keep only plans, decision
locks, backlog, QA matrix, and operational runbooks.

2026-04-29 Phase 9 live update: B17 staging smoke and Cloud Armor preview
tuning evidence is archived with the other Phase 9 result reports.

2026-05-03 Phase 10.5 update: accepted 10.5.2 closeout/result material lives
under `docs/archive/phases/phase_10_5/`. The active Phase 10.5 plan remains
under `docs/phases/phase_10_5/` because daypart-live primary-driver teaching
is still queued.
