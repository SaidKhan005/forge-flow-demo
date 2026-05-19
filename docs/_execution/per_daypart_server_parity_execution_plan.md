# Per-Daypart Server Parity Execution Plan

Status: active execution plan
Created: 2026-05-18
Owner: Codex orchestrator
Authority:
- `PROJECT_TRACKER.md`
- `docs/contracts/core_app_architecture.md`
- `docs/contracts/integration_spine_architecture_contract.md`
- `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
- `docs/POST_HARDENING_FOLLOWUPS.md`

## Goal

Repair the per-daypart architecture gap as one coherent server-parity slice:
benchmark/target cycle, active profile, weekly plan, shift close, variance,
history, mobile sync, operator web, admin, and proxy must all agree on keyed
service-period truth.

The desired end state:

- Closed shifts never regrade under a later target cycle.
- Corrected vendor facts can update actuals/provenance without overwriting
  locked target stamps, target scalar values, timing provenance, or the stable
  `service_period_key`.
- Mobile sync receives the same per-daypart closed target stamps that Postgres
  stores.
- Server target cycles and active target profiles carry per-period rows, not
  just whole-day rollup scalars.
- Server weekly-plan snapshots carry locked `day_dayparts` and
  `wage_at_lock_time_json`.
- Closed aggregation uses the canonical business timing profile chain before
  falling back to legacy `locations.business_day_rollover_hour`.
- Admin and operator-web data accuracy surfaces expose the same keyed
  service-period model and hierarchy scope rules.
- Baseline/star selection uses stable service-period identity instead of mutable
  display labels.

## Non-Negotiables

- No live Firebase, Cloud Run, provider, billing, production database, or
  credential action in this slice.
- Do not apply migrations to live or staging databases from this execution.
- Do not remove legacy `daypart` or lunch/dinner/late-night wire compatibility
  in the same slice. Add parity first; contract cleanup later.
- Do not update `PROJECT_TRACKER.md` to claim completion until code,
  verification, and audit evidence exist.
- All schema work follows expand-contract discipline.
- Any migration edits require:
  - `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
  - `dart run tool/migration_cutoff_lint.dart`
- Runtime/proxy contract edits require proxy route tests.
- UI edits require widget/browser-style evidence appropriate to the surface.

## Orchestrator Role

Codex main chat is the orchestrator and audit gate.

Responsibilities:

- Maintain this execution plan and adjust lane sequencing when implementation
  reveals a dependency.
- Keep lane ownership disjoint.
- Do the highest-risk integration review across all worker outputs.
- Resolve shared-seam conflicts.
- Run targeted verification after integration.
- Record residual risks honestly.
- Avoid tracker closeout until the repo state supports it.

The orchestrator does not rubber-stamp worker reports. Each worker result must
be reviewed against the actual diff, contracts, phase plan, and tests.

## Worker Lanes

### Lane A - Closed Shift Truth And Mobile Shift Sync

Owns:

- `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
- `tool/advisor_proxy/proxy_bootstrap.dart` shift-record select/JSON regions
- `lib/services/sync/**` shift-record parsing only if needed
- `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`
- relevant proxy/mobile shift sync tests

Tasks:

1. Add a failing regression for corrected-fact re-aggregation preserving the
   prior target snapshot, per-period target stamps, timing profile/version, and
   `service_period_key`.
2. Change conflict/update behavior so target snapshot fields are preserved when
   a prior row exists.
3. Update proxy shift-record sync to select and emit all `daypart_target_*` and
   `daypart_opz_*` fields.
4. Add mobile sync coverage proving those fields persist through SQLite.
5. Do not edit target-cycle, weekly-plan, admin, or baseline files.

Acceptance:

- Closed correction updates actuals/provenance only.
- Per-period target stamps written in Postgres are present in proxy JSON and
  mobile SQLite.
- Existing timing provenance sync behavior remains intact.

### Lane B - Target Cycle And Active Profile Per-Period Sync

Owns:

- `lib/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart`
- `lib/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart`
- `tool/advisor_proxy/star_target_routes.dart`
- `lib/services/sync/star_target_sync_resources.dart`
- star-target sync tests

Tasks:

1. Wire `target_cycle_dayparts` read/write for server target cycles.
2. Ensure target cycle JSON includes per-period rows.
3. Ensure active profile JSON exposes per-period rows, either from profile
   projection storage or by deriving from the active cycle's child rows.
4. Update mobile sync DTOs so `TargetCycle.dayparts` and
   `ActiveTargetProfile.dayparts` survive server sync.
5. Add tests for arbitrary service-period keys, not just lunch/dinner/late.

Acceptance:

- Server-synced mobile active profile supports `daypartFor(...)` for configured
  periods.
- Parent whole-day target fields remain rollup/cache values.
- Empty child rows remain a documented fallback, never zero sentinels.

### Lane C - Weekly Plan Snapshot Server Parity

Owns:

- `lib/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart`
- `tool/advisor_proxy/weekly_plan_routes.dart`
- `lib/services/sync/weekly_plan_sync_resources.dart`
- weekly-plan sync tests

Tasks:

1. Add server model support for `weekly_plan_snapshot_day_dayparts`.
2. Add server model support for `weekly_plan_snapshots.wage_at_lock_time_json`.
3. Insert/select/serialize both through repository and proxy routes.
4. Parse/sync both into mobile `WeeklyPlanSnapshot`.
5. Add tests proving synced snapshots render locked daypart rows without
   invoking allocator fallback when child rows exist.

Acceptance:

- `day_dayparts` and `wage_at_lock_time_json` round-trip server -> proxy ->
  mobile.
- Existing day-level `day_rows` behavior remains backward compatible.
- Legacy snapshots with no child rows still fall back honestly.

### Lane D - Timing Resolver And Stable Slot Identity

Owns:

- `lib/services/integration/canonical_fact_to_closed_shift_input.dart`
- business-date/timing tests for the aggregator
- `lib/models/baseline_candidate_shift.dart`
- `lib/services/baseline_manager_service.dart`
- `lib/services/star_target_selection_write_service.dart`
- `lib/infrastructure/persistence/sqlite/dao/shift_record_dao.dart`
- targeted baseline/star/slot tests

Tasks:

1. Replace primary closed-aggregation timing lookup with the canonical business
   timing profile resolver.
2. Keep legacy `locations.business_day_rollover_hour` only as a fallback.
3. Add coverage for sub-hour cutoff, inherited org-unit timing, location
   override timing, and post-close label changes.
4. Add stable `servicePeriodKey` to baseline candidates.
5. Make baseline/star selection write stable `service_period_key`.
6. Move local replace-for-slot toward `business_date + service_period_key`
   while preserving compatibility for legacy rows.

Acceptance:

- `04:30` cutoff and inherited timing are honored.
- Manager-selected stars survive service-period label changes.
- No existing legacy rows are silently orphaned.

### Lane E - Admin Keyed Data Accuracy Parity

Owns:

- `lib/admin/screens/per_location_data_accuracy_screen.dart`
- `lib/admin/services/data_accuracy_admin_gateway.dart`
- admin data-accuracy widget/gateway tests
- proxy/admin data-accuracy tests only if required by the admin payload shape

Tasks:

1. Replace hardcoded lunch/dinner/late-night admin override UI with keyed
   service-period rows.
2. Show selected scope, inherited source, and effective value before mutation.
3. Reuse existing keyed service-period data structures where practical.
4. Preserve derived legacy wire keys during transition.
5. Add widget tests for a four-period operator.

Acceptance:

- F&F admin and operator web expose the same configured service periods.
- Admin can mutate arbitrary service-period covers source at the intended
  hierarchy scope.
- Existing three-period clients continue to work.

## Integration Order

1. Land Lane A first because it protects closed truth.
2. Land Lane B and Lane C next; they unblock server-to-mobile parity for target
   and plan truth.
3. Land Lane D once Lane A's slot semantics are clear.
4. Land Lane E after proxy/data-accuracy payload expectations are stable.
5. Run full targeted verification across shift sync, star target sync, weekly
   plan sync, aggregator timing, baseline selection, and admin widget tests.
6. Run migration drift/cutoff tools if any migration changed.
7. Update this doc with execution evidence and residual risks.

## Shared-Seam Rules

- `tool/advisor_proxy/proxy_bootstrap.dart` is shared. Lane A may edit only
  shift-record sync regions. Lane E may edit only data-accuracy regions if
  needed. If both require nearby helper changes, serialize through the
  orchestrator.
- Sync DTOs are shared by runtime sync. Lanes B and C must not edit each
  other's resource files.
- No lane may change tracker state.
- No lane may commit, push, or merge without explicit user instruction.

## Verification Matrix

Minimum targeted commands before closeout:

- `flutter test test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`
- `flutter test test/services/sync/star_target_sync_mirror_test.dart`
- `flutter test test/services/sync/weekly_plan_sync_mirror_test.dart`
- `flutter test test/services/integration/canonical_fact_to_closed_shift_input_test.dart`
- `flutter test test/operator_web/screens/data_accuracy_screen_test.dart`
- `flutter test test/admin/data_accuracy_screen_renders_test.dart`
- `dart analyze`

Additional commands if migrations change:

- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
- `dart run tool/migration_cutoff_lint.dart`

If a broad command times out, capture the timeout, terminate orphaned processes,
then run smaller targeted files and disclose the incomplete gate.

## Current Execution Note

Execution is proceeding in a dedicated worktree:

- Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\per-daypart-server-parity`
- Branch: `codex/per-daypart-server-parity`
- Main checkout remains on `master`.
- No git commit, push, migration application, staging/cloud action, or tracker
  completion claim has been made from this slice.

Implemented in this first execution pass:

- Lane A closed-shift preservation and mobile/proxy sync parity.
- Lane B target-cycle and active-profile per-period server/mobile sync parity.
- Lane C weekly-plan day-daypart and wage-at-lock server/mobile sync parity.
- Lane D canonical timing resolver and stable service-period slot identity.

Still open after this pass:

- Lane E admin keyed data accuracy parity.
- Operator-web/Forge/Flow UX parity audit and visual acceptance.
- Migration/schema rollout proof for new or assumed server columns/tables.
- Live/staging proxy and database verification.
- Tracker, phase-doc, and walkthrough closeout evidence.
