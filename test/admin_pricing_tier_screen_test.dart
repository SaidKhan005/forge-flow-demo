// Phase 11A.2 — Pricing tier admin screen widget tests.
//
// Drives the screen against an `InMemoryPricingTierAdminGateway` so
// the click path runs end-to-end without a backend. Coverage:
//
//   * Initial render lists every seeded operator with cap rows.
//   * Empty state renders when no operators are seeded.
//   * Apply-template flow seeds Premium cap rows.
//   * Inline edit flow rewrites a usage cap.
//   * Read-only mode (`editingEnabled: false`) hides every mutate
//     affordance — exercised by the `ff_support` walkthrough.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/pricing_tier_admin_models.dart';
import 'package:forge_and_flow/admin/screens/pricing_tier_admin_screen.dart';
import 'package:forge_and_flow/admin/services/pricing_tier_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  Future<void> chooseWorkspaceBusinessScope(WidgetTester tester) async {
    const operatorId = '00000000-0000-4000-8000-000000000001';
    final option = find.byKey(Key('admin_setup_scope_business_$operatorId'));
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

  testWidgets('renders one row per seeded operator with cap counts', (
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
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_screen')), findsOneWidget);
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

    await tester.tap(
      find.byKey(const Key('admin_pricing_template_premium_button')),
    );
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

    final editKey = Key('admin_pricing_cap_edit_${cap.capId}');
    await tester.ensureVisible(find.byKey(editKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(editKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_cap_dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('admin_pricing_cap_monthly')),
      '125.00',
    );
    await tester.tap(find.byKey(const Key('admin_pricing_cap_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.caps.single.monthlyCapUsd, equals(125.0));
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
      expect(
        find.byKey(Key('admin_pricing_cap_edit_${cap.capId}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'admin shell with ff_support source renders pricing in read-only mode',
    (tester) async {
      final pricingGateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-support', businessName: 'Support View Co'),
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
      final pricingGateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-super', businessName: 'Super View Co'),
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

    await tester.tap(
      find.byKey(const Key('admin_pricing_template_pilot_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_pricing_confirm_ok')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_action_error')), findsOneWidget);
  });
}
