# PR #1153 Wave 8 Locations UX Audit

## Scope

- Operator Web Locations only.
- Wave 8 from `docs/_execution/operator_web_ux_consistency_execution_plan_2026_05_21.md`.
- Keep existing add, rename, and move behavior intact.
- Preserve read-only behavior for roles that can view but not mutate the hierarchy.

## Diff Audit

| Area | Evidence | Result |
| --- | --- | --- |
| Locations uses shared Operator Web surfaces | `lib/operator_web/screens/hierarchy_screen.dart:499`, `lib/operator_web/screens/hierarchy_screen.dart:508`, and `lib/operator_web/screens/hierarchy_screen.dart:661` use `OperatorWebBanner` and `OperatorWebPanel`. | Pass |
| Page summary is compact and scan-friendly | `lib/operator_web/screens/hierarchy_screen.dart:490`, `lib/operator_web/screens/hierarchy_screen.dart:542`, `lib/operator_web/screens/hierarchy_screen.dart:556`, and `test/operator_web/screens/hierarchy_screen_test.dart:103` add and pin groups, locations, and access summary metrics. | Pass |
| Read-only state is still clear | `lib/operator_web/screens/hierarchy_screen.dart:501` and `test/operator_web/screens/hierarchy_screen_test.dart:164` keep the view-only message visible while mutation buttons remain hidden by existing tests. | Pass |
| Location rows stay bounded in the tree | `lib/operator_web/screens/hierarchy_screen.dart:921`, `lib/operator_web/screens/hierarchy_screen.dart:949`, and `lib/operator_web/screens/hierarchy_screen.dart:951` keep each location annotation compact while preserving the move action key. | Pass |
| Add, rename, and move popups use the same modal primitive | `lib/operator_web/screens/hierarchy_screen.dart:1160`, `lib/operator_web/screens/hierarchy_screen.dart:1303`, and `lib/operator_web/screens/hierarchy_screen.dart:1375` move the dialogs to `OperatorWebDialog` without changing form fields or actions. | Pass |
| Existing behavior remains pinned | `test/operator_web/screens/hierarchy_screen_test.dart:255`, `test/operator_web/screens/hierarchy_screen_test.dart:330`, and `test/operator_web/screens/hierarchy_screen_test.dart:475` still assert add, rename, and move flows. | Pass |

## Verification

- `dart analyze lib/operator_web/screens/hierarchy_screen.dart test/operator_web/screens/hierarchy_screen_test.dart`
- `flutter test test/operator_web/screens/hierarchy_screen_test.dart test/operator_web/widgets/hierarchy_tree_visualization_test.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check origin/master...HEAD`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-location-completed`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-business`
- Browser QA fallback with local `owner-business` web build:
  - `/locations`: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave8-qa\locations-owner-business.png`
  - Add child dialog: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave8-qa\locations-add-child-dialog.png`
  - Rename dialog: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave8-qa\locations-rename-dialog.png`
  - Move dialog: `C:\Users\saidu\AppData\Local\Temp\operator-web-wave8-qa\locations-move-dialog.png`

## Decision

GO for merge after the standard pre-merge gate passes.
