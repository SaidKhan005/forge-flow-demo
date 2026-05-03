# Docs Archive

This folder holds historical or background material that should stay discoverable without crowding the active working docs.

## Structure

- `trackers/` - archived tracker snapshots, prompt history, and older progress logs
- `phases/` - completed phase planning docs that are no longer active authority
- `reference/` - background/reference material that still matters, but is not part of the active working loop
- `internal/` - completed execution closeouts and audit notes kept for traceability

Recent archive landmarks:

- `phases/phase_9/phase_9_execution_backlog_2026-04-29_PRE_CLOSEOUT_LEAN.md`
  preserves the full pre-lean Phase 9 backlog.
- `trackers/PROJECT_TRACKER_2026-04-29_PRE_PHASE9_CLOSEOUT_LEAN.md`
  preserves the tracker before the Phase 9 closeout lean pass.
- `phases/phase_9/phase_9_b17_staging_cloud_armor_tuning_result.md`
  records the B17 staging smoke and Cloud Armor preview tuning result.
- `phases/phase_7_61/7.61.1_acceptance_closeout.md` records the accepted
  F-1 driver-key analyzer cleanup while the wider Phase 7.61 family stays
  live.
- `phases/phase_10_5/10_5_2_per_period_read_service_closeout.md`
  records the accepted 10.5.2 per-period read service + Shift cards +
  Variance lens closeout while the Phase 10.5 planning doc stays active.
- `internal/2026-05-03_docs_code_audit_closeout.md`
  preserves the pre-`11A.6` docs/code audit closeout after active trackers were updated.

## Working Rule

Use top-level docs for active authority first:

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md`
- explicitly referenced active phase docs

Treat `docs/archive/**` as historical/reference material unless a prompt explicitly points there.
