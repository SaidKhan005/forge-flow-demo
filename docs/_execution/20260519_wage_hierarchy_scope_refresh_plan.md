# Wage hierarchy scope refresh plan

Date: 2026-05-19

Worker: Worker Wage

Branch: `codex/wage-hierarchy-scope-refresh`

Worktree: `.codex_worktrees/wage-hierarchy-scope-refresh`

## Prior work reused

Closed PR #836 (`claude/gap-b2-wage-role-rows-hierarchy-scope`) supplied the useful direction: add hierarchy scope fields to `wage_role_rows`, add a resolver that prefers Location over nearest org unit over Business, and surface set/inherited scope in Operator Web Wage Authority.

That PR was intentionally closed unmerged. Its own notes also identified a live-path gap: the proxy route/repository still wrote location-only rows, so live saves would not actually persist Business or org-unit scope. I reused the model/resolver/UI direction, but refreshed the schema and proxy path instead of copying the old branch wholesale.

## Current findings

- Live Wage Authority still depended on location-only proxy reads/writes before this slice.
- The old PR #836 migration described Business/org-unit rows with `location_id = NULL`, but it did not drop the existing `location_id NOT NULL` table constraint.
- The old PR #836 approach did not provide a null-safe scope-aware upsert key for Business/org-unit rows.
- Operator Web Data Accuracy embeds Wage Authority, so the embedded surface also needs hierarchy nodes and selected-location ancestor ids. Otherwise org-unit inheritance would resolve incorrectly even if the standalone screen worked.

## Scope

Owned files are limited to the wage hierarchy slice:

- `wage_role_rows` migration/model/repository/proxy write route/proxy read route.
- Operator Web Wage Authority gateway, screen, and Data Accuracy embed pass-through.
- Wage scope resolver and focused tests.
- This execution plan doc.

No project trackers are updated by this worker.

## Schema and operator approval gate

This is SCHEMA-TOUCHING and PROXY-TOUCHING.

The migration:

- Adds `scope_type`, `org_unit_id`, and `inherited_from_scope_id` to `public.wage_role_rows`.
- Drops `location_id NOT NULL` so Business/org-unit rows can have no location payload.
- Adds scope payload CHECK constraints.
- Adds an org-unit FK and a null-safe scope unique index for upsert.
- Changes the `wage_role_rows_per_tenant` RLS policy from operator+location to operator-only so operator owners can read and write higher-scope wage rows.

Because RLS and schema are touched, this PR requires explicit operator approval before merge. The orchestrator should pause at this gate.

## Verification plan

Planned:

- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
- `dart run tool/migration_cutoff_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart analyze`
- Focused tests:
  - `flutter test test/infrastructure/persistence/postgres/repositories/wage_role_rows_repository_test.dart`
  - `flutter test test/proxy/operator_routes_wage_role_rows_test.dart`
  - `flutter test test/proxy/wage_role_rows_write_routes_test.dart`
  - `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
  - `flutter test test/operator_web/services/operator_web_http_wage_authority_gateway_test.dart`
  - `flutter test test/operator_web/services/operator_web_wage_authority_gateway_effective_test.dart`
  - `flutter test test/services/wage/wage_role_row_scope_resolver_test.dart`
  - `flutter test test/operator_web/screens/wage_authority_scope_test.dart`
  - `flutter test test/operator_web/screens/wage_authority_screen_test.dart`

Results:

- `flutter pub get`: pass.
- `dart analyze`: pass, no issues found. First attempt before worktree package hydration timed out at 120s; rerun after `flutter pub get` passed.
- `dart analyze <focused touched files>`: pass, no issues found.
- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`: pass after rebasing onto current `origin/master`. Pre-rebase, this failed because this branch temporarily made `202605191200_wage_role_rows_hierarchy_scope_refresh.sql` the latest migration while shared authority/backlog docs still pointed at `202605191000_per_daypart_v1_r7f_data_accuracy_precedence_fix.sql`. Current `origin/master` now carries the newer `202605191830_canonical_fact_projection_retry_jobs.sql` migration and authority-doc cutoff updates, so no tracker/backlog edits were needed here.
- `dart run tool/migration_cutoff_lint.dart`: pass after rebase, cutoff is `202605191830_canonical_fact_projection_retry_jobs.sql`.
- `dart run tool/index_leading_column_lint.dart`: pass.
- `dart run tool/rls_policy_lint.dart`: pass.
- `dart run tool/advisor_proxy_size_lint.dart`: pass.
- `dart run tool/postgres_import_lint.dart`: pass.
- `dart run tool/ux_em_dash_lint.dart`: pass.
- Focused test bundle: pass, 96 tests.
