# Graph Audit Fix Wave Execution Plan

Branch: `codex/graph-audit-fix-wave`
Started: 2026-05-19
Base: `origin/master` after PRs #1009, #1010, and #1013 merged.

## Role Split

- Orchestrator:
  - Owns merge safety, branch hygiene, final integration, verification, commit, push, and PR.
  - Owns high-contention proxy files unless explicitly handed to one worker.
  - Does not edit the shared checkout; main checkout stays on `master`.
- Workers:
  - Work in their forked workspaces.
  - Own only their assigned files.
  - Do not revert unrelated changes.
  - Do not update trackers.
  - Do not merge.

## First Wave

### Local Orchestrator Lane - Admin Proxy Hardening

Files:
- `tool/advisor_proxy/advisor_proxy.dart`
- `tool/advisor_proxy/proxy_bootstrap.dart`
- `test/proxy/data_accuracy_admin_routes_test.dart`
- `test/proxy/mobile_operational_sync_routes_test.dart`

Goals:
- Require `Idempotency-Key` for admin Data Accuracy writes.
- Transport Data Accuracy source metadata through admin read JSON.
- Add real calendar-date validation for manual covers and effective business dates where scoped to this route family.
- Ensure keyed-only Data Accuracy saves do not synthesize hidden legacy lunch / dinner / late_night writes.

### Worker A - Operator Web Data Accuracy

Files:
- `lib/operator_web/screens/data_accuracy_screen.dart`
- `lib/operator_web/services/operator_web_data_accuracy_gateway.dart`
- `test/operator_web/screens/data_accuracy_screen_test.dart`
- `test/operator_web/services/operator_web_data_accuracy_gateway_test.dart`
- `test/operator_web/services/operator_web_stable_idempotency_g60_test.dart`

Goals:
- Preserve server source metadata while rendering/editing Data Accuracy settings.
- Stop new Operator Web saves from sending the legacy lunch/dinner/late-night covers fields.
- Add four-period/custom-period coverage.

### Worker B - Mobile Star-Shift Projection

Files:
- `lib/forge_flow_bootstrap.dart`
- `lib/services/star_target_selection_write_service.dart`
- `test/services/star_target_selection_write_service_test.dart`
- `test/proxy/selected_star_target_routes_test.dart` only if route-level proof is needed.

Goals:
- Add per-service-period target rows to mobile star-shift projection.
- Keep existing selected-star write route shape compatible.
- Prove target-cycle daypart rows are sent when star shifts span service periods.

### Worker C - Narrow Role Taxonomy Cleanup

Files:
- `lib/screens/settings_screen.dart`
- `lib/services/team/team_scope_visibility_policy.dart`
- `lib/auth/role_management_policy.dart`
- `test/screens/settings_screen_collapse_test.dart`
- `test/permission_runtime_test.dart`
- `test/auth/role_management_policy_test.dart`

Goals:
- Replace retired mobile/team gate checks with `operator_general_manager`.
- Keep compatibility only where explicitly mapping old input labels to v2 constants.
- Add tests so real General Manager works and retired `operator_manager` does not silently pass new runtime gates.
- Close the small grant-policy straggler found during review: current `operator_general_manager` / `location_manager` get v2 grant posture, and retired `operator_manager` is denied as an actor.

## Findings During Execution

- Operator Web was fixed to stop sending legacy covers fields, but the mobile/proxy write path still synthesized default lunch/dinner/late_night rows when those fields were absent. Fixed in the same wave so keyed-only saves stay clean.
- `lib/auth/role_management_policy.dart` still had a v1-only `operator_manager` grant branch. It was small and in-scope for the role cleanup, so it was fixed instead of deferred.
- Broader role literal sweep remains separate: docs, old migrations, archived walkthroughs, and operator-web auth convergence still contain intentional or already-tracked v1 references. Do not sweep those inside this patch.

## Out Of First Wave

- Full proxy-wide `operator_admin` sweep.
- Product decision on admin pre-staged service-period keys.
- Mobile source-label UX, unless the first wave leaves a tiny non-conflicting slot.

## Verification

- `flutter test test/proxy/data_accuracy_admin_routes_test.dart`
- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- `flutter test test/per_daypart_v1_r7b_proxy_covers_keyed_test.dart`
- `flutter test test/operator_web/screens/data_accuracy_screen_test.dart test/operator_web/services/operator_web_data_accuracy_gateway_test.dart`
- `flutter test test/services/star_target_selection_write_service_test.dart`
- `flutter test test/screens/settings_screen_collapse_test.dart test/permission_runtime_test.dart test/auth/role_management_policy_test.dart`
- `dart analyze --fatal-infos` on changed Dart files.
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`
