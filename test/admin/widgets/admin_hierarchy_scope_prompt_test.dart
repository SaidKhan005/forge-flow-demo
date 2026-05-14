import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/widgets/admin_hierarchy_scope_prompt.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // Wave 2 H-3: prompt is desktop-first. Default 800x600 viewport
  // truncates the hierarchy-map tree and pushes location rows below
  // the visible cut, so taps miss. Pump 1024x900 to keep every row
  // hit-testable in tests.
  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget wrap(Widget child) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Scaffold(body: SingleChildScrollView(child: Center(child: child))),
    );
  }

  const businessScope = AdminHierarchyScopeIntent.business(
    operatorId: 'op-1',
    operatorName: 'Demo Diner Co.',
    valueState: AdminHierarchyScopeValueState.setAtScope,
    effectiveValueLabel: 'Business default',
    allowedActionsLabel: 'Can edit',
  );
  const orgUnitScope = AdminHierarchyScopeIntent.orgUnit(
    operatorId: 'op-1',
    orgUnitId: 'ou-north',
    operatorName: 'Demo Diner Co.',
    orgUnitName: 'North Region',
    valueState: AdminHierarchyScopeValueState.inheritedFromBusiness,
    inheritedFromLabel: 'business',
    effectiveValueLabel: 'Business default',
    allowedActionsLabel: 'Read only',
  );
  const locationScope = AdminHierarchyScopeIntent.location(
    operatorId: 'op-1',
    orgUnitId: 'ou-north',
    locationId: 'loc-yorkville',
    operatorName: 'Demo Diner Co.',
    orgUnitName: 'North Region',
    locationName: 'Yorkville',
    valueState: AdminHierarchyScopeValueState.locationOnly,
    effectiveValueLabel: 'Location override',
    allowedActionsLabel: 'Can edit',
  );

  testWidgets('renders required scope labels and effective states', (
    tester,
  ) async {
    await sizeViewport(tester);
    AdminHierarchyScopeIntent? selected;

    await tester.pumpWidget(
      wrap(
        AdminHierarchyScopePrompt(
          surfaceName: 'Timing',
          selectedScope: businessScope,
          scopes: const <AdminHierarchyScopeIntent>[
            businessScope,
            orgUnitScope,
            locationScope,
          ],
          onScopeSelected: (scope) => selected = scope,
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin_hierarchy_scope_prompt')),
      findsOneWidget,
    );
    expect(find.text('Choose scope for Timing'), findsOneWidget);
    expect(find.text('Business'), findsOneWidget);
    expect(find.text('Org unit'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.text('Set at this scope'), findsOneWidget);
    expect(find.text('Inherited from business'), findsOneWidget);
    expect(find.text('Location only'), findsOneWidget);
    expect(find.text('Effective: Business default'), findsWidgets);
    expect(find.text('Effective: Location override'), findsOneWidget);
    expect(find.text('Can edit'), findsWidgets);
    expect(find.text('Read only'), findsOneWidget);

    // Wave 2 H-3: the prompt renders the hierarchy-map tree inside a
    // scrollable popover body, so the location row may sit below the
    // visible cut on the default test viewport. Scroll the row into
    // view before tapping so the hit-test lands on the InkWell.
    await tester.ensureVisible(
      find.byKey(Key('admin_hierarchy_scope_option_${locationScope.cacheKey}')),
    );
    await tester.tap(
      find.byKey(Key('admin_hierarchy_scope_option_${locationScope.cacheKey}')),
    );
    await tester.pumpAndSettle();

    expect(selected, locationScope);
  });

  testWidgets('banner exposes selected scope and change action', (
    tester,
  ) async {
    await sizeViewport(tester);
    var changed = false;
    var cleared = false;

    await tester.pumpWidget(
      wrap(
        AdminHierarchyScopeBanner(
          scope: orgUnitScope,
          surfaceName: 'data accuracy',
          onChangeScope: () => changed = true,
          onClear: () => cleared = true,
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin_hierarchy_scope_banner')),
      findsOneWidget,
    );
    expect(
      find.text('Showing data accuracy for org unit scope'),
      findsOneWidget,
    );
    expect(find.text('Demo Diner Co. / North Region'), findsOneWidget);
    expect(find.text('Inherited from business'), findsOneWidget);
    expect(find.text('Effective: Business default'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin_hierarchy_scope_change')));
    await tester.pumpAndSettle();
    expect(changed, isTrue);

    await tester.tap(find.byKey(const Key('admin_hierarchy_scope_clear')));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
  });
}
