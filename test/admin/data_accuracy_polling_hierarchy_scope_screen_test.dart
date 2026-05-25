import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
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
    'Covers and Wage Data Accuracy business scope shows pick-a-location for '
    'the primary surface but still lists scoped rows in the table',
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

      // Web-style replica parity: data accuracy is per-location, so a
      // business scope shows the friendly "pick a location" surface for the
      // PRIMARY section instead of the web source controls.
      expect(
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_primary_section')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('data_accuracy_wage_source_card')),
        findsNothing,
      );

      // SECONDARY admin extras still render: the table lists the scoped
      // operator-1 locations (and excludes operator-2's location).
      expect(
        find.byKey(const Key('admin_data_accuracy_table')),
        findsOneWidget,
      );
      expect(find.text('Toronto Yorkville'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
      expect(find.text('Brooklyn Williamsburg'), findsNothing);
    },
  );

  test(
    'gateway accepts keyed covers maps for business, org-unit, and location scopes',
    () async {
      final adminGateway = gateway();

      await adminGateway.overrideDataAccuracyScope(
        operatorId: 'op-1',
        scopeType: AdminDataAccuracyMutationScopeType.business,
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'breakfast': CoversSource.manual,
        },
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'Business breakfast source',
      );
      await adminGateway.overrideDataAccuracyScope(
        operatorId: 'op-1',
        scopeType: AdminDataAccuracyMutationScopeType.orgUnit,
        orgUnitId: 'ou-north',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'breakfast': CoversSource.forecast,
        },
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'Org breakfast source',
      );
      await adminGateway.overrideDataAccuracyScope(
        operatorId: 'op-1',
        scopeType: AdminDataAccuracyMutationScopeType.location,
        locationId: 'loc-1a',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'breakfast': CoversSource.manual,
        },
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'Location breakfast source',
      );

      final events = adminGateway.capturedAuditEvents
          .where(
            (event) => event.eventType == 'admin.data_accuracy.scope_override',
          )
          .toList(growable: false);
      expect(events, hasLength(3));
      expect(events[0].diff['scope_type'], equals('business'));
      expect(events[1].diff['scope_type'], equals('org_unit'));
      expect(events[1].diff['org_unit_id'], equals('ou-north'));
      expect(events[2].diff['scope_type'], equals('location'));
      expect(events[2].locationId, equals('loc-1a'));
      for (final event in events) {
        expect(
          event.diff['covers_source_per_service_period'],
          isA<Map<String, String>>().having(
            (map) => map.keys,
            'keys',
            contains('breakfast'),
          ),
        );
      }
    },
  );

  testWidgets(
    'Data Accuracy location scope renders the web-style primary controls '
    'and keeps the secondary table edit behavior',
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

      // PRIMARY web-style source controls render for the selected location.
      expect(
        find.byKey(const Key('admin_data_accuracy_primary_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_wage_source_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsNothing,
      );

      // SECONDARY admin table still offers the per-location override edit.
      expect(
        find.byKey(const Key('admin_data_accuracy_edit_op-1_loc-1a')),
        findsOneWidget,
      );
      expect(find.text('Vancouver Robson'), findsNothing);
    },
  );

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
        findsNothing,
      );
      expect(find.text('Effective: Org unit scope'), findsOneWidget);
      expect(find.text('Assign'), findsWidgets);
      expect(
        find.textContaining('saves one polling setup override'),
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

  testWidgets('Polling Setup scope assignment count ignores visible filters', (
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
          scopeLocationIds: const <String>{'loc-1a', 'loc-1b'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_operator_name_field')),
      'Toronto',
    );
    await tester.pumpAndSettle();

    expect(find.text('Toronto Yorkville'), findsOneWidget);
    expect(find.text('Vancouver Robson'), findsNothing);
    expect(find.text('1 location'), findsOneWidget);
    expect(find.textContaining('covered 2 locations inherit'), findsOneWidget);
  });

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
  // `docs/archive/_execution/lane_b_features/03_execution_slices.md`.

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

  // Web-style replica parity: the data-accuracy screen no longer hosts the
  // in-screen inheritance notice / scope banner (the AdminSetupWorkspace
  // scope-tree pane owns scope selection now). At a business / org-unit
  // scope the PRIMARY surface shows the friendly pick-a-location panel
  // because data accuracy is per-location, exactly like operator-web. The
  // Polling tile keeps the inheritance notice (its screen is unchanged), so
  // the shared single-location fixtures below stay in use.
  testWidgets(
    'Data Accuracy business scope shows pick-a-location for the primary '
    'surface (single covered location)',
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
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_scope_inheritance_notice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Data Accuracy org-unit scope shows pick-a-location for the primary '
    'surface (single covered location)',
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
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Data Accuracy multi-covered scope shows pick-a-location, no inheritance '
    'notice',
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
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_scope_inheritance_notice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Data Accuracy location scope renders the primary surface, no inheritance '
    'notice',
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
        find.byKey(const Key('admin_data_accuracy_primary_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_scope_inheritance_notice')),
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
        find.textContaining('Only Calgary Kensington is included here'),
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
        find.textContaining('Only Toronto Yorkville is included here'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Polling multi-covered scope suppresses inheritance notice', (
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
          scopeLocationIds: const <String>{'loc-1a', 'loc-1b'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_polling_scope_inheritance_notice')),
      findsNothing,
    );
  });

  testWidgets('Polling location scope suppresses inheritance notice', (
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

    expect(
      find.byKey(const Key('admin_polling_scope_inheritance_notice')),
      findsNothing,
    );
  });
}
