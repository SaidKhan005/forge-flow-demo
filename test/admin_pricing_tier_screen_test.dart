// Plans & Limits V1 (Phase 1) — admin Plans & limits screen widget
// tests.
//
// Drives the rebuilt screen against an
// `InMemoryPricingTierAdminGateway` (+ an
// `InMemoryObservabilityAdminGateway` for the read-only spend / margin
// / cap-breach figures) so the click path runs end-to-end without a
// backend. The screen opens on the read-only "Plans" tab; the
// master/detail business list lives behind the "Businesses" tab, so
// most tests switch to it first via [openBusinessesTab]. Coverage:
//
//   * Plans tab renders the laddered six-plan map (read-only).
//   * Businesses tab lists every seeded operator with a margin % and
//     spend joined from observability.
//   * Empty state renders when no operators are seeded.
//   * Apply-template flow seeds Premium cap rows.
//   * Inline edit flow rewrites a usage cap (use case is a dropdown).
//   * Spend-vs-cap bar joins observability cost telemetry to a cap.
//   * Read-only mode (`editingEnabled: false`) hides every mutate
//     affordance — exercised by the `ff_support` walkthrough.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/pricing_tier_admin_models.dart';
import 'package:forge_and_flow/admin/screens/pricing_tier_admin_screen.dart';
import 'package:forge_and_flow/admin/services/observability_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/pricing_tier_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const demoWorkspaceOperatorId = '00000000-0000-4000-8000-000000000001';

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  Future<void> openBusinessesTab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('admin_pricing_tab_businesses')));
    await tester.pumpAndSettle();
  }

  ObservabilityAdminGateway observabilityFor(
    String operatorId, {
    double revenueUsd = 250.0,
    double costUsd = 40.0,
    List<Map<String, Object?>> costTelemetry = const <Map<String, Object?>>[],
    List<Map<String, Object?>> capEvents = const <Map<String, Object?>>[],
  }) {
    return InMemoryObservabilityAdminGateway(
      envelope: <String, Object?>{
        'as_of': '2026-05-03T12:00:00.000Z',
        'contract': 'admin_observability.v1',
        'schema_version': 1,
        'cost_telemetry': costTelemetry,
        'margins': <Map<String, Object?>>[
          <String, Object?>{
            'operator_id': operatorId,
            'business_name': 'Seed Cafe',
            'subscription_tier': 'starter',
            'revenue_usd': revenueUsd,
            'cost_usd': costUsd,
          },
        ],
        'cap_events': capEvents,
      },
    );
  }

  Future<void> chooseWorkspaceBusinessScope(WidgetTester tester) async {
    final option = find.byKey(
      const Key('admin_setup_scope_business_$demoWorkspaceOperatorId'),
    );
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    if (find
        .byKey(const Key('admin_setup_workspace_tabs'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.widgetWithText(Tab, 'Plans and limits'));
      await tester.pumpAndSettle();
    }
    // The rebuilt screen opens on the read-only Plans tab; the
    // business master/detail (and its edit affordances) live behind
    // the Businesses tab.
    if (find
        .byKey(const Key('admin_pricing_tab_businesses'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const Key('admin_pricing_tab_businesses')));
      await tester.pumpAndSettle();
    }
  }

  PricingOperatorBundle seedBundle({
    String operatorId = 'op-seed-1',
    String businessName = 'Seed Cafe',
    String tier = 'starter',
    String? primaryLocationId = 'loc-seed-1',
    List<UsageCapRow> caps = const <UsageCapRow>[],
  }) {
    return PricingOperatorBundle(
      operatorId: operatorId,
      businessName: businessName,
      subscriptionTier: tier,
      preferredCurrency: 'CAD',
      primaryLocationId: primaryLocationId,
      suspended: false,
      caps: caps,
    );
  }

  UsageCapRow seedCap({
    String operatorId = 'op-seed-1',
    String locationId = 'loc-seed-1',
    String usageClass = 'advisor_qa',
    double monthly = 50.0,
    double perInvocation = 0.10,
  }) {
    final created = DateTime.utc(2026, 4, 1);
    return UsageCapRow(
      capId: 'cap-${operatorId}_$usageClass',
      operatorId: operatorId,
      locationId: locationId,
      usageClass: usageClass,
      monthlyCapUsd: monthly,
      perInvocationCapUsd: perInvocation,
      staffId: null,
      workflowId: null,
      createdBy: 'seed-actor',
      updatedBy: 'seed-actor',
      createdAt: created,
      updatedAt: created,
    );
  }

  testWidgets('Businesses tab lists one row per seeded operator', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(
          operatorId: 'op-2',
          businessName: 'Beta Bistro',
          caps: <UsageCapRow>[seedCap(operatorId: 'op-2', locationId: 'loc-2')],
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          observabilityGateway: observabilityFor('op-2'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_screen')), findsOneWidget);
    // Opens on the read-only Plans tab.
    expect(find.byKey(const Key('admin_pricing_plans_view')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_pricing_plan_card_starter')),
      findsOneWidget,
    );

    await openBusinessesTab(tester);
    expect(find.byKey(const Key('admin_pricing_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_pricing_row_op-2')), findsOneWidget);
    expect(find.text('Alpha Cafe'), findsWidgets);
    expect(find.text('Beta Bistro'), findsWidgets);
    expect(find.text('advisor_qa'), findsNothing);

    await tester.tap(find.byKey(const Key('admin_pricing_row_op-2')));
    await tester.pumpAndSettle();
    expect(find.text('Advisor answers'), findsOneWidget);
    expect(find.text('cap-op-2_advisor_qa'), findsNothing);

    final capDetails = find.byKey(
      const Key('admin_pricing_cap_details_cap-op-2_advisor_qa'),
    );
    await tester.ensureVisible(capDetails);
    await tester.pumpAndSettle();
    await tester.tap(capDetails);
    await tester.pumpAndSettle();
    expect(find.text('Use case ID'), findsOneWidget);
    expect(find.text('advisor_qa'), findsOneWidget);
    expect(find.text('cap-op-2_advisor_qa'), findsOneWidget);
  });

  testWidgets('Plans tab renders the laddered six-plan map (read-only)', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[seedBundle()],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_plans_view')), findsOneWidget);
    for (final key in const <String>[
      'pilot',
      'starter',
      'premium',
      'elite',
      'pro',
      'enterprise',
    ]) {
      expect(
        find.byKey(Key('admin_pricing_plan_card_$key')),
        findsOneWidget,
        reason: 'plan card for $key',
      );
    }
    // Plan map has no apply-template button and no add-limit button on
    // the Plans tab (those live in Businesses).
    expect(
      find.byKey(const Key('admin_pricing_template_premium_button')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_pricing_add_cap_button')),
      findsNothing,
    );
  });

  testWidgets(
    'Phase 3: Plans tab shows "Edit pricing" per card and saves a change',
    (tester) async {
      var counter = 0;
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            idempotencyKeyFactory: () => 'k-plan-${counter++}',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Every plan card carries an Edit pricing button when editing is on.
      final editPremium = find.byKey(
        const Key('admin_pricing_plan_edit_premium'),
      );
      expect(editPremium, findsOneWidget);

      await tester.ensureVisible(editPremium);
      await tester.tap(editPremium);
      await tester.pumpAndSettle();

      // The editor opens seeded with the current catalog values.
      expect(
        find.byKey(const Key('admin_pricing_plan_dialog')),
        findsOneWidget,
      );
      final monthlyField = find.byKey(
        const Key('admin_pricing_plan_monthly'),
      );
      expect(monthlyField, findsOneWidget);
      await tester.enterText(monthlyField, '275');
      await tester.tap(
        find.byKey(const Key('admin_pricing_plan_submit_button')),
      );
      await tester.pumpAndSettle();

      // Saved through the gateway: the catalog now holds the new price and
      // the card reflects it.
      final plans = await gateway.listPlanCatalog();
      expect(
        plans.firstWhere((p) => p.tierKey == 'premium').monthlyUsd,
        equals(275),
      );
    },
  );

  testWidgets('Phase 3: read-only mode hides the "Edit pricing" buttons', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(gateway: gateway, editingEnabled: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_plans_view')), findsOneWidget);
    // The cards still render, but with no edit affordance.
    expect(
      find.byKey(const Key('admin_pricing_plan_card_premium')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_pricing_plan_edit_premium')),
      findsNothing,
    );
  });

  testWidgets(
    'Phase 3: Plans tab falls back to hard-coded pricing when the catalog '
    'read fails',
    (tester) async {
      // A gateway whose listPlanCatalog throws stands in for the endpoint
      // not being deployed / an offline failure. The screen must still
      // paint all six plan cards from the hard-coded fallback.
      final gateway = _ThrowingCatalogGateway(
        seed: <PricingOperatorBundle>[seedBundle()],
      );
      await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_pricing_plans_view')),
        findsOneWidget,
      );
      for (final key in const <String>[
        'pilot',
        'starter',
        'premium',
        'elite',
        'pro',
        'enterprise',
      ]) {
        expect(
          find.byKey(Key('admin_pricing_plan_card_$key')),
          findsOneWidget,
          reason: 'fallback plan card for $key',
        );
      }
      // The fallback still wires the edit affordance (editing defaults on).
      expect(
        find.byKey(const Key('admin_pricing_plan_edit_premium')),
        findsOneWidget,
      );
    },
  );

  testWidgets('spend-vs-cap bar joins observability cost telemetry to a cap', (
    tester,
  ) async {
    final cap = seedCap(
      operatorId: 'op-spend',
      locationId: 'loc-spend',
      usageClass: 'advisor_qa',
      monthly: 200.0,
    );
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-spend',
          primaryLocationId: 'loc-spend',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    final observability = observabilityFor(
      'op-spend',
      revenueUsd: 250.0,
      costUsd: 50.0,
      costTelemetry: <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': 'op-spend',
          'location_id': 'loc-spend',
          'usage_class': 'advisor_qa',
          'query_class': 'advisor_qa',
          'total_usd': 50.0,
          'request_count': 100,
        },
      ],
    );
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          observabilityGateway: observability,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    // $50 spent against a $200 cap = 25%.
    expect(find.text('\$50 / \$200 this month'), findsOneWidget);
    expect(find.text('25%'), findsWidgets);
  });

  testWidgets('stacks master/detail panes on compact widths', (tester) async {
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cap = seedCap(
      operatorId: 'op-compact',
      usageClass: 'advisor_qa_with_long_suffix',
    );
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-compact',
          businessName: 'Very Long Compact Width Operator Name',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    expect(
      find.byKey(const Key('admin_pricing_operator_list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_pricing_detail_op-compact')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the empty state when no operators are seeded', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway();
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    expect(find.byKey(const Key('admin_pricing_empty')), findsOneWidget);
    expect(find.text('No operators on file'), findsOneWidget);
  });

  testWidgets('apply Premium template seeds advisor_qa cap row', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(operatorId: 'op-prem', tier: 'starter'),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final premiumButton = find.byKey(
      const Key('admin_pricing_template_premium_button'),
    );
    await tester.ensureVisible(premiumButton);
    await tester.pumpAndSettle();
    await tester.tap(premiumButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_pricing_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_pricing_confirm_ok')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.subscriptionTier, equals('premium'));
    expect(operators.single.caps, hasLength(1));
    expect(operators.single.caps.single.usageClass, equals('advisor_qa'));
    expect(operators.single.caps.single.monthlyCapUsd, equals(200.0));
  });

  testWidgets('inline edit rewrites the monthly cap', (tester) async {
    final cap = seedCap(operatorId: 'op-edit', locationId: 'loc-edit');
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-edit',
          primaryLocationId: 'loc-edit',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final editKey = Key('admin_pricing_cap_edit_${cap.capId}');
    await tester.ensureVisible(find.byKey(editKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(editKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_cap_dialog')), findsOneWidget);
    // Use case is a fixed dropdown when editing; only the cap amount
    // changes.
    await tester.enterText(
      find.byKey(const Key('admin_pricing_cap_monthly')),
      '125.00',
    );
    await tester.tap(find.byKey(const Key('admin_pricing_cap_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.caps.single.monthlyCapUsd, equals(125.0));
  });

  testWidgets('Phase 2: delete-limit confirm flow removes the cap', (
    tester,
  ) async {
    final cap = seedCap(operatorId: 'op-del', locationId: 'loc-del');
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-del',
          primaryLocationId: 'loc-del',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final deleteKey = Key('admin_pricing_cap_delete_${cap.capId}');
    await tester.ensureVisible(find.byKey(deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(deleteKey));
    await tester.pumpAndSettle();

    // The confirm dialog gates the destructive delete.
    expect(
      find.byKey(const Key('admin_pricing_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_pricing_confirm_ok')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.caps, isEmpty);
  });

  testWidgets('Phase 2: cancelling the delete confirm keeps the cap', (
    tester,
  ) async {
    final cap = seedCap(operatorId: 'op-keep', locationId: 'loc-keep');
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-keep',
          primaryLocationId: 'loc-keep',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final deleteKey = Key('admin_pricing_cap_delete_${cap.capId}');
    await tester.ensureVisible(find.byKey(deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_pricing_confirm_cancel')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.caps, hasLength(1));
  });

  testWidgets('Phase 2: read-only mode hides the delete affordance', (
    tester,
  ) async {
    final cap = seedCap(operatorId: 'op-ro-del');
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(
          operatorId: 'op-ro-del',
          primaryLocationId: 'loc-seed-1',
          caps: <UsageCapRow>[cap],
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(PricingTierAdminScreen(gateway: gateway, editingEnabled: false)),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    expect(
      find.byKey(Key('admin_pricing_cap_delete_${cap.capId}')),
      findsNothing,
    );
  });

  testWidgets('add limit uses a friendly use-case dropdown', (tester) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(operatorId: 'op-add', primaryLocationId: 'loc-add'),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final addButton = find.byKey(const Key('admin_pricing_add_cap_button'));
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_cap_dialog')), findsOneWidget);
    // The use-case field is a dropdown over the four known classes, shown
    // by their friendly labels (default selection is "Advisor answers").
    expect(
      find.byKey(const Key('admin_pricing_cap_usage_class')),
      findsOneWidget,
    );
    expect(find.text('Advisor answers'), findsWidgets);

    await tester.tap(find.byKey(const Key('admin_pricing_cap_usage_class')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coaching help').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_pricing_cap_monthly')),
      '300.00',
    );
    await tester.enterText(
      find.byKey(const Key('admin_pricing_cap_per_invocation')),
      '0.20',
    );
    await tester.tap(find.byKey(const Key('admin_pricing_cap_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.caps, hasLength(1));
    // The friendly label maps back to the raw class id on submit.
    expect(operators.single.caps.single.usageClass, equals('coach_qa'));
    expect(operators.single.caps.single.monthlyCapUsd, equals(300.0));
  });

  testWidgets(
    'editingEnabled: false hides templates, add, and edit affordances',
    (tester) async {
      final cap = seedCap(operatorId: 'op-readonly');
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(
            operatorId: 'op-readonly',
            primaryLocationId: 'loc-seed-1',
            caps: <UsageCapRow>[cap],
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(PricingTierAdminScreen(gateway: gateway, editingEnabled: false)),
      );
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      expect(
        find.byKey(const Key('admin_pricing_readonly_banner')),
        findsOneWidget,
      );
      // No plan presets card (Change plan) when read-only, so no
      // apply-template button.
      expect(
        find.byKey(const Key('admin_pricing_add_cap_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_pricing_template_premium_button')),
        findsNothing,
      );
      expect(
        find.byKey(Key('admin_pricing_cap_edit_${cap.capId}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'admin shell with ff_support source renders pricing in read-only mode',
    (tester) async {
      // Tall surface so the full admin nav + the master/detail
      // affordances are on-screen for the shell click path.
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pricingGateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(
            operatorId: demoWorkspaceOperatorId,
            businessName: 'Support View Co',
          ),
        ],
      );
      final source = DemoAdminAuthSource(
        initial: const AdminAuthAuthenticated(
          AdminAuthSession(
            uid: 'demo-ff-support',
            email: 'support@forgeflow.test',
            displayName: 'Demo F&F Support',
            roles: <String>['ff_support'],
          ),
        ),
      );
      addTearDown(source.dispose);
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          pricingTierGateway: pricingGateway,
          adminAuthSource: source,
          child: AdminConsoleApp(authSource: source),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_nav_item_pricing')));
      await tester.pumpAndSettle();
      await chooseWorkspaceBusinessScope(tester);

      expect(find.byKey(const Key('admin_pricing_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_pricing_readonly_banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_pricing_add_cap_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_pricing_template_premium_button')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'admin shell with super_admin source renders pricing with edit affordances',
    (tester) async {
      // Tall surface so the full admin nav + the master/detail
      // affordances are on-screen for the shell click path.
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pricingGateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(
            operatorId: demoWorkspaceOperatorId,
            businessName: 'Super View Co',
          ),
        ],
      );
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          pricingTierGateway: pricingGateway,
          adminAuthSource: source,
          child: AdminConsoleApp(authSource: source),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_nav_item_pricing')));
      await tester.pumpAndSettle();
      await chooseWorkspaceBusinessScope(tester);

      expect(find.byKey(const Key('admin_pricing_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_pricing_readonly_banner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_pricing_add_cap_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_pricing_template_premium_button')),
        findsOneWidget,
      );
    },
  );

  testWidgets('apply-template error renders in the action banner', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        seedBundle(operatorId: 'op-no-loc', primaryLocationId: null),
      ],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final pilotButton = find.byKey(
      const Key('admin_pricing_template_pilot_button'),
    );
    await tester.ensureVisible(pilotButton);
    await tester.pumpAndSettle();
    await tester.tap(pilotButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_pricing_confirm_ok')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_action_error')), findsOneWidget);
  });
}

/// Test double whose plan-catalog read always fails, standing in for the
/// `GET /v1/admin/pricing/plans` endpoint not being deployed yet or an
/// offline failure. Everything else delegates to the in-memory gateway so
/// the rest of the screen still works. Used to prove the Plans map falls
/// back to the hard-coded presentations.
class _ThrowingCatalogGateway extends InMemoryPricingTierAdminGateway {
  _ThrowingCatalogGateway({super.seed});

  @override
  Future<List<PricingPlanCatalogEntry>> listPlanCatalog() async {
    throw const PricingTierAdminGatewayError(
      statusCode: 503,
      errorCode: 'plans_unavailable',
      message: 'plan catalog endpoint is not available',
    );
  }
}
