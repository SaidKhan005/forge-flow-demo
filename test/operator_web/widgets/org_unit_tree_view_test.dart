// Phase 11W.3 - Org-unit tree view widget tests.
//
// Pins the parity-contract requirements scoped to the recursive tree:
//
//   - Display order: children sorted alphabetically by `name`;
//     locations sorted alphabetically within their org-unit.
//   - Read-only audiences keep tree expand/collapse interactivity but
//     see no mutate buttons.
//   - Mutate audiences see the add-child + per-location move
//     affordances.
//   - Empty state renders the friendly fallback notice.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/org_unit_tree_view.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  const orgUnits = <TeamOrgUnitEntry>[
    TeamOrgUnitEntry(
      orgUnitId: 'root',
      parentOrgUnitId: null,
      unitType: 'corp',
      path: 'demo',
      label: 'Demo Bistro',
    ),
    TeamOrgUnitEntry(
      orgUnitId: 'south',
      parentOrgUnitId: 'root',
      unitType: 'region',
      path: 'demo.south',
      label: 'South Region',
    ),
    TeamOrgUnitEntry(
      orgUnitId: 'north',
      parentOrgUnitId: 'root',
      unitType: 'region',
      path: 'demo.north',
      label: 'North Region',
    ),
  ];

  const locations = <TeamOrgLocationEntry>[
    TeamOrgLocationEntry(
      locationId: 'loc-zeta',
      parentOrgUnitId: 'north',
      orgUnitPath: 'demo.north',
      label: 'Zeta Cafe',
    ),
    TeamOrgLocationEntry(
      locationId: 'loc-alpha',
      parentOrgUnitId: 'north',
      orgUnitPath: 'demo.north',
      label: 'Alpha Cafe',
    ),
  ];

  testWidgets('renders the empty notice when no org units are supplied', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(800, 600));
    await tester.pumpWidget(
      wrap(
        const OrgUnitTreeView(
          orgUnits: <TeamOrgUnitEntry>[],
          locations: <TeamOrgLocationEntry>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_org_unit_tree_empty')),
      findsOneWidget,
    );
  });

  testWidgets('children sort alphabetically by label (North before South)',
      (tester) async {
    await sizeViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      wrap(
        const OrgUnitTreeView(
          orgUnits: orgUnits,
          locations: locations,
          canMutate: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final northRect = tester.getRect(find.text('North Region'));
    final southRect = tester.getRect(find.text('South Region'));
    expect(
      northRect.top < southRect.top,
      isTrue,
      reason: 'North Region should render before South Region',
    );
  });

  testWidgets('locations within an org unit sort alphabetically (Alpha '
      'before Zeta)', (tester) async {
    await sizeViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      wrap(
        const OrgUnitTreeView(
          orgUnits: orgUnits,
          locations: locations,
          canMutate: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final alphaRect = tester.getRect(find.text('Alpha Cafe'));
    final zetaRect = tester.getRect(find.text('Zeta Cafe'));
    expect(
      alphaRect.top < zetaRect.top,
      isTrue,
      reason: 'Alpha Cafe should render before Zeta Cafe',
    );
  });

  testWidgets('canMutate=true exposes add-child + move buttons', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      wrap(
        OrgUnitTreeView(
          orgUnits: orgUnits,
          locations: locations,
          canMutate: true,
          onAddChildOrgUnit: (_) {},
          onMoveLocation: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_org_unit_add_child_root')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_location_card_move_loc-alpha')),
      findsOneWidget,
    );
  });

  testWidgets('canMutate=false hides add-child + move buttons but keeps '
      'expand/collapse', (tester) async {
    await sizeViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      wrap(
        const OrgUnitTreeView(
          orgUnits: orgUnits,
          locations: locations,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_org_unit_add_child_root')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operator_web_location_card_move_loc-alpha')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operator_web_org_unit_toggle_root')),
      findsOneWidget,
    );
  });

  testWidgets('collapsing a node hides its children', (tester) async {
    await sizeViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      wrap(
        const OrgUnitTreeView(
          orgUnits: orgUnits,
          locations: locations,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('North Region'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('operator_web_org_unit_toggle_root')),
    );
    await tester.pumpAndSettle();
    expect(find.text('North Region'), findsNothing);
    expect(find.text('Alpha Cafe'), findsNothing);
  });
}
