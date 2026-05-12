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
    'Covers and Wage Data Accuracy business scope exposes selected-scope edit',
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
        find.text('Showing covers and wage data accuracy for business scope'),
        findsOneWidget,
      );
      expect(find.text('Set at this scope'), findsOneWidget);
      expect(find.text('Effective: Business scope'), findsOneWidget);
      expect(find.text('Edit selected scope'), findsWidgets);
      expect(
        find.textContaining('saves one scoped covers and wage override'),
        findsOneWidget,
      );
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
      expect(find.text('Brooklyn Williamsburg'), findsNothing);
      expect(
        find.byKey(const Key('admin_data_accuracy_scope_override')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_edit_op-1_loc-1a')),
        findsNothing,
      );
      expect(find.text('Visible locations'), findsNothing);
      expect(find.text('Manual covers'), findsNothing);
      expect(find.text('Forecast covers'), findsNothing);
    },
  );

  testWidgets('Covers and Wage scope edit writes selected hierarchy scope', (
    tester,
  ) async {
    useWideViewport(tester);
    const businessScope = AdminHierarchyScopeIntent.business(
      operatorId: 'op-1',
      operatorName: 'Demo Diner Co.',
    );
    final adminGateway = gateway();

    await tester.pumpWidget(
      wrap(
        PerLocationDataAccuracyScreen(
          gateway: adminGateway,
          actorUserId: 'demo-super-admin',
          initialHierarchyScope: businessScope,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scopeButton = find.byKey(
      const Key('admin_data_accuracy_scope_override'),
    );
    expect(scopeButton, findsOneWidget);
    await tester.ensureVisible(scopeButton);
    await tester.tap(scopeButton);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_data_accuracy_lunch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual entry').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_data_accuracy_reason_note')),
      'Business scope lunch override',
    );
    await tester.tap(
      find.byKey(const Key('admin_data_accuracy_override_submit')),
    );
    await tester.pumpAndSettle();

    final events = adminGateway.capturedAuditEvents
        .where(
          (event) => event.eventType == 'admin.data_accuracy.scope_override',
        )
        .toList();
    expect(events, hasLength(1));
    expect(events.single.locationId, isNull);
    expect(events.single.diff['scope_type'], equals('business'));
    expect(events.single.diff['affected_location_count'], equals(2));
  });

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

  testWidgets(
    'Polling Setup org-unit scope exposes selected-scope assignment',
    (tester) async {
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
            scopeLocationIds: const <String>{'loc-1a', 'loc-1b'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Showing polling setup for org unit scope'),
        findsOneWidget,
      );
      expect(find.text('Effective: Org unit scope'), findsOneWidget);
      expect(find.text('Assign selected scope'), findsWidgets);
      expect(
        find.textContaining('saves one scoped polling setup override'),
        findsOneWidget,
      );
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_polling_setup_scope_assign')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1a')),
        findsNothing,
      );
      expect(find.text('Visible locations'), findsNothing);
      expect(find.text('Assigned tiers'), findsNothing);
      expect(find.text('Open requests'), findsNothing);
    },
  );

  testWidgets(
    'Polling Setup scope assignment writes selected hierarchy scope',
    (tester) async {
      useWideViewport(tester);
      const orgScope = AdminHierarchyScopeIntent.orgUnit(
        operatorId: 'op-1',
        orgUnitId: 'ou-north',
        operatorName: 'Demo Diner Co.',
        orgUnitName: 'North Region',
      );
      final adminGateway = gateway();

      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: adminGateway,
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: orgScope,
            scopeLocationIds: const <String>{'loc-1a', 'loc-1b'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scopeButton = find.byKey(
        const Key('admin_polling_setup_scope_assign'),
      );
      expect(scopeButton, findsOneWidget);
      await tester.ensureVisible(scopeButton);
      await tester.tap(scopeButton);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_tier_assignment_dialog_tier')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Premium').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_polling_calculator_calls_per_day')),
        '100',
      );
      await tester.enterText(
        find.byKey(const Key('admin_polling_calculator_cost_per_call')),
        '0.02',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('admin_polling_calculator_use_estimate')),
      );
      await tester.pump();
      expect(find.widgetWithText(TextField, '60.00'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('admin_tier_assignment_dialog_reason')),
        'Org-unit polling upgrade',
      );
      await tester.tap(
        find.byKey(const Key('admin_tier_assignment_dialog_submit')),
      );
      await tester.pumpAndSettle();

      final events = adminGateway.capturedAuditEvents
          .where(
            (event) =>
                event.eventType == 'admin.polling_tier_assignment.scope_assign',
          )
          .toList();
      expect(events, hasLength(1));
      expect(events.single.locationId, isNull);
      expect(events.single.diff['scope_type'], equals('org_unit'));
      expect(events.single.diff['org_unit_id'], equals('ou-north'));
      expect(events.single.diff['affected_location_count'], equals(2));
      expect(
        events.single.diff['vendor_api_cost_estimate_cents_monthly'],
        6000,
      );
    },
  );

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

  // ---------------------------------------------------------------------------
  // B1.a — Inheritance notice propagation to Data Accuracy + Polling tiles.
  //
  // Mirrors PR #485's `admin_timing_scope_inheritance_notice` widget at
  // `lib/admin/screens/admin_timing_setup_screen.dart:164-182`. When the
  // selected scope is business or org_unit AND covers exactly one location,
  // both tiles render an inheritance notice warning the F&F admin that the
  // displayed value is effectively a single-location pull (HP #11 —
  // hierarchy honesty). Slice B1.a in
  // `docs/_execution/lane_b_features/03_execution_slices.md`.

  const singleLocationRefs = <OperatorLocationRef>[
    OperatorLocationRef(
      operatorId: 'op-solo',
      businessName: 'Solo Diner LLC',
      locationId: 'loc-solo-a',
      locationName: 'Calgary Kensington',
    ),
  ];

  InMemoryDataAccuracyAdminGateway singleLocationGateway() {
    return InMemoryDataAccuracyAdminGateway(
      operatorLocations: singleLocationRefs,
      initialTierDefinitions: <PollingTierKey, TierDefinition>{
        PollingTierKey.standard: kDemoStandardTierDefinition(),
        PollingTierKey.premium: kDemoPremiumTierDefinition(),
        PollingTierKey.custom: kDemoCustomTierDefinition(),
      },
    );
  }

  testWidgets(
    'Data Accuracy business scope with single covered location shows inheritance notice',
    (tester) async {
      useWideViewport(tester);
      const businessScope = AdminHierarchyScopeIntent.business(
        operatorId: 'op-solo',
        operatorName: 'Solo Diner LLC',
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: singleLocationGateway(),
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: businessScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('admin_data_accuracy_scope_inheritance_notice'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This scope only covers Calgary Kensington',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Data Accuracy org-unit scope with single covered location shows inheritance notice',
    (tester) async {
      useWideViewport(tester);
      const orgScope = AdminHierarchyScopeIntent.orgUnit(
        operatorId: 'op-1',
        orgUnitId: 'ou-yorkville-only',
        operatorName: 'Demo Diner Co.',
        orgUnitName: 'Yorkville Region',
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway(),
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: orgScope,
            scopeLocationIds: const <String>{'loc-1a'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('admin_data_accuracy_scope_inheritance_notice'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This scope only covers Toronto Yorkville',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Data Accuracy multi-covered scope suppresses inheritance notice',
    (tester) async {
      useWideViewport(tester);
      const businessScope = AdminHierarchyScopeIntent.business(
        operatorId: 'op-1',
        operatorName: 'Demo Diner Co.',
      );

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway(),
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: businessScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('admin_data_accuracy_scope_inheritance_notice'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Data Accuracy location scope suppresses inheritance notice',
    (tester) async {
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

      expect(
        find.byKey(
          const Key('admin_data_accuracy_scope_inheritance_notice'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Polling business scope with single covered location shows inheritance notice',
    (tester) async {
      useWideViewport(tester);
      const businessScope = AdminHierarchyScopeIntent.business(
        operatorId: 'op-solo',
        operatorName: 'Solo Diner LLC',
      );

      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: singleLocationGateway(),
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: businessScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_polling_scope_inheritance_notice')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This scope only covers Calgary Kensington',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Polling org-unit scope with single covered location shows inheritance notice',
    (tester) async {
      useWideViewport(tester);
      const orgScope = AdminHierarchyScopeIntent.orgUnit(
        operatorId: 'op-1',
        orgUnitId: 'ou-yorkville-only',
        operatorName: 'Demo Diner Co.',
        orgUnitName: 'Yorkville Region',
      );

      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: gateway(),
            actorUserId: 'demo-super-admin',
            initialHierarchyScope: orgScope,
            scopeLocationIds: const <String>{'loc-1a'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_polling_scope_inheritance_notice')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This scope only covers Toronto Yorkville',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Polling multi-covered scope suppresses inheritance notice',
    (tester) async {
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
            scopeLocationIds: const <String>{'loc-1a', 'loc-1b'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_polling_scope_inheritance_notice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Polling location scope suppresses inheritance notice',
    (tester) async {
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

      expect(
        find.byKey(const Key('admin_polling_scope_inheritance_notice')),
        findsNothing,
      );
    },
  );
}
