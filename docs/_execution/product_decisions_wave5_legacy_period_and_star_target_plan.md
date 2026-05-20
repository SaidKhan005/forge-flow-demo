# Product Decisions Wave 5: Legacy Periods And Star Targets

Status: complete
Date: 2026-05-20
Branch: `codex/product-decisions-wave5`
Worktree: `.codex_worktrees/product-decisions-wave5`
Base: `origin/master` at `a842954e`

## Plain English Summary

- Custom service-period keys stay valid. A restaurant can use keys like
  `brunch`, `happy_hour`, or `supper_rush`.
- The old `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night` fields are not retired in this wave.
- Before retiring those legacy fields, we need a full impact pass because
  active server routes, admin paths, tests, docs, and migration history still
  mention them.
- Star-target fallback behavior stays as-is. If a period has no selected star
  shift, the app keeps using the existing fallback.
- The only app change in this wave is a small save-time reminder when the
  operator is about to save star shifts while leaving another selectable
  configured period uncovered.
- Hidden server-only admin write routes stay hidden unless a future product
  decision says the UI needs them. No extra UI clutter is added here.

## Legacy Period Impact Audit

Retiring the old lunch, dinner, and late-night keys still needs a staged plan.
The database column retirement is already handled by R7d. The remaining risk
is the JSON/API compatibility bridge. The live impact map is:

- Server write routes still read legacy request keys before mapping them into
  keyed per-period storage:
  - `tool/advisor_proxy/advisor_proxy.dart:16700`
  - `tool/advisor_proxy/advisor_proxy.dart:16758`
  - `tool/advisor_proxy/proxy_bootstrap.dart:3391`
  - `tool/advisor_proxy/proxy_bootstrap.dart:5529`
  - `tool/advisor_proxy/proxy_bootstrap.dart:5643`
- Server read compatibility still emits legacy-shaped response fields for some
  mobile and proxy clients:
  - `tool/advisor_proxy/proxy_bootstrap.dart:10023`
  - `test/proxy/mobile_operational_sync_routes_test.dart:151`
  - `test/services/sync/http_sync_proxy_client_test.dart:366`
- Admin still carries a non-keyed fallback path for older or test-only payloads:
  - `lib/admin/screens/per_location_data_accuracy_screen.dart:803`
  - `lib/admin/services/data_accuracy_admin_gateway.dart:648`
  - `lib/admin/services/data_accuracy_admin_gateway.dart:693`
  - `lib/admin/services/data_accuracy_admin_gateway.dart:1526`
  - `lib/admin/services/data_accuracy_admin_gateway.dart:1650`
- Audit-history display logic still labels legacy diff keys:
  - `lib/admin/widgets/data_accuracy_audit_history_panel.dart:281`
- Operator Web is already on the keyed path and explicitly avoids sending the
  legacy trio:
  - `lib/operator_web/services/operator_web_data_accuracy_gateway.dart:330`
  - `test/operator_web/services/operator_web_data_accuracy_gateway_test.dart:215`
- Migration history created, backfilled, mapped, and later dropped the legacy
  columns. Any retirement pass must preserve that history and only change live
  compatibility behavior deliberately:
  - `db/migrations/202605050000_phase_8_data_accuracy_settings.sql:63`
  - `db/migrations/202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql:119`
  - `db/migrations/202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql:214`
  - `db/migrations/202605170200_per_daypart_v1_r7d_drop_legacy_covers_columns.sql:244`
- Active docs still reference the old trio in walkthroughs, plans, or contract
  notes. Those should be cleaned only when the staged retirement choice is
  made:
  - `docs/contracts/data_accuracy_settings_contract.md:346`
  - `docs/_walkthroughs/8.spine-bridge.C.md:223`
  - `docs/_execution/surface_parity_gap_execution_plan.md:47`
  - `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:468`

## Retirement Guardrails

- Do not remove legacy request parsing until all current clients are checked.
- Do not remove legacy response fields until mobile sync, closed-shift
  projection, and proxy tests are moved to keyed data or explicitly waived.
- Do not rewrite historical migrations. Add forward-only compatibility changes
  if retirement is approved.
- Keep custom service-period keys valid throughout the retirement path.
- Keep fallback behavior until a separate architecture slice replaces it.

## Execution Plan For This Wave

1. Document the decisions above so future cleanup does not retire fields
   blindly.
2. Leave the legacy server and admin compatibility paths unchanged.
3. Add only a save-time star-target reminder:
   - Trigger when a configured service period has selectable candidates.
   - Trigger when the operator saves with that selectable period uncovered.
   - Do not trigger when a configured period has no selectable candidates,
     because there is nothing useful for the operator to fix.
4. Verify with a focused widget test, analyzer, UX copy lint, and diff check.

## Result

- Product decisions are persisted in this document.
- Legacy server/admin compatibility paths are unchanged.
- Star-target fallback behavior is unchanged.
- Choose Star Shifts now shows one save-time reminder when the operator is
  about to save a partial selection while another configured period has
  selectable closed shifts.

## Verification

- `flutter test test\baseline_manager_screen_test.dart` passed.
- `dart analyze lib\screens\baseline_manager_screen.dart test\baseline_manager_screen_test.dart` passed.
- `dart run tool\ux_em_dash_lint.dart` passed.
- `git diff --check` passed with only Git line-ending normalization warnings.
