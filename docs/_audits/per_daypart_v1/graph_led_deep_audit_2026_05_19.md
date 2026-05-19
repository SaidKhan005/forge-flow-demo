# Graph-Led Deep Audit - 2026-05-19

Branch: `codex/graph-led-deep-audit`
Worktree: `.codex_worktrees/per-daypart-server-parity`
Base branch in worktree: `codex/data-accuracy-write-idempotency`
Shared checkout: stayed on `master`

## Graph Source

- Used local graph output at `graphify-out/graph.json`.
- Graph file timestamp: 2026-05-19 02:34:52 local.
- Graph report timestamp: 2026-05-19 02:36:02 local.
- Graph size checked in this pass: 22,419 nodes and 27,487 edges.
- Relevant high-degree graph neighborhoods:
  - Data Accuracy: `lib/operator_web/screens/data_accuracy_screen.dart`, `lib/admin/services/data_accuracy_admin_gateway.dart`, `tool/advisor_proxy/proxy_bootstrap.dart`
  - Admin/proxy: `tool/advisor_proxy/advisor_proxy.dart`, `tool/advisor_proxy/operator_benchmark_overrides_routes.dart`
  - Star shifts and target cycles: `lib/services/star_target_selection_write_service.dart`, `tool/advisor_proxy/star_target_routes.dart`, `lib/services/server_target_cycle_projection_service.dart`
  - Auth role drift: `docs/contracts/auth_permission_key_catalog.md`, `lib/services/team/team_scope_visibility_policy.dart`, proxy role allow-lists

## Old Gaps Rechecked

- Mobile manual covers are no longer local-only for signed-in live Settings.
  - `lib/screens/settings_screen.dart` injects `AuthSessionManualCoversWriter`.
  - `lib/services/manual_covers_write_service.dart` writes the proxy first, then mirrors SQLite.
  - `tool/advisor_proxy/advisor_proxy.dart` requires `Idempotency-Key` for `data_accuracy_settings/manual_covers`.
- Hidden benchmark override write routes are fail-closed.
  - `tool/advisor_proxy/operator_benchmark_overrides_routes.dart` returns HTTP 410 for legacy write verbs.
  - It points callers to `mobile_baseline_manager_selected_star`.
- Service-period editor field coverage is in place.
  - `lib/operator_web/widgets/service_period_editor.dart` carries `applicableDays`, `shortLabel`, and `sortOrder`.
  - `lib/operator_web/screens/business_timing_editor_screen.dart` passes those fields to and from the wire payload.
- Server source metadata exists for the operator/mobile Data Accuracy read path.
  - `db/migrations/202605190900_per_daypart_v1_r7e_data_accuracy_provenance.sql` adds the effective source columns.
  - Operator/mobile proxy reads emit those source fields.

## New Findings

### P1 - Mobile Star-Shift Projection Still Writes Whole-Day Targets Only

- Mobile star selection is wired and posts through the canonical selected-star route.
- The gap is the projection payload after selection:
  - `lib/forge_flow_bootstrap.dart:196` averages all selected candidates into one pooled target.
  - `lib/services/star_target_selection_write_service.dart:68` serializes only scalar `standards`.
  - `tool/advisor_proxy/star_target_routes.dart:841` can accept `target_cycle_dayparts` or `dayparts`, but mobile never sends them.
  - `lib/services/server_target_cycle_projection_service.dart:120` writes per-period child rows only from `standards.dayparts`.
- Impact:
  - Star shifts still "work" as a write path.
  - But the new target cycle can be missing per-period targets, so downstream daypart surfaces can fall back to pooled whole-day standards.
- Fix:
  - Add per-service-period rows to `StarTargetProjectionContext`.
  - Group selected candidates by stable `servicePeriodKey`.
  - Send `target_cycle_dayparts` with per-period target CPLH, SPLH, PPA, OPZ bounds, and cover count.
  - Add mobile writer and proxy tests proving child rows are present.

### P1 - Admin Data Accuracy Writes Can Bypass Idempotency

- `tool/advisor_proxy/advisor_proxy.dart:14337` accepts an empty `Idempotency-Key`.
- `tool/advisor_proxy/admin_route_group_part.dart:647` bypasses `_runAdminIdempotent` when the key is empty.
- The admin client sends keys, but the server does not require them.
- Impact:
  - Direct admin retries can double-write and double-audit Data Accuracy changes.
- Fix:
  - Require a non-empty `Idempotency-Key` for all admin Data Accuracy PATCH/PUT writes.
  - Keep max length validation.
  - Add missing/replay/conflict tests in `test/proxy/data_accuracy_admin_routes_test.dart`.

### P1 - Data Accuracy Source Metadata Still Does Not Reach All UI

- Operator Web parses source metadata, but drops it before render:
  - `lib/operator_web/screens/data_accuracy_screen.dart:455` rebuilds a fresh `DataAccuracySettings`.
  - The rebuild does not copy `coversSourcePerServicePeriodSources`, `wageSourceSource`, or `walkInHandlingModeSource`.
  - Widgets render source labels only if that metadata survives.
- Admin list/scope rows also strip source metadata:
  - `tool/advisor_proxy/proxy_bootstrap.dart:5057` and `:6123` read the effective settings view but omit the three `*_source` columns.
  - `tool/advisor_proxy/proxy_bootstrap.dart:6284` emits settings JSON without those fields.
- Repository reads are also behind:
  - `lib/services/data_accuracy/data_accuracy_settings_repository.dart` still builds its own projection and does not return source metadata.
- Impact:
  - The SQL view is fixed, but admin and operator-visible source labels are still incomplete.
  - This keeps HP #11 partially open for Data Accuracy.
- Fix:
  - Preserve source fields in Operator Web materialization.
  - Add the three source fields to admin selects and `_settingsJson`.
  - Either switch repository reads to the effective view or extend the repository projection with the same source fields.
  - Add tests that source labels render from real gateway payloads.

### P1 - Legacy Lunch/Dinner/Late-Night Payloads Can Still Create Ghost Settings

- Contract says the old trio shape is rejected for new implementation work:
  - `docs/contracts/data_accuracy_settings_contract.md:344`.
- Operator Web still emits the old keys on save:
  - `lib/operator_web/services/operator_web_data_accuracy_gateway.dart:250`.
- Proxy/admin still accept old keys and map them into keyed rows:
  - `tool/advisor_proxy/advisor_proxy.dart:16616`.
  - `tool/advisor_proxy/proxy_bootstrap.dart:5222`.
- Impact:
  - A custom-period operator can save one real period, while the request also writes hidden `lunch`, `dinner`, and `late_night` defaults.
  - This does not break the visible row immediately, but it reintroduces the hardcoded trio under the keyed model.
- Fix:
  - Stop new clients from sending the legacy trio fields.
  - Add tests for a four-period operator and assert no legacy trio keys are emitted.
  - Decide whether server should reject legacy trio fields now, or keep a short compatibility path that validates keys against configured timing.

### P1 - Role Taxonomy Drift Still Exists Outside Operator Web

- The auth catalog says:
  - `operator_admin` was never seeded.
  - `operator_manager` is retired and maps to `operator_general_manager`.
  - Source: `docs/contracts/auth_permission_key_catalog.md:385`.
- Operator Web cleaned this up for its main admit set.
- Remaining drift:
  - `tool/advisor_proxy/advisor_proxy.dart:17747` still lets `operator_admin` mutate Data Accuracy.
  - `lib/screens/settings_screen.dart:599` still treats retired `operator_manager` as mobile admin tier and misses `operator_general_manager`.
  - `lib/services/team/team_scope_visibility_policy.dart:67` still special-cases `operator_manager`, so a real General Manager can miss Team nav despite having the v2 permission set.
  - Broader proxy/read routes still contain `operator_admin` allow-lists.
- Impact:
  - A phantom role can still pass some server gates.
  - A real v2 General Manager can be hidden from expected mobile/team surfaces.
- Fix:
  - First fix Data Accuracy and Settings/Team runtime gates.
  - Then run a dedicated proxy role-taxonomy sweep for every remaining `operator_admin` and `operator_manager` occurrence.

### P2 - Admin Service-Period Overrides Accept Arbitrary Keys

- Admin override dialog has a free-text service-period key field.
- Proxy validates syntax only:
  - `tool/advisor_proxy/advisor_proxy.dart:17938`.
  - `tool/advisor_proxy/proxy_bootstrap.dart:4044`.
- Impact:
  - Admin can create a Data Accuracy service-period override for a key no configured timing profile uses.
- Decision:
  - If pre-staging future period keys is intended, document it clearly.
  - Otherwise, admin should load configured timing periods and choose from that list.

### P2 - Manual Covers Accept Impossible Calendar Dates

- Manual covers validates `business_date` with regex only:
  - `tool/advisor_proxy/advisor_proxy.dart:18024`.
  - `tool/advisor_proxy/proxy_bootstrap.dart:4056`.
- It then stores that string as a JSONB key.
- Impact:
  - `2026-99-99` can be saved but will never match real business-date reads.
- Fix:
  - Add calendar-date validation, not just shape validation.
  - Reuse the same validator for manual covers and service-period effective dates.

### P2 - Mobile Carries Source Metadata But Does Not Show It

- Mobile sync parses/carries source metadata.
- The mobile Covers Setup form currently shows active scope but no inherited-source line.
- Impact:
  - Mobile manual covers are canonical now, but provenance UX is not full parity with web/admin.
- Product choice:
  - Either explicitly exempt this entry-only mobile form from source-label display.
  - Or add a read-only "Source" line fed from the latest sync snapshot.

### P3 - Stale Comments And Tests Still Mention Old Roles And Legacy Fields

- Examples:
  - `lib/operator_web/screens/data_accuracy_screen.dart:25` still mentions `operator_admin` in a stale comment.
  - `lib/operator_web/widgets/keyed_service_period_accuracy_card.dart:112` says `operator_admin` only.
  - Tests still seed `operator_manager` for selected-star routes even though the route is permission-key based.
- Impact:
  - Mostly comprehension risk, but it hides real role drift during audits.
- Fix:
  - Clean comments/tests in the same slices that touch those files.

## Safe Fix Order

1. **Admin idempotency guard**
   - Single owner for `tool/advisor_proxy/advisor_proxy.dart`.
   - Require `Idempotency-Key` for admin Data Accuracy writes.
   - Add missing/replay/conflict tests.

2. **Provenance transport**
   - One owner for `tool/advisor_proxy/proxy_bootstrap.dart`.
   - One owner for Operator Web UI materialization/tests.
   - Add source columns to admin reads and preserve parsed source metadata in UI.

3. **Keyed-only Data Accuracy payloads**
   - Stop Operator Web from emitting legacy trio fields.
   - Decide server compatibility posture before rejecting old fields.
   - Add four-period custom timing tests.

4. **Star-shift per-period projection**
   - Add per-period projection rows in the mobile star selection writer path.
   - Keep selected-star write route unchanged because it already accepts daypart rows.
   - Add tests proving target cycles and active profiles get child rows.

5. **Role taxonomy cleanup**
   - Fix the narrow Data Accuracy write gate first.
   - Fix mobile Settings admin-tier gate.
   - Fix TeamScopeVisibilityPolicy for `operator_general_manager`.
   - Then do the broader proxy `operator_admin` and `operator_manager` sweep as its own slice.

6. **Validation hardening**
   - Add real calendar-date validation for manual covers and service-period effective dates.
   - Decide whether service-period keys must be configured before writes.

7. **UX/documentation cleanup**
   - Add or explicitly defer mobile source labels.
   - Remove stale role comments and legacy-field wording.

## Parallel Execution Shape

- Do not run two workers against `tool/advisor_proxy/advisor_proxy.dart` at the same time.
- Do not run two workers against `tool/advisor_proxy/proxy_bootstrap.dart` at the same time.
- Clean first wave:
  - Worker A: admin idempotency in `advisor_proxy.dart` plus proxy tests.
  - Worker B: Operator Web provenance preservation and tests.
  - Worker C: star-shift per-period projection and tests.
- Clean second wave:
  - Worker D: admin provenance transport in `proxy_bootstrap.dart`.
  - Worker E: keyed-only Operator Web payload cleanup.
  - Worker F: role taxonomy cleanup for mobile Settings and Team policy.
- Broader proxy role sweep should wait until the narrow role fixes are landed, because it crosses many route files and tests.

## Verification Needed Before Fix PRs Merge

- `flutter test test/proxy/data_accuracy_admin_routes_test.dart`
- `flutter test test/operator_web/screens/data_accuracy_screen_test.dart test/operator_web/services/operator_web_data_accuracy_gateway_test.dart`
- `flutter test test/services/star_target_selection_write_service_test.dart test/proxy/selected_star_target_routes_test.dart`
- `flutter test test/screens/settings_screen_collapse_test.dart test/permission_runtime_test.dart`
- `dart analyze --fatal-infos` on changed Dart files
- `dart run tool/advisor_proxy_size_lint.dart` after proxy edits
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`
