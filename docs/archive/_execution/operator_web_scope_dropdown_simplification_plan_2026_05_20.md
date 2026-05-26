# Operator Web Scope Dropdown Simplification Plan

Date: 2026-05-20

## Goal

Make Operator Web use one simple scope control: the top management dropdown/banner.

## Product Rule

- The top dropdown is the place to choose what the operator is managing.
- Page-level hierarchy trees, "Where this applies" cards, and duplicate scope selectors are removed from Operator Web.
- Settings screens can still show small source labels such as "Set here", "Inherited", or "Open timing" when useful.
- Admin Web is not part of this pass.

## Operator Web Surfaces

- Business account:
  - Use the top dropdown for scope.
  - Remove the separate "Where this applies" card.
  - Keep editable account sections.
  - Show compact source/status pills inside section headers only.

- Business setup:
  - Use the top dropdown for location/group context.
  - Remove the hierarchy map and inheritance card from the page.
  - Keep timing-in-use and service periods.
  - Route non-location scopes into the timing editor when those scopes can own timing.

- Business timing editor:
  - Use the top dropdown for where timing is saved.
  - Remove the internal "Where does this profile apply?" selector.
  - Remove the hierarchy tree.
  - Keep effective date, timezone, rollover, week start, and service-period editing.

- Audit log:
  - Use the top dropdown as the hierarchy filter.
  - Remove the separate audit-log hierarchy filter pane.
  - Keep audit filters, rows, export, and integrity badge.
  - Use the hierarchy audit-log gateway when the selected top scope is narrower than business-wide.

- Schedule, Vendor integrations, and Data accuracy:
  - These remain location-owned surfaces.
  - When the top dropdown is business, brand, region, or district, show a simple location list filtered to that selected scope.
  - Picking a location switches the same top dropdown to that location and opens the normal page.
  - Do not add page-level hierarchy cards.

## Risk Controls

- Work in the dedicated worktree only. Keep shared `master` untouched.
- Keep existing gateways and write paths. This pass is a UX/surface refactor, not a schema change.
- Do not touch Admin Web.
- Run focused Operator Web tests plus `dart analyze`.
- Commit and push only after verification.

## Execution Status

- Implemented the larger top management banner in Operator Web.
- Removed duplicate hierarchy cards, maps, and page-level scope selectors from Operator Web pages in scope.
- Kept Account source context as compact card header pills: "Set here", "Inherited", and "Unsaved".
- Business Setup now keeps timing-in-use and service-period review without the extra tree and inheritance card.
- Business Timing now uses the selected top scope for the save target and no longer asks for scope again inside the editor.
- Audit Log now follows the top selected scope for scoped rows and scoped CSV export.
- Schedule, Vendor integrations, and Data accuracy show a simple filtered location list when the top scope is not a location.
- Admin Web remains untouched in this pass.

## Verification

- `flutter test test/operator_web/widgets/hierarchy_map_picker_test.dart test/operator_web/screens/account_screen_test.dart test/operator_web/screens/business_setup_screen_test.dart test/operator_web/screens/business_timing_editor_screen_test.dart test/operator_web/screens/audit_log_screen_test.dart test/operator_web/screens/data_accuracy_screen_test.dart test/operator_web/screens/schedule_screen_test.dart test/operator_web/operator_web_router_test.dart`
- `dart analyze lib/operator_web/widgets/hierarchy_map_picker.dart lib/operator_web/widgets/web_app_shell.dart lib/operator_web/screens/account_screen.dart lib/operator_web/screens/business_setup_screen.dart lib/operator_web/screens/business_timing_editor_screen.dart lib/operator_web/screens/audit_log_screen.dart lib/operator_web/screens/data_accuracy_screen.dart lib/operator_web/screens/schedule_screen.dart lib/operator_web/screens/wage_authority_screen.dart lib/operator_web/router/operator_web_router.dart test/operator_web/widgets/hierarchy_map_picker_test.dart test/operator_web/screens/account_screen_test.dart test/operator_web/screens/business_setup_screen_test.dart test/operator_web/screens/business_timing_editor_screen_test.dart test/operator_web/screens/audit_log_screen_test.dart test/operator_web/screens/data_accuracy_screen_test.dart test/operator_web/screens/schedule_screen_test.dart test/operator_web/operator_web_router_test.dart`
