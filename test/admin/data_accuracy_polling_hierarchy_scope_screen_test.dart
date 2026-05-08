import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const refs = <OperatorLocationRef>[
    OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1a',
      locationName: 'Toronto Yorkville',
    ),
    OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1b',
      locationName: 'Vancouver Robson',
    ),
    OperatorLocationRef(
      operatorId: 'op-2',
      businessName: 'Sunset Cafe Group',
      locationId: 'loc-2a',
      locationName: 'Brooklyn Williamsburg',
    ),
  ];

  Widget wrap(Widget child, {AdminHierarchyScopeIntent? hierarchyScope}) {
    final scopedChild = hierarchyScope == null
        ? child
        : AdminRouteHandoff(
            selectedRouteId: 'data-accuracy',
            hierarchyScope: hierarchyScope,
            onSelectRoute: (_) {},
            child: child,
          );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Scaffold(body: scopedChild),
    );
  }

  InMemoryDataAccuracyAdminGateway gateway() {
    return InMemoryDataAccuracyAdminGateway(
      operatorLocations: refs,
      initialTierDefinitions: <PollingTierKey, TierDefinition>{
        PollingTierKey.standard: kDemoStandardTierDefinition(),
        PollingTierKey.premium: kDemoPremiumTierDefinition(),
        PollingTierKey.custom: kDemoCustomTierDefinition(),
      },
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets(
    'Data Accuracy business scope is a read-only rollup from handoff',
    (tester) async {
      useWideViewport(tester);
      const businessScope = AdminHierarchyScopeIntent.business(
        operatorId: 'op-1',
        operatorName: 'Demo Diner Co.',
        allowedActionsLabel: 'Editable',
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway(),
            actorUserId: 'demo-super-admin',
          ),
          hierarchyScope: businessScope,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_hierarchy_scope_banner')),
        findsOneWidget,
      );
      expect(
        find.text('Showing data accuracy for business scope'),
        findsOneWidget,
      );
      expect(find.text('Overridden at location scope'), findsOneWidget);
      expect(find.text('Effective: Location rollup'), findsOneWidget);
      expect(find.text('Select a location to edit'), findsWidgets);
      expect(
        find.textContaining('Business scope is a read-only rollup'),
        findsOneWidget,
      );
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
      expect(find.text('Brooklyn Williamsburg'), findsNothing);
      expect(
        find.byKey(const Key('admin_data_accuracy_edit_op-1_loc-1a')),
        findsNothing,
      );
    },
  );

  testWidgets('Data Accuracy location scope keeps location edit behavior', (
    tester,
  ) async {
    useWideViewport(tester);
    const locationScope = AdminHierarchyScopeIntent.location(
      operatorId: 'op-1',
      locationId: 'loc-1a',
      operatorName: 'Demo Diner Co.',
      locationName: 'Toronto Yorkville',
    );

    await tester.pumpWidget(
      wrap(
        PerLocationDataAccuracyScreen(
          gateway: gateway(),
          actorUserId: 'demo-super-admin',
          initialHierarchyScope: locationScope,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location only'), findsOneWidget);
    expect(find.text('Effective: Per-location overrides'), findsOneWidget);
    expect(find.text('Location controls'), findsOneWidget);
    expect(find.byKey(const Key('admin_hierarchy_scope_notice')), findsNothing);
    expect(
      find.byKey(const Key('admin_data_accuracy_edit_op-1_loc-1a')),
      findsOneWidget,
    );
    expect(find.text('Vancouver Robson'), findsNothing);
  });

  testWidgets('Polling and pricing org-unit scope requires a location', (
    tester,
  ) async {
    useWideViewport(tester);
    const orgScope = AdminHierarchyScopeIntent.orgUnit(
      operatorId: 'op-1',
      orgUnitId: 'ou-north',
      operatorName: 'Demo Diner Co.',
      orgUnitName: 'North Region',
    );

    await tester.pumpWidget(
      wrap(
        PollingAndPricingAdminScreen(
          gateway: gateway(),
          actorUserId: 'demo-super-admin',
          initialHierarchyScope: orgScope,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Showing polling and pricing for org unit scope'),
      findsOneWidget,
    );
    expect(find.text('Effective: Scoped resolver pending'), findsOneWidget);
    expect(find.text('Location required to assign'), findsWidgets);
    expect(
      find.textContaining(
        'Org-unit polling and pricing assignment is disabled',
      ),
      findsOneWidget,
    );
    expect(find.text('No tier assignments match this view.'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1a')),
      findsNothing,
    );
  });

  testWidgets('Polling and pricing location scope keeps assignment action', (
    tester,
  ) async {
    useWideViewport(tester);
    const locationScope = AdminHierarchyScopeIntent.location(
      operatorId: 'op-1',
      locationId: 'loc-1a',
      operatorName: 'Demo Diner Co.',
      locationName: 'Toronto Yorkville',
    );

    await tester.pumpWidget(
      wrap(
        PollingAndPricingAdminScreen(
          gateway: gateway(),
          actorUserId: 'demo-super-admin',
          initialHierarchyScope: locationScope,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location only'), findsOneWidget);
    expect(
      find.text('Effective: Per-location tier assignment'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1a')),
      findsOneWidget,
    );
    expect(find.text('Vancouver Robson'), findsNothing);
  });
}
