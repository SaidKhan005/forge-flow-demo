# Post-1022 Deeper Gap Fix Execution Plan

Status: implemented locally, PR/merge pending
Created: 2026-05-19
Branch: codex/post-1022-deeper-gap-fix
Base: origin/master at 96b9d2b3

## Plain-English Goal

- Finish the remaining gaps found after PR #1022 landed.
- Keep the shared checkout clean on master.
- Use this worktree for every code/doc edit.
- Fix only the lanes that are clear enough to land safely.
- Document any new gaps found while working so they do not disappear.

## Authority Read

- `CLAUDE.md`
- `PROJECT_TRACKER.md`
- `docs/contracts/core_app_architecture.md`
- `docs/contracts/data_accuracy_settings_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
- Updated `graphify-out/graph.json` used read-only only. No graph refresh.

## Fix Lane 1: Data Accuracy Covers Precedence and Admin Edit Parity

- Restore the effective Data Accuracy view to the R7a hierarchy rule:
  keyed service-period rows are the base per-period shape, then business,
  org, and location scoped overrides win when they set the same key.
- Make `covers_source_per_service_period_source` follow the same winner
  order so the UI label names the real winning source.
- Add or update focused tests proving both value and source metadata choose
  the same winning layer.
- Close the admin per-location edit gap where row edit still falls back to
  the old Lunch / Dinner / Late Night payload shape.

## Fix Lane 2: Closed-Truth Completion

- Use `ClosedTruthEligibility` anywhere closed rows feed operator-facing
  week records, Full Week rows, demand anchors, dollar-impact rollups, or
  baseline candidates.
- Keep legacy fallback behavior only where no operational business date is
  available, and document that as compatibility instead of pretending it is
  final closed truth.
- Update tests that currently expect same-business-date app-local closes to
  count immediately, but only where the product rule says they should wait
  until the business-day boundary.

## Fix Lane 3: Star Profile Version Identity

- Preserve `targetProfileVersionId` through local/offline TargetCycle to
  ActiveTargetProfile projection.
- Stop mobile direct close from minting a fake target profile version when an
  active server version exists.
- Store synced `target_cycle_id` on target profile version rows so mobile can
  keep cycle provenance.
- Add `targetProfileVersionId` to open/projected current-week records where
  the active profile is already known.

## Fix Lane 4: Learn and Service-Period Labels

- Route Learn recurring-leak and Repeatable Wins summaries through the
  timing resolver when available.
- Keep saved timing identity stable, but display configured service-period
  labels and ordering instead of raw keys when definitions are present.
- Mark remaining hardcoded label fallbacks as legacy fallback paths if they
  cannot be safely removed in this wave.

## Fix Lane 5: Mobile Timing Source Provenance

- Add inherited-source metadata for mobile Timing setup if the existing sync
  payload already has a safe server source.
- If the server payload does not expose enough metadata yet, document the
  exact server contract gap instead of inventing local guesses.
- 2026-05-19 finding: the current mobile sync contract does not expose enough
  source truth to add inherited-source metadata safely.
  `SyncProxyClient.fetchResolvedTimingConfig` explicitly describes the payload
  as the resolved shape, not the inheritance graph. The HTTP parser accepts
  only effective timing values: `restaurant_id`, `business_timezone` or
  `location_timezone`, `business_day_start_local_time`, `week_start_day`,
  `service_period_definitions` / `service_periods`, and timestamps. It does not
  carry selected scope, winning source scope type/id/label, inherited-from
  status, profile version/source row identity, or field-level provenance for
  timezone, day start, week start, or service-period definitions.
- Server contract needed before mobile can render Timing source provenance:
  `/v1/operators/{operatorId}/locations/{locationId}/timing/resolved` must
  return authoritative provenance with the effective config, at minimum
  `selected_scope_type`, `selected_scope_id`, `source_scope_type`,
  `source_scope_id`, `source_scope_label`, `inherited_from_ancestor`, and either
  a single winning timing profile/version identifier or field-level source maps
  for timezone, business-day start, week start, and service-period definitions.
  Mobile should then persist/display that server-provided metadata instead of
  deriving it from the effective values.

## Document-Later Lane

- Update stale active walkthrough references if touched by this wave.
- Record remaining hardcoded service-period fallbacks that are default data,
  template data, or legacy compatibility.
- Record any new gaps found while implementing.

## Worker Roles

- Orchestrator: owns the plan, worktree, conflict map, integration, tests,
  commit, push, PR, pre-merge gate, merge, and landed verification.
- Worker A: Data Accuracy SQL/source metadata/admin keyed edit lane.
- Worker B: Closed-truth completion lane.
- Worker C: Star profile version identity lane.
- Worker D: Learn/timing labels and mobile timing provenance lane.
- Workers must edit only their assigned files, respect other edits, commit no
  work themselves, and report changed paths and test suggestions back.

## Safety Checks

- `dart analyze --fatal-infos` on changed Dart files.
- Focused Flutter tests for touched services/screens.
- `dart run tool/ux_em_dash_lint.dart`
- If migrations change:
  - `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
  - `dart run tool/migration_cutoff_lint.dart`
- `git diff --check`
- High-risk PR gate from the shared checkout before merge:
  `tool/pre_merge_gate.sh <PR>`
- Post-merge landed proof:
  `tool/verify_pr_landed.sh <PR> <symbols>`

## Local Verification Completed

- Changed Dart files analyze cleanly with fatal infos enabled.
- Data Accuracy focused tests passed.
- Closed-truth focused tests passed.
- Star/profile identity focused tests passed.
- Learn/service-period label focused tests passed.
- Migration drift scanner and cutoff lint passed after updating watched
  migration authority docs to include R7f.
- UX em-dash lint passed.
- `git diff --check` passed.

## Known Risk

- Closed-truth tests previously expected app-local same-day closes to count
  immediately in legacy helper paths. This wave must align those expectations
  with the product rule instead of weakening the rule.
