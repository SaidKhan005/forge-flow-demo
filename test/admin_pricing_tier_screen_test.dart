// Plans & Limits V1 (Phase 1) — admin Plans & limits screen widget
// tests.
//
// Drives the rebuilt screen against an
// `InMemoryPricingTierAdminGateway` (+ an
// `InMemoryObservabilityAdminGateway` for the read-only spend / margin
// / cap-breach figures) so the click path runs end-to-end without a
// backend. The screen opens on the read-only "Plans" tab; the
// Businesses tab now shows the detail for the business the left scope
// tree (`hierarchyScope`) selects — there is no per-business master list
// of its own — so most tests pass a [businessScope] and switch to the
// tab via [openBusinessesTab]. Coverage:
//
//   * Plans tab renders the laddered six-plan map (read-only).
//   * Businesses tab shows the scope-selected operator's detail directly
//     (no master list), with margin % and spend joined from
//     observability.
//   * "No operators on file" empty state renders when the gateway returns
//     no businesses.
//   * "Choose a business" empty state renders when businesses exist but
//     the scope resolves no operator (no crash, no random pick).
//   * Apply-template flow seeds Premium cap rows.
//   * Inline edit flow rewrites a usage cap (use case is a dropdown).
//   * Spend-vs-cap bar joins observability cost telemetry to a cap.
//   * Read-only mode (`editingEnabled: false`) hides every mutate
//     affordance — exercised by the `ff_support` walkthrough.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
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

  // The left scope tree is the single business selector now. A
  // business-level scope for the operator under test stands in for the
  // tree having that business picked, so the Businesses tab renders that
  // operator's detail directly.
  AdminHierarchyScopeIntent businessScope(String operatorId) =>
      AdminHierarchyScopeIntent.business(operatorId: operatorId);

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

  testWidgets(
    'Businesses tab shows the scope-selected operator detail (no master '
    'list)',
    (tester) async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
          seedBundle(
            operatorId: 'op-2',
            businessName: 'Beta Bistro',
            caps: <UsageCapRow>[
              seedCap(operatorId: 'op-2', locationId: 'loc-2'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            observabilityGateway: observabilityFor('op-2'),
            // The scope tree has Beta Bistro (op-2) picked.
            hierarchyScope: businessScope('op-2'),
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
      // No per-business master list and no per-business rows: the left
      // scope tree is the single selector now.
      expect(
        find.byKey(const Key('admin_pricing_operator_list')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_pricing_row_op-1')), findsNothing);
      expect(find.byKey(const Key('admin_pricing_row_op-2')), findsNothing);

      // The scope-selected operator's detail renders directly.
      expect(
        find.byKey(const Key('admin_pricing_detail_op-2')),
        findsOneWidget,
      );
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
    },
  );

  testWidgets(
    'Custom contract edit is hidden when scoped contract load fails',
    (tester) async {
      final gateway = _ThrowingScopedContractGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-contract', businessName: 'Contract Cafe'),
        ],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            observabilityGateway: observabilityFor('op-contract'),
            hierarchyScope: businessScope('op-contract'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      expect(
        find.text('custom contract endpoint is not available'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_pricing_edit_contract_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_pricing_clear_contract_button')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Businesses tab shows the pick-a-business empty state when the scope '
    'resolves no operator',
    (tester) async {
      // Businesses exist, but no scope is provided, so the scope tree has
      // resolved no business. The tab must show a clean empty state, not
      // crash and not silently pick a random business.
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
          seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
        ],
      );
      await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      expect(
        find.byKey(const Key('admin_pricing_pick_business')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Choose a business in the scope panel to see its plan and limits.',
        ),
        findsOneWidget,
      );
      // No detail is shown and no business was auto-selected.
      expect(find.byKey(const Key('admin_pricing_detail_op-1')), findsNothing);
      expect(find.byKey(const Key('admin_pricing_detail_op-2')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Businesses tab shows the pick-a-business empty state when the scoped '
    'operator is absent from the gateway result',
    (tester) async {
      // The scope resolves an operator the gateway does not return (e.g. a
      // stale or cross-tenant selection). Falls back to the empty state
      // rather than crashing or showing the wrong business.
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(operatorId: 'op-present', businessName: 'Present Co'),
        ],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            hierarchyScope: businessScope('op-absent'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      expect(
        find.byKey(const Key('admin_pricing_pick_business')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_pricing_detail_op-present')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.byKey(const Key('admin_pricing_add_cap_button')), findsNothing);
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
      final monthlyField = find.byKey(const Key('admin_pricing_plan_monthly'));
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
      wrap(PricingTierAdminScreen(gateway: gateway, editingEnabled: false)),
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

  // ── Phase 5a — Included features (entitlements) matrix tab. ───────
  testWidgets('Phase 5a: Included features tab renders a matrix row per plan', (
    tester,
  ) async {
    final gateway = InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[seedBundle()],
    );
    await tester.pumpWidget(wrap(PricingTierAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_pricing_tab_features')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_pricing_features_view')),
      findsOneWidget,
    );
    // One row per plan, each with the advisor toggle present.
    for (final key in const <String>[
      'pilot',
      'starter',
      'premium',
      'elite',
      'pro',
      'enterprise',
    ]) {
      expect(
        find.byKey(Key('admin_pricing_entitlements_row_$key')),
        findsOneWidget,
        reason: 'entitlements row for $key',
      );
      expect(
        find.byKey(Key('admin_pricing_entitlement_toggle_${key}_advisor')),
        findsOneWidget,
        reason: 'advisor toggle for $key',
      );
    }
  });

  testWidgets(
    'Phase 5a: toggling a cell calls updateEntitlement and persists',
    (tester) async {
      var counter = 0;
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[seedBundle()],
      );
      // Starter does not include LMS by default.
      final before = await gateway.listEntitlements();
      expect(
        before
            .firstWhere((e) => e.tierKey == 'starter' && e.featureSlug == 'lms')
            .enabled,
        isFalse,
      );

      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            idempotencyKeyFactory: () => 'k-ent-${counter++}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_pricing_tab_features')));
      await tester.pumpAndSettle();

      final toggle = find.byKey(
        const Key('admin_pricing_entitlement_toggle_starter_lms'),
      );
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // Saved through the gateway: Starter now includes LMS.
      final after = await gateway.listEntitlements();
      expect(
        after
            .firstWhere((e) => e.tierKey == 'starter' && e.featureSlug == 'lms')
            .enabled,
        isTrue,
      );
    },
  );

  testWidgets(
    'Phase 5a: read-only mode renders the matrix with disabled toggles',
    (tester) async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(PricingTierAdminScreen(gateway: gateway, editingEnabled: false)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_pricing_tab_features')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_pricing_features_view')),
        findsOneWidget,
      );
      // The matrix still renders, but the toggle is disabled (onChanged
      // null) so a support user cannot mutate it.
      final toggle = tester.widget<Switch>(
        find.byKey(const Key('admin_pricing_entitlement_toggle_premium_lms')),
      );
      expect(toggle.onChanged, isNull);
    },
  );

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
          hierarchyScope: businessScope('op-spend'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    // $50 spent against a $200 cap = 25%.
    expect(find.text('\$50 / \$200 this month'), findsOneWidget);
    expect(find.text('25%'), findsWidgets);
  });

  testWidgets('renders the scoped detail single-pane on compact widths', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-compact'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    // No master list at any width: just the scoped detail, rendered
    // single-pane without clipping on a narrow surface.
    expect(find.byKey(const Key('admin_pricing_operator_list')), findsNothing);
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-prem'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final premiumButton = find.byKey(
      const Key('admin_pricing_template_premium_button'),
    );
    await tester.ensureVisible(premiumButton);
    await tester.pumpAndSettle();
    await tester.tap(premiumButton);
    await tester.pumpAndSettle();
    // The preset preview diff gates the apply (replaces the old plain
    // confirm).
    expect(
      find.byKey(const Key('admin_pricing_preset_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_pricing_preset_apply')));
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-edit'),
        ),
      ),
    );
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-del'),
        ),
      ),
    );
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-keep'),
        ),
      ),
    );
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
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          editingEnabled: false,
          hierarchyScope: businessScope('op-ro-del'),
        ),
      ),
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-add'),
        ),
      ),
    );
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
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            editingEnabled: false,
            hierarchyScope: businessScope('op-readonly'),
          ),
        ),
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
    await tester.pumpWidget(
      wrap(
        PricingTierAdminScreen(
          gateway: gateway,
          hierarchyScope: businessScope('op-no-loc'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openBusinessesTab(tester);

    final pilotButton = find.byKey(
      const Key('admin_pricing_template_pilot_button'),
    );
    await tester.ensureVisible(pilotButton);
    await tester.pumpAndSettle();
    await tester.tap(pilotButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_pricing_preset_apply')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_pricing_action_error')), findsOneWidget);
  });

  testWidgets(
    'preset preview diff shows a NEW row, a CHANGED row, and applies on '
    'confirm',
    (tester) async {
      // Operator is on a plan with an existing advisor_qa cap at $50.
      // Applying Elite (advisor_qa $400 + coach_qa $300) must preview
      // advisor_qa as CHANGED ($50 to $400) and coach_qa as NEW ($300).
      final existing = seedCap(
        operatorId: 'op-diff',
        locationId: 'loc-diff',
        usageClass: 'advisor_qa',
        monthly: 50.0,
      );
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(
            operatorId: 'op-diff',
            tier: 'starter',
            primaryLocationId: 'loc-diff',
            caps: <UsageCapRow>[existing],
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            hierarchyScope: businessScope('op-diff'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      final eliteButton = find.byKey(
        const Key('admin_pricing_template_elite_button'),
      );
      await tester.ensureVisible(eliteButton);
      await tester.pumpAndSettle();
      await tester.tap(eliteButton);
      await tester.pumpAndSettle();

      // The preview diff dialog opens with both rows.
      expect(
        find.byKey(const Key('admin_pricing_preset_dialog')),
        findsOneWidget,
      );
      // advisor_qa already exists at a different amount -> CHANGED, with
      // the prior ($50) and new ($400/mo) amounts both visible inside the
      // row.
      final advisorRow = find.byKey(
        const Key('admin_pricing_preset_row_advisor_qa'),
      );
      expect(advisorRow, findsOneWidget);
      expect(find.text('CHANGED'), findsOneWidget);
      expect(
        find.descendant(of: advisorRow, matching: find.text('\$50')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: advisorRow, matching: find.text('\$400/mo')),
        findsOneWidget,
      );
      // coach_qa has no current limit -> NEW, new amount $300/mo.
      final coachRow = find.byKey(
        const Key('admin_pricing_preset_row_coach_qa'),
      );
      expect(coachRow, findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);
      expect(
        find.descendant(of: coachRow, matching: find.text('\$300/mo')),
        findsOneWidget,
      );

      // Confirming applies the template through the gateway.
      await tester.tap(find.byKey(const Key('admin_pricing_preset_apply')));
      await tester.pumpAndSettle();

      final operators = await gateway.listOperators();
      expect(operators.single.subscriptionTier, equals('elite'));
      final classes = operators.single.caps.map((c) => c.usageClass).toSet();
      expect(classes, containsAll(<String>['advisor_qa', 'coach_qa']));
      expect(
        operators.single.caps
            .firstWhere((c) => c.usageClass == 'advisor_qa')
            .monthlyCapUsd,
        equals(400.0),
      );
    },
  );

  testWidgets(
    'preset preview shows the custom-contract note and no diff rows for '
    'Enterprise',
    (tester) async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          seedBundle(
            operatorId: 'op-ent',
            tier: 'pro',
            primaryLocationId: 'loc-ent',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          PricingTierAdminScreen(
            gateway: gateway,
            hierarchyScope: businessScope('op-ent'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openBusinessesTab(tester);

      final enterpriseButton = find.byKey(
        const Key('admin_pricing_template_enterprise_button'),
      );
      await tester.ensureVisible(enterpriseButton);
      await tester.pumpAndSettle();
      await tester.tap(enterpriseButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_pricing_preset_dialog')),
        findsOneWidget,
      );
      // Custom contract: the note shows and there are no diff rows.
      expect(
        find.byKey(const Key('admin_pricing_preset_custom_note')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_pricing_preset_row_advisor_qa')),
        findsNothing,
      );
      expect(find.text('NEW'), findsNothing);
      expect(find.text('CHANGED'), findsNothing);
    },
  );
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

class _ThrowingScopedContractGateway extends InMemoryPricingTierAdminGateway {
  _ThrowingScopedContractGateway({super.seed});

  @override
  Future<ScopedPricingContractEffectiveResponse> fetchEffectiveScopedContract(
    ScopedPricingContractScope scope,
  ) async {
    throw const PricingTierAdminGatewayError(
      statusCode: 503,
      errorCode: 'scoped_contract_unavailable',
      message: 'custom contract endpoint is not available',
    );
  }
}
