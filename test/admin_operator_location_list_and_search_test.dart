// Phase 11A.1 — Admin Operator/Location screen widget tests: SCOPE TREE
// + SEARCH.
//
// Bucket 5h of the 2026-05-20 test-suite tightening audit. Split out
// of the ~2,131-line `admin_operator_location_screen_test.dart`
// monolith. Originally covered the flat operator-list, search, setup
// tiles, and master/detail tile-tap navigations.
//
// Reconciled 2026-05-24 for the Business-accounts scope-pane rebuild:
// the screen now presents the SAME left searchable scope tree as the AI
// setup tabs (`AdminScopeTreePane`) + a right detail pane, so these
// tests assert business selection through the scope tree
// (`admin_setup_scope_business_*` / `admin_setup_scope_search`) and the
// detail pane (`admin_operator_detail_*` / `admin_operators_detail_empty`)
// instead of the removed flat list, search field, and drill-in setup
// tiles. Tile-tap navigation to the per-business setup screens moved to
// the always-on sidebar cluster (covered by `admin_shell_widget_test.dart`).
//
// Shared fixtures (`wrap`, `seedBundle`) and bounded pump helpers
// (`pumpEventually`) live in `admin_operator_location_test_helpers.dart`
// and `_test_helpers/widget_pump_helpers.dart`, respectively, so each
// split file imports a single source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  testWidgets('renders one scope-tree row per seeded operator', (tester) async {
    // Wide window so the split layout renders both the left scope tree
    // and the right detail pane (compact widths fold them into tabs).
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    // The shared scope tree renders one selectable business row per
    // seeded operator (no flat operator list / "manage" rows anymore).
    expect(
      find.byKey(const Key('admin_setup_workspace_scope_pane')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_setup_scope_business_op-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_setup_scope_business_op-2')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operator_row_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsNothing);
    expect(find.byKey(const Key('admin_operator_manage_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_manage_op-2')), findsNothing);
    expect(find.text('Click to manage'), findsNothing);

    // "New business" onboarding moved into the top of the scope pane and
    // keeps its full-size affordance.
    final newBusinessSize = tester.getSize(
      find.byKey(const Key('admin_operators_new_button')),
    );
    expect(newBusinessSize.width, greaterThanOrEqualTo(168));
    expect(newBusinessSize.height, greaterThanOrEqualTo(50));

    // Before any business is picked the right pane shows the "Select a
    // business" empty prompt, and the removed drill-in setup tiles /
    // groups are gone.
    expect(
      find.byKey(const Key('admin_operators_detail_empty')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operator_detail_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_business_setup_op-1')), findsNothing);
    expect(
      find.byKey(const Key('admin_business_setup_group_operations')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_data_accuracy')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_integrations')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_support_logs')),
      findsNothing,
    );

    // Both business names are discoverable in the scope tree.
    expect(find.text('Alpha Cafe'), findsWidgets);
    expect(find.text('Beta Bistro'), findsWidgets);
  });

  testWidgets('selecting a scope-tree business shows it in the detail pane', (
    tester,
  ) async {
    // Wide window so the right detail pane is visible alongside the tree.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    // No business is auto-selected: the detail pane starts on the empty
    // prompt (mirrors the AI tabs' "select a scope" behavior).
    expect(
      find.byKey(const Key('admin_operators_detail_empty')),
      findsOneWidget,
    );

    final betaRow = find.byKey(const Key('admin_setup_scope_business_op-2'));
    await tester.ensureVisible(betaRow);
    await pumpEventually(tester);
    await tester.tap(betaRow);
    await pumpEventually(tester);

    // The right detail pane now renders the picked business profile.
    expect(
      find.byKey(const Key('admin_operators_detail_empty')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_operator_detail_op-2')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operator_profile_card')), findsOneWidget);
    expect(find.text('Beta Bistro'), findsWidgets);
  });

  testWidgets('scope-tree search filters businesses by name', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(
          operatorId: 'op-2',
          businessName: 'Beta Bistro',
          primaryLocationId: 'loc-beta',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    // Search lives in the shared scope tree now, not a dedicated
    // operator-list search field.
    expect(
      find.byKey(const Key('admin_operators_search_field')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const Key('admin_setup_scope_search')),
      'beta',
    );
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_setup_scope_business_op-1')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_setup_scope_business_op-2')),
      findsOneWidget,
    );

    // The seeded locations are both named "HQ"; searching that name
    // matches both businesses (the tree matches business/org-unit/
    // location names).
    await tester.enterText(
      find.byKey(const Key('admin_setup_scope_search')),
      'hq',
    );
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_setup_scope_business_op-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_setup_scope_business_op-2')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_setup_scope_search')),
      'zzzz',
    );
    await pumpEventually(tester);

    // No business matches: the scope tree shows its empty-search card
    // (the old `admin_operators_no_matches` list state is gone).
    expect(find.byKey(const Key('admin_setup_scope_empty')), findsOneWidget);
    expect(find.byKey(const Key('admin_operators_no_matches')), findsNothing);
  });

  testWidgets('stacks scope/detail panes into tabs on compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-compact',
          businessName: 'Very Long Compact Width Operator Name',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    // Compact widths fold the left scope tree + right detail pane into a
    // two-tab layout instead of the side-by-side split.
    expect(
      find.byKey(const Key('admin_operators_workspace_tabs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_operators_workspace_split')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_setup_scope_business_op-compact')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the empty state when no operators are seeded', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway();
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_empty')), findsOneWidget);
    expect(find.text('No business accounts yet'), findsOneWidget);
  });
}
