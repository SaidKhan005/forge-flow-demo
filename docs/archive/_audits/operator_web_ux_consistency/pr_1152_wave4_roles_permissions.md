# PR #1152 Wave 4 Roles & Permissions Audit

## Scope

- Operator Web only.
- Wave 4 from `docs/_execution/operator_web_ux_consistency_execution_plan_2026_05_21.md`.
- Keep role scope aligned to the active Operator Web management scope.
- Do not remove the Permission Explainer while it still clarifies permission groups and hidden scope behavior.

## Diff Audit

| Area | Evidence | Result |
| --- | --- | --- |
| Active scope drives role authoring | `lib/operator_web/router/operator_web_router.dart:1030`, `lib/operator_web/router/operator_web_router.dart:1988`, `lib/operator_web/router/operator_web_router.dart:1989` map the selected management scope into the custom role editor. | Pass |
| Roles list states the active scope | `lib/operator_web/screens/roles_screen.dart:391`, `lib/operator_web/screens/roles_screen.dart:427`, `lib/operator_web/screens/roles_screen.dart:440` add the scope note without adding hierarchy clutter. | Pass |
| Custom role editor states the active scope | `lib/operator_web/screens/custom_role_editor_screen.dart:431`, `lib/operator_web/screens/custom_role_editor_screen.dart:550`, `lib/operator_web/screens/custom_role_editor_screen.dart:563`, `lib/operator_web/screens/custom_role_editor_screen.dart:580` add the editor scope context. | Pass |
| Business-wide permissions are hidden below business scope | `lib/services/auth/custom_role_validator.dart:266`, `lib/services/auth/custom_role_validator.dart:267`, `lib/widgets/role_permission_picker.dart:173`, `lib/widgets/role_permission_picker.dart:383` apply the same limited-scope behavior to org-unit and location scopes. | Pass |
| Permission Explainer remains available | The explainer stays in the roles header while the picker notice explains hidden permissions below the business level. | Pass |
| Focused tests cover scope behavior | `test/operator_web/screens/roles_screen_test.dart:127`, `test/operator_web/screens/roles_screen_test.dart:144`, `test/operator_web/screens/custom_role_editor_screen_test.dart:654`, `test/operator_web/screens/custom_role_editor_screen_test.dart:662`, `test/services/auth/custom_role_orphan_lint_test.dart` cover org-unit/location scope copy and filtering. | Pass |

## Backend And Gateway Check

| Question | Evidence | Result |
| --- | --- | --- |
| Can Operator Web create scoped grants? | `lib/operator_web/services/web_team_roles_gateway.dart:244`, `lib/operator_web/services/web_team_roles_gateway.dart:255`, `lib/operator_web/services/web_team_roles_gateway.dart:259` send `scope_type`, `location_id`, and `org_unit_id`. | Pass |
| Does the repository gateway accept business, org-unit, and location scopes? | `lib/services/auth/repository_auth_operations_gateway.dart:2137` through `lib/services/auth/repository_auth_operations_gateway.dart:2139` validate allowed scope values as `operator_wide`, `org_unit`, and `location`. | Pass |
| Are chosen scopes audited? | `lib/services/auth/repository_auth_operations_gateway.dart:934`, `lib/services/auth/repository_auth_operations_gateway.dart:939`, `lib/services/auth/repository_auth_operations_gateway.dart:943` record `auth.role_grant_created` with scope and optional org-unit/location identifiers. | Pass |
| Can the existing member grant flow choose scoped roles? | `lib/operator_web/screens/edit_member_dialog.dart:325` submits scoped grants through the gateway; the dialog already models operator-wide, org-unit, and location grant scopes. | Pass |
| Does demo mode preserve scope behavior? | `lib/operator_web/services/demo_team_roles_gateway.dart:196` stores scoped grant commands for local Operator Web demo QA. | Pass |

## Verification

- `dart analyze lib/services/auth/custom_role_validator.dart lib/widgets/role_permission_picker.dart lib/operator_web/screens/custom_role_editor_screen.dart lib/operator_web/screens/roles_screen.dart lib/operator_web/router/operator_web_router.dart test/operator_web/screens/custom_role_editor_screen_test.dart test/operator_web/screens/roles_screen_test.dart test/operator_web/operator_web_router_test.dart test/services/auth/custom_role_orphan_lint_test.dart`
- `flutter test test/operator_web/screens/custom_role_editor_screen_test.dart test/operator_web/screens/roles_screen_test.dart test/operator_web/operator_web_router_test.dart test/services/auth/custom_role_validator_test.dart test/services/auth/custom_role_orphan_lint_test.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check origin/master...HEAD`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-location-completed`
- Browser QA fallback with local completed-demo web build:
  - `/roles`: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave4-qa\roles-completed-demo.png`
  - `/roles` -> `New role` click-through editor: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave4-qa\roles-new-role-editor-clickthrough.png`

## Decision

GO for merge after the standard pre-merge gate passes.
