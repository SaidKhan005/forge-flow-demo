// Phase 11A.1 — Admin Operator/Location screen widget tests: LIFECYCLE.
//
// Bucket 5h of the 2026-05-20 test-suite tightening audit. Split out
// of the ~2,131-line `admin_operator_location_screen_test.dart`
// monolith. Covers operator + location lifecycle flows: editing the
// Account profile (success + email-conflict), onboarding a new
// operator, suspend/reactivate badge + fade, the IANA timezone add +
// edit + remove location flows, the primary-location guard, and the
// `editingEnabled: false` mutation hide.
//
// Reconciled 2026-05-24 for the Business-accounts scope-pane rebuild:
// the screen no longer auto-selects the first operator, so each test
// first picks its business in the shared left scope tree
// (`selectBusiness`) before the right detail pane (profile card,
// hierarchy panel, lifecycle buttons) is rendered. The removed
// per-business drill-in setup tiles (Timing / Support view / People /
// Access / Integrations) and the three Timing-dialog tests that opened
// them are dropped; that navigation moved to the always-on sidebar
// cluster (covered by `admin_shell_widget_test.dart`).
//
// Shared fixtures (`wrap`, `seedBundle`, `chooseTimezone`,
// `EmailConflictOperatorGateway`) and bounded pump helpers
// (`pumpEventually`) live in `admin_operator_location_test_helpers.dart`
// and `_test_helpers/widget_pump_helpers.dart`, respectively, so each
// split file imports a single source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  // The Business-accounts screen now mirrors the AI setup tabs: a left
  // searchable scope tree + a right detail pane, with NO auto-selected
  // first operator. Lifecycle tests therefore use a wide window (so the
  // split layout shows the detail pane) and pick their business in the
  // scope tree before exercising profile / location actions.
  void useWideWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> selectBusiness(
    WidgetTester tester, {
    required String operatorId,
  }) async {
    final businessRow = find.byKey(
      Key('admin_setup_scope_business_$operatorId'),
    );
    await tester.ensureVisible(businessRow);
    await pumpEventually(tester);
    await tester.tap(businessRow);
    await pumpEventually(tester);
  }

  testWidgets('Account profile action edits the business contact email', (
    tester,
  ) async {
    useWideWindow(tester);
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-profile');

    final profileAction = find.descendant(
      of: find.byKey(const Key('admin_operator_profile_card')),
      matching: find.byKey(const Key('admin_operator_edit_button')),
    );
    await tester.ensureVisible(profileAction);
    await pumpEventually(tester);
    await tester.tap(profileAction);
    await pumpEventually(tester);

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
    await pumpEventually(tester);

    final operators = await gateway.listOperators();
    expect(operators.single.operator.ownerEmail, 'contact@profile.test');
    expect(find.text('contact@profile.test'), findsWidgets);
  });

  testWidgets('Account profile conflict details show existing email usage', (
    tester,
  ) async {
    useWideWindow(tester);
    final gateway = EmailConflictOperatorGateway(
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-profile-conflict');

    final profileAction = find.descendant(
      of: find.byKey(const Key('admin_operator_profile_card')),
      matching: find.byKey(const Key('admin_operator_edit_button')),
    );
    await tester.ensureVisible(profileAction);
    await pumpEventually(tester);
    await tester.tap(profileAction);
    await pumpEventually(tester);
    await tester.enterText(
      find.byKey(const Key('admin_edit_owner_email')),
      'taken@business.test',
    );
    await tester.tap(find.byKey(const Key('admin_edit_submit_button')));
    await pumpEventually(tester);

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

  testWidgets('onboarding dialog creates a new operator end-to-end', (
    tester,
  ) async {
    useWideWindow(tester);
    final gateway = InMemoryOperatorLocationAdminGateway();
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    // "New business" lives at the top of the scope pane and is reachable
    // before any business is selected.
    await tester.tap(find.byKey(const Key('admin_operators_new_button')));
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_onboard_operator_dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_rollover_hour_dropdown')), findsNothing);
    expect(
      find.byKey(const Key('admin_onboard_legacy_rollover_readonly')),
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
    await pumpEventually(tester);

    final operators = await gateway.listOperators();
    expect(operators, hasLength(1));
    expect(operators.single.operator.businessName, equals('New Operator Inc'));
    expect(
      operators.single.locations.single.timezone,
      equals('America/Vancouver'),
    );
  });

  testWidgets('suspend then reactivate flips the badge', (tester) async {
    useWideWindow(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-active')],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-active');

    expect(find.text('suspended'), findsNothing);

    await tester.tap(find.byKey(const Key('admin_operator_suspend_button')));
    await pumpEventually(tester);
    expect(find.text('suspended'), findsWidgets);

    final reactivateButton = find.byKey(
      const Key('admin_operator_reactivate_button'),
    );
    await tester.ensureVisible(reactivateButton);
    await pumpEventually(tester);
    await tester.tap(reactivateButton);
    await pumpEventually(tester);
    expect(find.text('suspended'), findsNothing);
  });

  testWidgets('suspended operator fades the location rows', (tester) async {
    useWideWindow(tester);
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-paused');

    final fadedLocation = tester.widget<Opacity>(
      find.byKey(const Key('admin_location_suspended_fade_loc-paused')),
    );
    expect(fadedLocation.opacity, lessThan(1));

    await tester.tap(find.byKey(const Key('admin_operator_reactivate_button')));
    await pumpEventually(tester);

    final activeLocation = tester.widget<Opacity>(
      find.byKey(const Key('admin_location_suspended_fade_loc-paused')),
    );
    expect(activeLocation.opacity, equals(1));
  });

  testWidgets('add location dialog submits the selected IANA timezone', (
    tester,
  ) async {
    useWideWindow(tester);
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-seed-1');

    final addButton = find.byKey(
      const Key('admin_operator_add_location_button'),
    );
    await tester.ensureVisible(addButton);
    await pumpEventually(tester);
    await tester.tap(addButton);
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_location_add_dialog')), findsOneWidget);
    expect(find.byKey(const Key('admin_rollover_hour_dropdown')), findsNothing);
    expect(
      find.byKey(const Key('admin_location_legacy_rollover_readonly')),
      findsOneWidget,
    );
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
    await pumpEventually(tester);

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
    useWideWindow(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-seed-1');

    final editButton = find.byKey(const Key('admin_location_edit_loc-seed-1'));
    await tester.ensureVisible(editButton);
    await pumpEventually(tester);
    await tester.tap(editButton);
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_location_edit_dialog')), findsOneWidget);
    expect(find.byKey(const Key('admin_rollover_hour_dropdown')), findsNothing);
    expect(
      find.byKey(const Key('admin_location_legacy_rollover_readonly')),
      findsOneWidget,
    );

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
    await pumpEventually(tester);

    final operators = await gateway.listOperators();
    final location = operators.single.locations.single;
    expect(location.name, equals('Harbour HQ'));
    expect(location.timezone, equals('America/St_Johns'));
    expect(find.text('Harbour HQ'), findsWidgets);
  });

  testWidgets('remove button is disabled on the primary location', (
    tester,
  ) async {
    useWideWindow(tester);
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-x');

    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('admin_location_remove_loc-x')),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('editingEnabled false hides operator and location mutations', (
    tester,
  ) async {
    useWideWindow(tester);
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(gateway: gateway, editingEnabled: false),
      ),
    );
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-seed-1');

    expect(
      find.byKey(const Key('admin_operators_readonly_banner')),
      findsOneWidget,
    );
    // "New business" onboarding is hidden in read-only mode (the scope
    // pane omits its header button).
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
  });

  testWidgets('add and then remove a non-primary location', (tester) async {
    useWideWindow(tester);
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
    await pumpEventually(tester);
    await selectBusiness(tester, operatorId: 'op-rem');

    // Add a second location through the dialog.
    final addButton = find.byKey(
      const Key('admin_operator_add_location_button'),
    );
    await tester.ensureVisible(addButton);
    await pumpEventually(tester);
    await tester.tap(addButton);
    await pumpEventually(tester);
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
    await pumpEventually(tester);

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
    await pumpEventually(tester);
    await tester.tap(removeButton);
    await pumpEventually(tester);
    expect(find.byKey(const Key('admin_confirm_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_confirm_confirm_button')));
    await pumpEventually(tester);

    final after = await gateway.listOperators();
    expect(after.single.locations, hasLength(1));
    expect(after.single.locations.single.name, equals('HQ'));
  });
}
