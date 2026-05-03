// Phase 11A.1 — Operator/location admin screen widget tests.
//
// Drives the screen against an `InMemoryOperatorLocationAdminGateway`
// so the click path runs end-to-end without a backend. Coverage:
//
//   * Initial render lists every seeded operator.
//   * Empty state renders when no operators are seeded.
//   * Onboarding flow creates an operator + primary location.
//   * Suspend / reactivate buttons flip the badge.
//   * Add location dialog rejects an invalid IANA timezone before
//     reaching the gateway.
//   * Remove-location button is disabled on the primary location.
//   * Non-admin user cannot reach the screen via the admin shell
//     (forbidden-card path through `AdminAuthGate`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  OperatorAdminBundle seedBundle({
    String operatorId = 'op-seed-1',
    String primaryLocationId = 'loc-seed-1',
    String businessName = 'Seed Cafe',
    bool suspended = false,
  }) {
    final created = DateTime.utc(2026, 1, 1);
    return OperatorAdminBundle(
      operator: OperatorAdminRecord(
        operatorId: operatorId,
        businessName: businessName,
        ownerEmail: 'owner@seed.test',
        subscriptionTier: 'launch',
        preferredCurrency: 'CAD',
        primaryLocationId: primaryLocationId,
        suspendedAt: suspended ? DateTime.utc(2026, 4, 1) : null,
        createdAt: created,
        updatedAt: created,
      ),
      locations: <LocationAdminRecord>[
        LocationAdminRecord(
          locationId: primaryLocationId,
          operatorId: operatorId,
          name: 'HQ',
          address: '',
          timezone: 'America/Toronto',
          businessDayRolloverHour: 4,
          createdAt: created,
          updatedAt: created,
        ),
      ],
    );
  }

  testWidgets('renders one row per seeded operator', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(operatorId: 'op-2', businessName: 'Beta Bistro'),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);
    // The selected operator's name shows in both the list row and the
    // detail card; the unselected operator's name only in the list.
    expect(find.text('Alpha Cafe'), findsWidgets);
    expect(find.text('Beta Bistro'), findsWidgets);
  });

  testWidgets('stacks master/detail panes on compact widths', (tester) async {
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
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operators_list')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_operator_detail_op-compact')),
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
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operators_empty')), findsOneWidget);
    expect(find.text('No customers yet'), findsOneWidget);
  });

  testWidgets('onboarding dialog creates a new operator end-to-end', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway();
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_operators_new_button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_onboard_operator_dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_onboard_business_name')),
      'New Operator Inc',
    );
    await tester.enterText(
      find.byKey(const Key('admin_onboard_owner_email')),
      'owner@new.test',
    );
    await tester.enterText(
      find.byKey(const Key('admin_onboard_admin_email')),
      'admin@new.test',
    );
    await tester.enterText(
      find.byKey(const Key('admin_onboard_location_name')),
      'Main',
    );
    await tester.enterText(
      find.byKey(const Key('admin_onboard_location_timezone')),
      'America/Toronto',
    );
    await tester.tap(find.byKey(const Key('admin_onboard_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators, hasLength(1));
    expect(operators.single.operator.businessName, equals('New Operator Inc'));
    expect(
      operators.single.locations.single.timezone,
      equals('America/Toronto'),
    );
    expect(find.text('New Operator Inc'), findsWidgets);
  });

  testWidgets('suspend then reactivate flips the badge', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-active')],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.text('suspended'), findsNothing);

    await tester.tap(find.byKey(const Key('admin_operator_suspend_button')));
    await tester.pumpAndSettle();
    expect(find.text('suspended'), findsWidgets);

    await tester.tap(find.byKey(const Key('admin_operator_reactivate_button')));
    await tester.pumpAndSettle();
    expect(find.text('suspended'), findsNothing);
  });

  testWidgets('add location dialog rejects an invalid IANA timezone', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_location_add_dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'Bad Zone',
    );
    await tester.enterText(
      find.byKey(const Key('admin_location_timezone_field')),
      'not a zone',
    );
    await tester.tap(find.byKey(const Key('admin_location_submit_button')));
    await tester.pumpAndSettle();

    // Form-level validator blocks submit; dialog stays open.
    expect(find.byKey(const Key('admin_location_add_dialog')), findsOneWidget);
    expect(find.text('Use an IANA name like America/Toronto'), findsOneWidget);
  });

  testWidgets('remove button is disabled on the primary location', (
    tester,
  ) async {
    final bundle = seedBundle(operatorId: 'op-x', primaryLocationId: 'loc-x');
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[bundle],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final removeButton = tester.widget<IconButton>(
      find.byKey(const Key('admin_location_remove_loc-x')),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('add and then remove a non-primary location', (tester) async {
    final bundle = seedBundle(
      operatorId: 'op-rem',
      primaryLocationId: 'loc-rem-primary',
    );
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[bundle],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Add a second location through the dialog.
    await tester.tap(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'West Coast',
    );
    await tester.enterText(
      find.byKey(const Key('admin_location_timezone_field')),
      'America/Vancouver',
    );
    await tester.tap(find.byKey(const Key('admin_location_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.locations, hasLength(2));
    final added = operators.single.locations.firstWhere(
      (l) => l.name == 'West Coast',
    );

    // Remove it through the row's delete button + confirm dialog.
    final removeButton = find.byKey(
      Key('admin_location_remove_${added.locationId}'),
    );
    await tester.ensureVisible(removeButton);
    await tester.pumpAndSettle();
    await tester.tap(removeButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_confirm_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_confirm_confirm_button')));
    await tester.pumpAndSettle();

    final after = await gateway.listOperators();
    expect(after.single.locations, hasLength(1));
    expect(after.single.locations.single.name, equals('HQ'));
  });

  testWidgets('non-admin user is blocked by the admin auth gate', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);
    await tester.pumpWidget(AdminConsoleApp(authSource: source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_forbidden_card')), findsOneWidget);
    expect(find.byKey(const Key('admin_operators_screen')), findsNothing);
    expect(find.text('Operators'), findsNothing);
  });

  testWidgets(
    'admin services scope overrides the default gateway in the shell',
    (tester) async {
      final overrideGateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-override', businessName: 'Override Co'),
        ],
      );
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);

      // AdminConsoleApp owns its own MaterialApp; wrapping the scope
      // above it puts the override on the InheritedWidget path that
      // the operators-route builder reads via
      // `AdminConsoleServicesScope.operatorLocationGatewayOf`.
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          operatorLocationGateway: overrideGateway,
          child: AdminConsoleApp(authSource: source),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_operator_row_op-override')),
        findsOneWidget,
      );
    },
  );
}
