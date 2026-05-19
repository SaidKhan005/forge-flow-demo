# Post-1020 Gap Fix Execution Plan

Created: 2026-05-19
Branch: `codex/post-1020-gap-fix`
Base: `origin/master` at `152adea1`

## Goal

Close the remaining gaps found by the deeper graph/code audit after PR #1020.
Keep the shared checkout on `master`; all edits happen in this worktree.

## Confirmed Gaps

1. Covers source is not lossless end to end.
   - `reservation_plus_walkin` is valid in the keyed service-period table.
   - `DataAccuracySettings` still treats it as unsupported and falls back to Vendor.
   - Operator Web can therefore show one source in the keyed card and another in the main source card.

2. Closed-shift reservation covers are too eager.
   - Reservation plus walk-in math can run even when the operator did not select that source.
   - Vendor/default paths should not silently pull reservation facts.

3. Mobile target-profile sync can reattach the wrong dayparts.
   - The proxy sends `target_cycle_id` and daypart rows.
   - The SQLite active-profile cache drops the cycle identity and later hydrates from the latest local active cycle.
   - Learn can then use daypart targets from the wrong cycle.

4. Learn repeatable wins still have static service-period ordering.
   - Shift, Operator Web, and Admin support configured service periods.
   - Learn ranking still has a hardcoded order unless a caller manually injects a resolver.

5. Mobile Covers Setup loses winning source labels.
   - The server sends source metadata.
   - The mobile service-period cache stores the effective source value but drops the source label metadata.
   - The mobile form shows a generic label instead of Business, Org unit, Location, or Default.

6. F&F Admin custom-role creation is weaker than Operator Web.
   - Operator Web expands implied permissions and blocks empty saves.
   - Admin custom-role creation submits raw selected keys and can create an empty role.

7. Active docs still mention superseded roles and old Covers columns.
   - Some active walkthroughs and plans still point operators at `operator_admin`, retired v1 roles, or `covers_source_lunch`.
   - Historical audit records should stay historical; active operator-facing docs should be corrected or marked closed.

## Execution Lanes

### Lane A - Covers and Mobile Source Labels

Owner: Orchestrator

Files expected:
- `lib/domain/models/data_accuracy_settings.dart`
- `lib/domain/models/data_accuracy_service_period_setting.dart`
- `lib/services/integration/canonical_fact_to_closed_shift_input.dart`
- `lib/operator_web/widgets/covers_source_toggle.dart`
- `lib/operator_web/screens/data_accuracy_screen.dart`
- `lib/operator_web/services/operator_web_data_accuracy_gateway.dart`
- `lib/infrastructure/persistence/sqlite/dao/data_accuracy_service_period_settings_cache_dao.dart`
- `lib/infrastructure/persistence/sqlite/repositories/sqlite_data_accuracy_service_period_settings_cache_repository.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart`
- `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`
- `lib/screens/settings/settings_covers_setup_section.dart`
- Focused tests under `test/services/integration`, `test/operator_web`, `test/services/sync`, and `test/screens`.

Fix:
- Preserve `reservation_plus_walkin` in the main settings model.
- Gate reservation plus walk-in aggregation so it only runs when selected.
- Keep explicit Vendor, Forecast, and Manual behavior unchanged.
- Persist Covers source metadata in the mobile keyed settings cache.
- Show the real source label in Mobile Covers Setup when metadata exists.

Risk controls:
- Do not add new proxy routes.
- Do not change database production migrations.
- SQLite migration must be additive and nullable.
- Add regression tests for vendor/default not using reservation facts.

### Lane B - Target Profile and Learn Dynamic Service Periods

Owner: Worker

Files expected:
- `lib/domain/models/active_target_profile.dart`
- `lib/infrastructure/persistence/sqlite/dao/target_profile_dao.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart`
- `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`
- `lib/services/daypart_pattern_summary_builder.dart`
- `lib/services/learn_repeatable_wins_read_service.dart`
- `lib/screens/variance/variance_learn_tab.dart`
- Focused tests under `test/services/sync`, `test/active_target_profile_dayparts_test.dart`, and `test/learn_repeatable_wins_read_service_test.dart`.

Fix:
- Store `target_cycle_id` and `target_profile_version_id` on mobile active target profiles.
- Hydrate daypart rows from that exact cycle when present.
- Keep the current latest-active-cycle fallback only for old cached rows.
- Let Learn use configured service-period labels and order.

Risk controls:
- SQLite migration must be additive and nullable.
- Existing profile reads with no cycle id must behave as before.
- Learn must keep legacy labels for old rows.

### Lane C - Admin Custom Role Parity

Owner: Worker

Files expected:
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`
- `test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart`

Fix:
- Expand implied permissions before Admin submits a custom role.
- Block creating a custom role with no effective permissions.
- Keep Barrio-disabled behavior unchanged.

Risk controls:
- Do not change seeded role editing in this lane.
- Do not change gateway payload shape except the permission list contents.

### Lane D - Active Doc Cleanup

Owner: Worker

Files expected:
- `docs/_execution/next_deeper_gap_audit_execution_plan.md`
- `docs/_execution/surface_parity_remaining_gaps_execution_plan.md`
- `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`
- `docs/_walkthroughs/8.spine-bridge.B.md`
- `docs/_walkthroughs/8.spine-bridge.C.md`
- `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`
- `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md`

Fix:
- Mark PR #1020-era execution plans closed or superseded.
- Update active walkthroughs away from old roles and old Covers columns.
- Add role-supersession notes where large old phase plans are still useful history.
- Do not edit `docs/ARCHITECTURE.md`.
- Do not rewrite historical audit docs.

Risk controls:
- Preserve historical context when a doc is a dated plan.
- Prefer short supersession notes over broad rewrites.

## Verification Plan

- Run focused Flutter tests for changed widgets/services.
- Run focused sync/model tests for SQLite and target-profile changes.
- Run focused integration tests for closed-shift Covers resolution.
- Run `dart analyze --fatal-infos` on changed Dart files.
- Run `dart run tool/ux_em_dash_lint.dart`.
- Run `git diff --check`.
- Because this touches `lib/**`, run `tool/pre_merge_gate.sh <PR>` before merge.
- After merge, run `tool/verify_pr_landed.sh <PR>` with symbols from the fix.

## Worker Rules

- Workers are not alone in the codebase.
- Workers must not revert edits outside their lane.
- Workers must keep to their assigned file sets.
- Workers stop after their lane is implemented and tested.
- The orchestrator integrates, audits, commits, pushes, opens the PR, gates, merges, and verifies landed content.
