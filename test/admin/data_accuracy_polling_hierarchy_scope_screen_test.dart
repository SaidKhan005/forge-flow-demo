import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';
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

  InMemoryAdminBusinessTimingResolutionGateway timingGateway({
    String operatorId = 'op-1',
    String locationId = 'loc-1a',
  }) {
    return InMemoryAdminBusinessTimingResolutionGateway(
      seed: <String, AdminBusinessTimingResolution>{
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          operatorId,
          locationId,
        ): AdminBusinessTimingResolution(
          operatorId: operatorId,
          locationId: locationId,
          businessDate: '2026-05-24',
          ianaTimezone: 'America/Toronto',
          candidates: const <AdminResolutionCandidate>[
            AdminResolutionCandidate(
              profileId: 'timing-op-1',
              scopeType: 'operator_default',
              scopeId: 'op-1',
              scopeLabel: 'Demo Diner Co.',
              scopeDepthRank: 0,
              ianaTimezone: 'America/Toronto',
              effectiveAtBusinessDate: '2026-01-01',
              weekStartDay: 'monday',
              businessDayStartLocal: '04:00',
              servicePeriods: <AdminResolutionServicePeriod>[
                AdminResolutionServicePeriod(
                  key: 'lunch',
                  label: 'Lunch',
                  shortLabel: 'Lunch',
                  startLocal: '11:00',
                  endLocal: '15:00',
                  rollsPastMidnight: false,
                  sortOrder: 0,
                  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                ),
                AdminResolutionServicePeriod(
                  key: 'dinner',
                  label: 'Dinner',
                  shortLabel: 'Dinner',
                  startLocal: '17:00',
                  endLocal: '22:00',
                  rollsPastMidnight: false,
                  sortOrder: 1,
                  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                ),
              ],
            ),
          ],
        ),
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
    'Covers and Wage Data Accuracy business scope waits for the left picker',
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
            timingResolutionGateway: timingGateway(),
            vendorApplicabilityGateway:
                const _EmptyVendorApplicabilityAdminGateway(),
          ),
          hierarchyScope: businessScope,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_data_accuracy_waiting_for_location_scope')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_data_accuracy_table')), findsNothing);
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
    'Data Accuracy location scope renders the Operator Web surface only',
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
            timingResolutionGateway: timingGateway(),
            vendorApplicabilityGateway:
                const _EmptyVendorApplicabilityAdminGateway(),
            initialHierarchyScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
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
      expect(find.byKey(const Key('admin_data_accuracy_table')), findsNothing);
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
      expect(find.text('Effective: Org unit scope'), findsNothing);
      expect(find.text('Assignments'), findsOneWidget);
      expect(find.text('2 locations in North Region'), findsOneWidget);
      expect(find.text('Assign shown locations'), findsOneWidget);
      expect(find.textContaining('Apply one polling setup'), findsNothing);
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
    expect(find.text('2 locations in North Region'), findsOneWidget);
    expect(find.text('Assign shown locations'), findsOneWidget);
    expect(find.textContaining('covered 2 locations'), findsNothing);
  });

  testWidgets('Polling Setup tier filter narrows assignment rows', (
    tester,
  ) async {
    useWideViewport(tester);
    final now = DateTime.utc(2026, 5, 26, 12);
    final adminGateway = InMemoryDataAccuracyAdminGateway(
      operatorLocations: refs,
      initialTierDefinitions: <PollingTierKey, TierDefinition>{
        PollingTierKey.standard: kDemoStandardTierDefinition(),
        PollingTierKey.premium: kDemoPremiumTierDefinition(),
        PollingTierKey.custom: kDemoCustomTierDefinition(),
      },
      initialAssignments: <String, ForgeFlowPollingTierAssignment>{
        'op-1/loc-1a': ForgeFlowPollingTierAssignment(
          assignmentId: 'assignment-standard',
          operatorId: 'op-1',
          locationId: 'loc-1a',
          tierKey: PollingTierKey.standard,
          pollingCadencePerVendorSeconds: const <String, int>{
            'quickbooks_time': 300,
          },
          effectiveAt: now,
          createdAt: now,
        ),
        'op-1/loc-1b': ForgeFlowPollingTierAssignment(
          assignmentId: 'assignment-premium',
          operatorId: 'op-1',
          locationId: 'loc-1b',
          tierKey: PollingTierKey.premium,
          pollingCadencePerVendorSeconds: const <String, int>{'humanity': 60},
          effectiveAt: now,
          createdAt: now,
        ),
      },
    );

    await tester.pumpWidget(
      wrap(
        PollingAndPricingAdminScreen(
          gateway: adminGateway,
          actorUserId: 'demo-super-admin',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Toronto Yorkville'), findsOneWidget);
    expect(find.text('Vancouver Robson'), findsOneWidget);
    expect(find.text('Brooklyn Williamsburg'), findsOneWidget);

    final tierDropdown = find.byKey(const Key('admin_tier_filter_dropdown'));
    await tester.ensureVisible(tierDropdown);
    await tester.pumpAndSettle();
    await tester.tap(tierDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Premium').last);
    await tester.pumpAndSettle();

    expect(find.text('Toronto Yorkville'), findsNothing);
    expect(find.text('Vancouver Robson'), findsOneWidget);
    expect(find.text('Brooklyn Williamsburg'), findsNothing);
    expect(find.text('1 location'), findsWidgets);
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
      expect(find.text('Assign shown locations'), findsOneWidget);
      expect(find.textContaining('Apply one polling setup'), findsNothing);
      expect(find.textContaining('Selected scope:'), findsNothing);
      await tester.ensureVisible(scopeButton);
      await tester.tap(scopeButton);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('admin_tier_assignment_dialog')),
          matching: find.text('Assign polling setup'),
        ),
        findsOneWidget,
      );
      expect(find.text('Assign polling setup to North Region'), findsNothing);
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
      expect(find.text(r'Estimate: $60.00 per location.'), findsOneWidget);
      expect(find.textContaining('for 2 locations'), findsNothing);
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

    expect(find.text('Location only'), findsNothing);
    expect(find.text('Effective: Per-location tier assignment'), findsNothing);
    expect(find.text('Assignments'), findsOneWidget);
    expect(find.text('1 location in Toronto Yorkville'), findsOneWidget);
    expect(find.text('Assign shown location'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1a')),
      findsNothing,
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

  // Data Accuracy no longer hosts an in-screen inheritance notice, scope
  // banner, pick-location panel, or table. The AdminSetupWorkspace scope tree
  // owns scope selection; the Data Accuracy tab mounts Operator Web only after
  // a location is selected. The Polling tile keeps the inheritance notice, so
  // the shared single-location fixtures below stay in use.
  testWidgets('Data Accuracy business scope waits for a selected location '
      '(single covered location)', (tester) async {
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
          timingResolutionGateway: timingGateway(
            operatorId: 'op-solo',
            locationId: 'loc-solo-a',
          ),
          vendorApplicabilityGateway:
              const _EmptyVendorApplicabilityAdminGateway(),
          initialHierarchyScope: businessScope,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_data_accuracy_waiting_for_location_scope')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_data_accuracy_scope_inheritance_notice')),
      findsNothing,
    );
  });

  testWidgets('Data Accuracy org-unit scope waits for a selected location '
      '(single covered location)', (tester) async {
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
          timingResolutionGateway: timingGateway(),
          vendorApplicabilityGateway:
              const _EmptyVendorApplicabilityAdminGateway(),
          initialHierarchyScope: orgScope,
          scopeLocationIds: const <String>{'loc-1a'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_data_accuracy_waiting_for_location_scope')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('data_accuracy_covers_source_card')),
      findsNothing,
    );
  });

  testWidgets(
    'Data Accuracy multi-covered scope waits for a selected location, no '
    'inheritance notice',
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
            timingResolutionGateway: timingGateway(),
            vendorApplicabilityGateway:
                const _EmptyVendorApplicabilityAdminGateway(),
            initialHierarchyScope: businessScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_data_accuracy_waiting_for_location_scope')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_scope_inheritance_notice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Data Accuracy location scope renders Operator Web, no inheritance notice',
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
            timingResolutionGateway: timingGateway(),
            vendorApplicabilityGateway:
                const _EmptyVendorApplicabilityAdminGateway(),
            initialHierarchyScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
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

class _EmptyVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  const _EmptyVendorApplicabilityAdminGateway();

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    return const <VendorApplicabilityAdminRow>[];
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) {
    throw UnsupportedError('not used by Data Accuracy polling tests');
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) {
    throw UnsupportedError('not used by Data Accuracy polling tests');
  }
}
