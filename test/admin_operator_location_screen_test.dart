// Phase 11A.1 — Operator/location admin screen widget tests.
//
// Drives the screen against an `InMemoryOperatorLocationAdminGateway`
// so the click path runs end-to-end without a backend. Coverage:
//
//   * Initial render lists every seeded operator.
//   * Operator search filters the list by name, email, plan, and location.
//   * Empty state renders when no operators are seeded.
//   * Onboarding flow creates an operator + primary location.
//   * Suspend / reactivate buttons flip the badge.
//   * Add/edit location dialogs submit IANA timezones from dropdowns.
//   * Edit location dialog patches the selected location.
//   * Remove-location button is disabled on the primary location.
//   * Non-admin user cannot reach the screen via the admin shell
//     (forbidden-card path through `AdminAuthGate`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_responsive_layout.dart';
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
          parentOrgUnitId: 'org-root',
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

  Future<void> chooseTimezone(
    WidgetTester tester,
    Key fieldKey,
    String timezone,
  ) async {
    final field = find.byKey(fieldKey);
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_timezone_search_field')),
      timezone,
    );
    await tester.pumpAndSettle();

    final option = find.byKey(Key('admin_timezone_option_text_$timezone'));
    await tester.tap(option);
    await tester.pumpAndSettle();
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
    expect(find.byKey(const Key('admin_operator_manage_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_manage_op-2')), findsNothing);
    expect(find.text('Click to manage'), findsNothing);
    expect(
      find.byKey(const Key('admin_business_setup_tile_account_profile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_data_accuracy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_polling_pricing')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_people_access_roles')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('admin_business_setup_tile_security_audit_sessions'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_support_logs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_integrations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_timing')),
      findsOneWidget,
    );
    expect(find.text('Support workspace'), findsNothing);
    // The selected operator's name shows in both the list row and the
    // detail card; the unselected operator's name only in the list.
    expect(find.text('Alpha Cafe'), findsWidgets);
    expect(find.text('Beta Bistro'), findsWidgets);
  });

  testWidgets('operator detail opens support logs for operator and location', (
    tester,
  ) async {
    final supportLogRequests = <List<String?>>[];
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-support',
          primaryLocationId: 'loc-support',
          businessName: 'Support Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          onOpenSupportLogs: (operatorId, locationId) {
            supportLogRequests.add(<String?>[operatorId, locationId]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final supportLogsTile = find.byKey(
      const Key('admin_business_setup_tile_support_logs'),
    );
    await tester.ensureVisible(supportLogsTile);
    await tester.pumpAndSettle();
    await tester.tap(supportLogsTile);
    await tester.pumpAndSettle();
    expect(supportLogRequests, hasLength(1));
    expect(supportLogRequests.single, <String?>['op-support', null]);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-support'),
    );
    await tester.ensureVisible(locationRow);
    await tester.pumpAndSettle();
    await tester.tap(locationRow);
    await tester.pumpAndSettle();
    await tester.ensureVisible(supportLogsTile);
    await tester.pumpAndSettle();
    await tester.tap(supportLogsTile);
    await tester.pumpAndSettle();
    expect(supportLogRequests, hasLength(2));
    expect(supportLogRequests.last, <String?>['op-support', 'loc-support']);
  });

  testWidgets('setup tiles preserve business and location hierarchy scope', (
    tester,
  ) async {
    final scopes = <AdminHierarchyScopeIntent>[];
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-workspace',
          primaryLocationId: 'loc-workspace',
          businessName: 'Workspace Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          onOpenPeopleAccessRolesScope: scopes.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final peopleTile = find.byKey(
      const Key('admin_business_setup_tile_people_access_roles'),
    );
    await tester.ensureVisible(peopleTile);
    await tester.pumpAndSettle();
    await tester.tap(peopleTile);
    await tester.pumpAndSettle();
    expect(scopes, hasLength(1));
    expect(scopes.single.operatorId, 'op-workspace');
    expect(scopes.single.scopeType, AdminHierarchyScopeType.business);
    expect(scopes.single.locationId, isNull);
    expect(scopes.single.operatorName, 'Workspace Cafe');

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-workspace'),
    );
    await tester.ensureVisible(locationRow);
    await tester.pumpAndSettle();
    await tester.tap(locationRow);
    await tester.pumpAndSettle();
    await tester.ensureVisible(peopleTile);
    await tester.pumpAndSettle();
    await tester.tap(peopleTile);
    await tester.pumpAndSettle();
    expect(scopes, hasLength(2));
    expect(scopes.last.operatorId, 'op-workspace');
    expect(scopes.last.scopeType, AdminHierarchyScopeType.location);
    expect(scopes.last.locationId, 'loc-workspace');
    expect(scopes.last.operatorName, 'Workspace Cafe');
    expect(scopes.last.locationName, 'HQ');
  });

  testWidgets('Account profile tile edits the business contact email', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-profile',
          primaryLocationId: 'loc-profile',
          businessName: 'Profile Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final profileTile = find.byKey(
      const Key('admin_business_setup_tile_account_profile'),
    );
    await tester.ensureVisible(profileTile);
    await tester.pumpAndSettle();
    await tester.tap(profileTile);
    await tester.pumpAndSettle();

    final dialog = find.byKey(const Key('admin_edit_operator_dialog'));
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('Account profile')),
      findsOneWidget,
    );
    expect(find.text('Owner email'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('admin_edit_owner_email')),
      'contact@profile.test',
    );
    await tester.tap(find.byKey(const Key('admin_edit_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators.single.operator.ownerEmail, 'contact@profile.test');
    expect(find.text('contact@profile.test'), findsWidgets);
  });

  testWidgets('Account profile conflict details show existing email usage', (
    tester,
  ) async {
    final gateway = _EmailConflictOperatorGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-profile-conflict',
          primaryLocationId: 'loc-profile-conflict',
          businessName: 'Conflict Source Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final profileTile = find.byKey(
      const Key('admin_business_setup_tile_account_profile'),
    );
    await tester.ensureVisible(profileTile);
    await tester.pumpAndSettle();
    await tester.tap(profileTile);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_edit_owner_email')),
      'taken@business.test',
    );
    await tester.tap(find.byKey(const Key('admin_edit_submit_button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Contact email is already used by another account.'),
      findsOneWidget,
    );
    expect(find.text('Where this email is used'), findsOneWidget);
    expect(
      find.byKey(
        const Key('admin_operators_email_conflict_taken@business.test'),
      ),
      findsOneWidget,
    );
    expect(find.text('Conflict Bistro / Downtown'), findsOneWidget);
    expect(find.textContaining('Business contact'), findsOneWidget);
  });

  testWidgets('location Timing action opens a scoped non-destructive dialog', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-timing',
          primaryLocationId: 'loc-timing',
          businessName: 'Timing Cafe',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-timing'),
    );
    await tester.ensureVisible(locationRow);
    await tester.pumpAndSettle();
    await tester.tap(locationRow);
    await tester.pumpAndSettle();

    final timingTile = find.byKey(
      const Key('admin_business_setup_tile_timing'),
    );
    await tester.ensureVisible(timingTile);
    await tester.pumpAndSettle();
    await tester.tap(timingTile);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_location_timing_dialog')),
      findsOneWidget,
    );
    expect(find.text('Timing Cafe / HQ'), findsWidgets);
    expect(find.text('America/Toronto'), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
    expect(find.textContaining('No timing change was written'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_location_timing_audit_reason')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_location_timing_save_disabled')),
      findsOneWidget,
    );
  });

  testWidgets(
    'read-only location Timing dialog does not expose save controls',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(
            operatorId: 'op-timing-readonly',
            primaryLocationId: 'loc-timing-readonly',
            businessName: 'Readonly Cafe',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(gateway: gateway, editingEnabled: false),
        ),
      );
      await tester.pumpAndSettle();

      final locationRow = find.byKey(
        const Key('admin_hierarchy_location_loc-timing-readonly'),
      );
      await tester.ensureVisible(locationRow);
      await tester.pumpAndSettle();
      await tester.tap(locationRow);
      await tester.pumpAndSettle();

      final timingTile = find.byKey(
        const Key('admin_business_setup_tile_timing'),
      );
      await tester.ensureVisible(timingTile);
      await tester.pumpAndSettle();
      await tester.tap(timingTile);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_location_timing_dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Read-only support view'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_location_timing_audit_reason')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_location_timing_save_disabled')),
        findsNothing,
      );
    },
  );

  testWidgets('search filters operators by operator and location text', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(operatorId: 'op-1', businessName: 'Alpha Cafe'),
        seedBundle(
          operatorId: 'op-2',
          businessName: 'Beta Bistro',
          primaryLocationId: 'loc-beta',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'beta',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'toronto',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'zzzz',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operators_no_matches')), findsOneWidget);
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
    expect(find.text('No business accounts yet'), findsOneWidget);
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
    await chooseTimezone(
      tester,
      const Key('admin_onboard_location_timezone'),
      'America/Vancouver',
    );
    await tester.tap(find.byKey(const Key('admin_onboard_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    expect(operators, hasLength(1));
    expect(operators.single.operator.businessName, equals('New Operator Inc'));
    expect(
      operators.single.locations.single.timezone,
      equals('America/Vancouver'),
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

    final reactivateButton = find.byKey(
      const Key('admin_operator_reactivate_button'),
    );
    await tester.ensureVisible(reactivateButton);
    await tester.pumpAndSettle();
    await tester.tap(reactivateButton);
    await tester.pumpAndSettle();
    expect(find.text('suspended'), findsNothing);
  });

  testWidgets('suspended operator fades the location rows', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-paused',
          primaryLocationId: 'loc-paused',
          suspended: true,
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final fadedLocation = tester.widget<Opacity>(
      find.byKey(const Key('admin_location_suspended_fade_loc-paused')),
    );
    expect(fadedLocation.opacity, lessThan(1));

    await tester.tap(find.byKey(const Key('admin_operator_reactivate_button')));
    await tester.pumpAndSettle();

    final activeLocation = tester.widget<Opacity>(
      find.byKey(const Key('admin_location_suspended_fade_loc-paused')),
    );
    expect(activeLocation.opacity, equals(1));
  });

  testWidgets('operator AI plan selection is read-only while coming soon', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Forge & Flow AI plan'), findsOneWidget);
    final detailRow = tester.widget<AdminDetailRow>(
      find.byKey(const Key('admin_operator_ai_plan_detail_row')),
    );
    expect(detailRow.muted, isTrue);

    await tester.tap(find.byKey(const Key('admin_operator_edit_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_edit_operator_dialog')), findsOneWidget);
    expect(find.text('Forge & Flow AI plan'), findsWidgets);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Coming soon')).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('admin_subscription_tier_dropdown')),
            )
            .dy,
      ),
    );

    final planField = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('admin_subscription_tier_dropdown')),
    );
    expect(planField.onChanged, isNull);
  });

  testWidgets('add location requires a selected hierarchy org unit', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final addButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    expect(addButton.onPressed, isNull);
    expect(
      find.byKey(const Key('admin_location_parent_org_unit_required_copy')),
      findsOneWidget,
    );
  });

  testWidgets('add location dialog submits the selected IANA timezone', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          selectedParentOrgUnitId: 'org-unit-harbour',
          selectedParentOrgUnitLabel: 'Harbour Region',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final addButton = find.byKey(
      const Key('admin_operator_add_location_button'),
    );
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_location_add_dialog')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_location_parent_org_unit_field')),
      findsOneWidget,
    );
    expect(find.text('Harbour Region'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'Harbour',
    );
    await chooseTimezone(
      tester,
      const Key('admin_location_timezone_field'),
      'America/Halifax',
    );
    await tester.tap(find.byKey(const Key('admin_location_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    final added = operators.single.locations.firstWhere(
      (l) => l.name == 'Harbour',
    );
    expect(added.timezone, equals('America/Halifax'));
    expect(added.parentOrgUnitId, equals('org-unit-harbour'));
    expect(find.byKey(const Key('admin_location_add_dialog')), findsNothing);
  });

  testWidgets('edit location dialog patches the selected location', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final editButton = find.byKey(const Key('admin_location_edit_loc-seed-1'));
    await tester.ensureVisible(editButton);
    await tester.pumpAndSettle();
    await tester.tap(editButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_location_edit_dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'Harbour HQ',
    );
    await chooseTimezone(
      tester,
      const Key('admin_location_timezone_field'),
      'America/St_Johns',
    );
    await tester.tap(find.byKey(const Key('admin_location_submit_button')));
    await tester.pumpAndSettle();

    final operators = await gateway.listOperators();
    final location = operators.single.locations.single;
    expect(location.name, equals('Harbour HQ'));
    expect(location.timezone, equals('America/St_Johns'));
    expect(find.text('Harbour HQ'), findsWidgets);
  });

  testWidgets('remove button is disabled on the primary location', (
    tester,
  ) async {
    final bundle = seedBundle(operatorId: 'op-x', primaryLocationId: 'loc-x');
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[bundle],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          selectedParentOrgUnitId: 'org-unit-west',
          selectedParentOrgUnitLabel: 'West Region',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final removeButton = tester.widget<IconButton>(
      find.byKey(const Key('admin_location_remove_loc-x')),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('location vendor action is a manage integrations button', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-seed-1'),
    );
    await tester.ensureVisible(locationRow);
    await tester.pumpAndSettle();
    await tester.tap(locationRow);
    await tester.pumpAndSettle();

    final integrationsTile = find.byKey(
      const Key('admin_business_setup_tile_integrations'),
    );
    await tester.ensureVisible(integrationsTile);
    await tester.pumpAndSettle();

    expect(integrationsTile, findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);

    await tester.tap(integrationsTile);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
  });

  testWidgets('editingEnabled false hides operator and location mutations', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(gateway: gateway, editingEnabled: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_operators_readonly_banner')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operators_new_button')), findsNothing);
    expect(find.byKey(const Key('admin_operator_edit_button')), findsNothing);
    expect(
      find.byKey(const Key('admin_operator_suspend_button')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_operator_add_location_button')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_location_edit_loc-seed-1')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_location_remove_loc-seed-1')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_integrations')),
      findsOneWidget,
    );
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
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          selectedParentOrgUnitId: 'org-unit-west',
          selectedParentOrgUnitLabel: 'West Region',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Add a second location through the dialog.
    final addButton = find.byKey(
      const Key('admin_operator_add_location_button'),
    );
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_location_name_field')),
      'West Coast',
    );
    await chooseTimezone(
      tester,
      const Key('admin_location_timezone_field'),
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

  testWidgets('admin shell with ff_support renders operators read-only', (
    tester,
  ) async {
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
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-support-shell')],
    );

    await tester.pumpWidget(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateway,
        adminAuthSource: source,
        child: AdminConsoleApp(authSource: source),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_operators_readonly_banner')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_operators_new_button')), findsNothing);
    expect(find.byKey(const Key('admin_operator_edit_button')), findsNothing);
  });
}

class _EmailConflictOperatorGateway
    extends InMemoryOperatorLocationAdminGateway {
  _EmailConflictOperatorGateway({required super.seed});

  @override
  Future<OperatorAdminRecord> patchOperator(
    OperatorPatchCommand command,
  ) async {
    throw const OperatorLocationAdminGatewayError(
      statusCode: 409,
      errorCode: 'email_in_use',
      message: 'Contact email is already used by another account.',
      details: <String, Object?>{
        'email_conflicts': <Object?>[
          <String, Object?>{
            'email': 'taken@business.test',
            'source': 'business_contact',
            'operator_id': 'op-existing-business',
            'business_name': 'Conflict Bistro',
            'location_id': 'loc-existing-business',
            'location_name': 'Downtown',
            'status': 'active',
          },
        ],
      },
    );
  }
}
