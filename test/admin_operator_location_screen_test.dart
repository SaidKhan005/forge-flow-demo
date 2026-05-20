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
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_business_accounts_back_button.dart';
import 'package:forge_and_flow/admin/widgets/admin_responsive_layout.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '_test_helpers/widget_pump_helpers.dart';

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

  // Fix #4 / S4 (G42): seed the READ-ONLY admin business-timing
  // resolution gateway with a real canonical-shaped candidate chain
  // so the per-location Timing dialog renders the REAL resolved
  // `EffectiveBusinessTimingProfile` (replacing the deleted synthetic
  // `_AdminTimingResolution.forScope` fabrication).
  InMemoryAdminBusinessTimingResolutionGateway seedTimingGateway({
    required String operatorId,
    required String locationId,
    String timezone = 'America/Toronto',
    String dayStart = '04:00',
    String weekStart = 'monday',
    List<AdminResolutionServicePeriod>? periods,
  }) {
    final gw = InMemoryAdminBusinessTimingResolutionGateway();
    gw.put(
      operatorId,
      locationId,
      AdminBusinessTimingResolution(
        operatorId: operatorId,
        locationId: locationId,
        businessDate: '2026-05-01',
        ianaTimezone: timezone,
        candidates: <AdminResolutionCandidate>[
          AdminResolutionCandidate(
            profileId: '$operatorId-default',
            scopeType: 'operator',
            scopeId: operatorId,
            scopeLabel: 'Operator default',
            scopeDepthRank: 0,
            ianaTimezone: timezone,
            effectiveAtBusinessDate: '2026-05-01',
            weekStartDay: weekStart,
            businessDayStartLocal: dayStart,
            servicePeriods:
                periods ??
                <AdminResolutionServicePeriod>[
                  const AdminResolutionServicePeriod(
                    key: 'lunch',
                    label: 'Lunch',
                    startLocal: '11:00',
                    endLocal: '16:00',
                    rollsPastMidnight: false,
                    shortLabel: 'L',
                    sortOrder: 1,
                    applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                  ),
                  const AdminResolutionServicePeriod(
                    key: 'dinner',
                    label: 'Dinner',
                    startLocal: '16:00',
                    endLocal: '22:00',
                    rollsPastMidnight: false,
                    shortLabel: 'D',
                    sortOrder: 2,
                    applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                  ),
                ],
          ),
        ],
      ),
    );
    return gw;
  }

  Future<void> chooseTimezone(
    WidgetTester tester,
    Key fieldKey,
    String timezone,
  ) async {
    final field = find.byKey(fieldKey);
    await tester.ensureVisible(field);
    await pumpEventually(tester);
    await tester.tap(field);
    await pumpEventually(tester);

    await tester.enterText(
      find.byKey(const Key('admin_timezone_search_field')),
      timezone,
    );
    await pumpEventually(tester);

    final option = find.byKey(Key('admin_timezone_option_text_$timezone'));
    await tester.tap(option);
    await pumpEventually(tester);
  }

  Future<void> chooseScopePrompt(
    WidgetTester tester, {
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
  }) async {
    if (find
        .byKey(const Key('admin_hierarchy_scope_prompt'))
        .evaluate()
        .isEmpty) {
      return;
    }
    final cacheKey =
        '$operatorId|$scopeType|${orgUnitId ?? ''}|${locationId ?? ''}';
    final option = find.byKey(Key('admin_hierarchy_scope_option_$cacheKey'));
    await tester.ensureVisible(option);
    await pumpEventually(tester);
    await tester.tap(option);
    await pumpEventually(tester);
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
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_manage_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_manage_op-2')), findsNothing);
    expect(find.text('Click to manage'), findsNothing);
    expect(
      find.text(
        'Start with the business, then move into setup, locations, team, access, audit, and data controls.',
      ),
      findsNothing,
    );
    final newBusinessSize = tester.getSize(
      find.byKey(const Key('admin_operators_new_button')),
    );
    expect(newBusinessSize.width, greaterThanOrEqualTo(168));
    expect(newBusinessSize.height, greaterThanOrEqualTo(50));
    final profileCard = find.byKey(const Key('admin_operator_profile_card'));
    expect(
      find.descendant(of: profileCard, matching: find.text('Account profile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_business_setup_tile_account_profile')),
      findsNothing,
    );
    final setupCard = find.byKey(const Key('admin_business_setup_op-1'));
    expect(
      find.descendant(
        of: setupCard,
        matching: find.text('Selected business scope'),
      ),
      findsOneWidget,
    );
    for (final noisyLabel in <String>[
      'Ready',
      'Needs details',
      'Review',
      'Location required',
      'Business default',
      'Inherited',
      'Effective: Business default',
      'Editable',
      'Set at this scope',
    ]) {
      expect(
        find.descendant(of: setupCard, matching: find.text(noisyLabel)),
        findsNothing,
      );
    }
    final operationsGroup = find.byKey(
      const Key('admin_business_setup_group_operations'),
    );
    expect(operationsGroup, findsOneWidget);
    for (final label in <String>[
      'Integrations',
      'Covers and Wage Data Accuracy',
      'Timing',
    ]) {
      expect(
        find.descendant(of: operationsGroup, matching: find.text(label)),
        findsOneWidget,
      );
    }
    final peopleGroup = find.byKey(
      const Key('admin_business_setup_group_people'),
    );
    expect(
      find.descendant(
        of: peopleGroup,
        matching: find.text('People, access, and roles'),
      ),
      findsOneWidget,
    );
    final safetyGroup = find.byKey(
      const Key('admin_business_setup_group_safety_support'),
    );
    expect(
      find.descendant(
        of: safetyGroup,
        matching: find.text('Security, audit, and sessions'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: safetyGroup, matching: find.text('Support logs')),
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
    await pumpEventually(tester);

    final supportLogsTile = find.byKey(
      const Key('admin_business_setup_tile_support_logs'),
    );
    await tester.ensureVisible(supportLogsTile);
    await pumpEventually(tester);
    await tester.tap(supportLogsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-support',
      scopeType: 'business',
    );
    expect(supportLogRequests, hasLength(1));
    expect(supportLogRequests.single, <String?>['op-support', null]);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-support'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);
    await tester.ensureVisible(supportLogsTile);
    await pumpEventually(tester);
    await tester.tap(supportLogsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-support',
      scopeType: 'location',
      locationId: 'loc-support',
    );
    expect(supportLogRequests, hasLength(2));
    expect(supportLogRequests.last, <String?>['op-support', 'loc-support']);
  });

  testWidgets('setup tiles offer business, org-unit, and location scope', (
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
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-workspace': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Workspace root',
            operatorId: 'op-workspace',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-workspace': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-workspace',
            name: 'HQ',
            operatorId: 'op-workspace',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          onOpenPeopleAccessRolesScope: scopes.add,
        ),
      ),
    );
    await pumpEventually(tester);

    final peopleTile = find.byKey(
      const Key('admin_business_setup_tile_people_access_roles'),
    );
    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-workspace',
      scopeType: 'business',
    );
    expect(scopes, hasLength(1));
    expect(scopes.single.operatorId, 'op-workspace');
    expect(scopes.single.scopeType, AdminHierarchyScopeType.business);
    expect(scopes.single.locationId, isNull);
    expect(scopes.single.operatorName, 'Workspace Cafe');

    final orgUnitRow = find.byKey(
      const Key('admin_hierarchy_org_unit_org-root'),
    );
    await tester.ensureVisible(orgUnitRow);
    await pumpEventually(tester);
    await tester.tapAt(tester.getTopLeft(orgUnitRow) + const Offset(24, 24));
    await pumpEventually(tester);

    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-workspace',
      scopeType: 'org_unit',
      orgUnitId: 'org-root',
    );
    expect(scopes, hasLength(2));
    expect(scopes.last.operatorId, 'op-workspace');
    expect(scopes.last.scopeType, AdminHierarchyScopeType.orgUnit);
    expect(scopes.last.orgUnitId, 'org-root');
    expect(scopes.last.orgUnitName, 'Workspace root');

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-workspace'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);
    await tester.ensureVisible(peopleTile);
    await pumpEventually(tester);
    await tester.tap(peopleTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-workspace',
      scopeType: 'location',
      orgUnitId: 'org-root',
      locationId: 'loc-workspace',
    );
    expect(scopes, hasLength(3));
    expect(scopes.last.operatorId, 'op-workspace');
    expect(scopes.last.scopeType, AdminHierarchyScopeType.location);
    expect(scopes.last.locationId, 'loc-workspace');
    expect(scopes.last.operatorName, 'Workspace Cafe');
    expect(scopes.last.orgUnitId, 'org-root');
    expect(scopes.last.orgUnitName, 'Workspace root');
    expect(scopes.last.locationName, 'HQ');
  });

  testWidgets('Account profile action edits the business contact email', (
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
    await pumpEventually(tester);

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
    await pumpEventually(tester);

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
    final timingGw = seedTimingGateway(
      operatorId: 'op-timing',
      locationId: 'loc-timing',
      timezone: 'America/Toronto',
      dayStart: '04:00',
      weekStart: 'monday',
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          timingResolutionGateway: timingGw,
        ),
      ),
    );
    await pumpEventually(tester);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-timing'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);

    final timingTile = find.byKey(
      const Key('admin_business_setup_tile_timing'),
    );
    await tester.ensureVisible(timingTile);
    await pumpEventually(tester);
    await tester.tap(timingTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-timing',
      scopeType: 'location',
      locationId: 'loc-timing',
    );
    // The resolved body is a FutureBuilder over the READ-ONLY S2
    // admin gateway; let it complete.
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_location_timing_dialog')),
      findsOneWidget,
    );
    expect(find.text('Timing Cafe / HQ'), findsWidgets);
    // REAL resolved values from the seeded canonical chain (no longer
    // the deleted synthetic `_AdminTimingResolution.forScope` path).
    expect(
      find.byKey(const Key('admin_timing_resolved_fields')),
      findsOneWidget,
    );
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
    expect(find.text('Timezone source'), findsOneWidget);
    // Provenance is the resolver's resolved scope (operator-only chain
    // => "Inherited (Operator default)"), NOT a synthetic scope flag.
    expect(find.text('Inherited (Operator default)'), findsWidgets);
    expect(
      find.byKey(const Key('admin_timing_service_periods_panel')),
      findsOneWidget,
    );
  });

  testWidgets('business Timing action shows inherited timing provenance', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        seedBundle(
          operatorId: 'op-business-timing',
          primaryLocationId: 'loc-business-timing',
          businessName: 'Business Timing Cafe',
        ),
      ],
    );
    // At business scope the dialog resolves timing for the primary
    // location; seed the canonical chain under that location id.
    final timingGw = seedTimingGateway(
      operatorId: 'op-business-timing',
      locationId: 'loc-business-timing',
      timezone: 'America/Toronto',
      dayStart: '04:00',
      weekStart: 'monday',
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          timingResolutionGateway: timingGw,
        ),
      ),
    );
    await pumpEventually(tester);

    final timingTile = find.byKey(
      const Key('admin_business_setup_tile_timing'),
    );
    await tester.ensureVisible(timingTile);
    await pumpEventually(tester);
    await tester.tap(timingTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-business-timing',
      scopeType: 'business',
    );
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_location_timing_dialog')),
      findsOneWidget,
    );
    expect(find.text('Showing timing for business scope'), findsOneWidget);
    // REAL resolved values from the seeded canonical chain.
    expect(
      find.byKey(const Key('admin_timing_resolved_fields')),
      findsOneWidget,
    );
    expect(find.text('Effective timezone'), findsOneWidget);
    expect(find.text('America/Toronto'), findsOneWidget);
    expect(find.text('Business day starts'), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
    expect(find.text('Week starts'), findsOneWidget);
    expect(find.text('Monday'), findsOneWidget);
    expect(find.text('Week-start source'), findsOneWidget);
    expect(find.text('Effective service periods'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    // Operator-only seeded chain => provenance is the resolver's
    // resolved scope, not a synthetic "Set at this scope" flag.
    expect(find.text('Inherited (Operator default)'), findsWidgets);
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
      final timingGw = seedTimingGateway(
        operatorId: 'op-timing-readonly',
        locationId: 'loc-timing-readonly',
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            editingEnabled: false,
            timingResolutionGateway: timingGw,
          ),
        ),
      );
      await pumpEventually(tester);

      final locationRow = find.byKey(
        const Key('admin_hierarchy_location_loc-timing-readonly'),
      );
      await tester.ensureVisible(locationRow);
      await pumpEventually(tester);
      await tester.tap(locationRow);
      await pumpEventually(tester);

      final timingTile = find.byKey(
        const Key('admin_business_setup_tile_timing'),
      );
      await tester.ensureVisible(timingTile);
      await pumpEventually(tester);
      await tester.tap(timingTile);
      await pumpEventually(tester);
      await chooseScopePrompt(
        tester,
        operatorId: 'op-timing-readonly',
        scopeType: 'location',
        locationId: 'loc-timing-readonly',
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_location_timing_dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Read-only support view'), findsOneWidget);
      // Read-only-accurate (operator decision Q3): values are REAL
      // and resolved, but NO write/edit affordance is added.
      expect(
        find.byKey(const Key('admin_timing_resolved_fields')),
        findsOneWidget,
      );
      expect(find.text('America/Toronto'), findsOneWidget);
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
    await pumpEventually(tester);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'beta',
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsNothing);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'toronto',
    );
    await pumpEventually(tester);

    expect(find.byKey(const Key('admin_operator_row_op-1')), findsOneWidget);
    expect(find.byKey(const Key('admin_operator_row_op-2')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_operators_search_field')),
      'zzzz',
    );
    await pumpEventually(tester);

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
    await pumpEventually(tester);

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
    await pumpEventually(tester);

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
    await pumpEventually(tester);

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
    expect(find.text('New Operator Inc'), findsWidgets);
  });

  testWidgets('suspend then reactivate flips the badge', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle(operatorId: 'op-active')],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

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

  testWidgets('operator AI plan selection is read-only while coming soon', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

    expect(find.text('Forge & Flow AI plan'), findsOneWidget);
    final detailRow = tester.widget<AdminDetailRow>(
      find.byKey(const Key('admin_operator_ai_plan_detail_row')),
    );
    expect(detailRow.muted, isTrue);

    await tester.tap(find.byKey(const Key('admin_operator_edit_button')));
    await pumpEventually(tester);

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
    await pumpEventually(tester);

    final addButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('admin_operator_add_location_button')),
    );
    expect(addButton.onPressed, isNull);
    expect(
      find.byKey(const Key('admin_location_parent_org_unit_required_copy')),
      findsOneWidget,
    );
  });

  testWidgets('business hierarchy manager creates a child org unit', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': <OrgUnitAdminNode>[
          const OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': <HierarchyLocationLeaf>[
          const HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-add-child',
        ),
      ),
    );
    await pumpEventually(tester);

    final addChild = find.byKey(
      const Key('admin_hierarchy_org_unit_add_child_org-root'),
    );
    await tester.ensureVisible(addChild);
    await pumpEventually(tester);
    await tester.tap(addChild);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_add_child_org_unit_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_hierarchy_add_org_unit_label')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_add_org_unit_name')),
      'North district',
    );
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_add_org_unit_reason')),
      'operator requested hierarchy setup',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_add_org_unit_submit')),
    );
    await pumpEventually(tester);

    expect(find.text('North district'), findsOneWidget);
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.org_unit.create'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('operator requested hierarchy setup'));
    expect(event.payload['parent_org_unit_id'], equals('org-root'));
  });

  testWidgets('business hierarchy manager moves a location with a reason', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-north',
            name: 'North district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-root',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-move-location',
        ),
      ),
    );
    await pumpEventually(tester);

    final moveButton = find.byKey(const Key('admin_location_move_loc-seed-1'));
    await tester.ensureVisible(moveButton);
    await pumpEventually(tester);
    await tester.tap(moveButton);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_move_location_dialog')),
      findsOneWidget,
    );
    expect(find.text('Demo Diner Co. / North district'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_move_location_reason')),
      'move hq under the north district',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_move_location_submit')),
    );
    await pumpEventually(tester);

    final moved = (await hierarchyGateway.listHierarchyLocations(
      operatorId: 'op-seed-1',
    )).single;
    expect(moved.orgUnitId, equals('org-north'));
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.location.move'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('move hq under the north district'));
    expect(event.payload['org_unit_id'], isA<Map<String, Object?>>());
  });

  testWidgets('business hierarchy manager moves an org unit with a reason', (
    tester,
  ) async {
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
        'op-seed-1': const <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'org-root',
            name: 'Demo Diner Co.',
            operatorId: 'op-seed-1',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-east',
            name: 'East district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-downtown',
            name: 'Downtown group',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-east',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'org-west',
            name: 'West district',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-seed-1': const <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-seed-1',
            name: 'HQ',
            operatorId: 'op-seed-1',
            orgUnitId: 'org-east',
          ),
        ],
      },
    );
    await tester.pumpWidget(
      wrap(
        OperatorLocationAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          actorUserId: 'demo-super-admin',
          idempotencyKeyFactory: () => 'idem-business-hierarchy-move-org-unit',
        ),
      ),
    );
    await pumpEventually(tester);

    final rootMoveButton = tester.widget<IconButton>(
      find.byKey(const Key('admin_hierarchy_org_unit_move_org-root')),
    );
    expect(rootMoveButton.onPressed, isNull);

    final moveButton = find.byKey(
      const Key('admin_hierarchy_org_unit_move_org-east'),
    );
    await tester.ensureVisible(moveButton);
    await pumpEventually(tester);
    await tester.tap(moveButton);
    await pumpEventually(tester);

    expect(
      find.byKey(const Key('admin_hierarchy_move_org_unit_dialog')),
      findsOneWidget,
    );
    expect(find.text('Demo Diner Co. / West district'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('admin_hierarchy_move_org_unit_reason')),
      'rebalance the district reporting line',
    );
    await tester.tap(
      find.byKey(const Key('admin_hierarchy_move_org_unit_submit')),
    );
    await pumpEventually(tester);

    final moved = (await hierarchyGateway.listOrgUnits(
      operatorId: 'op-seed-1',
    )).singleWhere((unit) => unit.orgUnitId == 'org-east');
    expect(moved.parentOrgUnitId, equals('org-west'));
    final event = hierarchyGateway.capturedAuditEvents.single;
    expect(event.action, equals('team.org_unit.move'));
    expect(event.actorUserId, equals('demo-super-admin'));
    expect(event.adminReason, equals('rebalance the district reporting line'));
    expect(event.payload['parent_org_unit_id'], isA<Map<String, Object?>>());
  });

  testWidgets(
    'business hierarchy manager suspends reactivates and deletes org units',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
            OrgUnitAdminNode(
              orgUnitId: 'org-east',
              name: 'East district',
              operatorId: 'op-seed-1',
              parentOrgUnitId: 'org-root',
            ),
            OrgUnitAdminNode(
              orgUnitId: 'org-empty',
              name: 'Empty district',
              operatorId: 'op-seed-1',
              parentOrgUnitId: 'org-root',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-seed-1',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-east',
            ),
          ],
        },
      );
      var idempotency = 0;
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () => 'idem-org-lifecycle-${idempotency++}',
          ),
        ),
      );
      await pumpEventually(tester);

      final rootSuspend = tester.widget<IconButton>(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_org-root')),
      );
      expect(rootSuspend.onPressed, isNull);

      final suspendButton = find.byKey(
        const Key('admin_hierarchy_org_unit_suspend_org-east'),
      );
      await tester.ensureVisible(suspendButton);
      await pumpEventually(tester);
      await tester.tap(suspendButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_reason')),
        'district temporarily paused by admin',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_suspend_submit')),
      );
      await pumpEventually(tester);

      expect(find.text('Suspended branch'), findsOneWidget);
      final suspended = (await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      )).singleWhere((unit) => unit.orgUnitId == 'org-east');
      expect(suspended.isSuspended, isTrue);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.suspend'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('district temporarily paused by admin'),
      );

      final reactivateButton = find.byKey(
        const Key('admin_hierarchy_org_unit_reactivate_org-east'),
      );
      await tester.ensureVisible(reactivateButton);
      await pumpEventually(tester);
      await tester.tap(reactivateButton);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_reactivate_reason')),
        'district ready for use again',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_reactivate_submit')),
      );
      await pumpEventually(tester);

      final reactivated = (await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      )).singleWhere((unit) => unit.orgUnitId == 'org-east');
      expect(reactivated.isSuspended, isFalse);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.reactivate'),
      );

      final deleteButton = find.byKey(
        const Key('admin_hierarchy_org_unit_delete_org-empty'),
      );
      await tester.ensureVisible(deleteButton);
      await pumpEventually(tester);
      await tester.tap(deleteButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_reason')),
        'empty district created in error',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_org_unit_delete_submit')),
      );
      await pumpEventually(tester);

      final units = await hierarchyGateway.listOrgUnits(
        operatorId: 'op-seed-1',
      );
      expect(units.any((unit) => unit.orgUnitId == 'org-empty'), isFalse);
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_org-empty')),
        findsNothing,
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.org_unit.delete'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('empty district created in error'),
      );
    },
  );

  testWidgets(
    'business hierarchy manager suspends reactivates and deletes locations',
    (tester) async {
      final created = DateTime.utc(2026, 1, 1);
      final bundle = OperatorAdminBundle(
        operator: OperatorAdminRecord(
          operatorId: 'op-seed-1',
          businessName: 'Seed Cafe',
          ownerEmail: 'owner@seed.test',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationId: 'loc-primary',
          suspendedAt: null,
          createdAt: created,
          updatedAt: created,
        ),
        locations: <LocationAdminRecord>[
          LocationAdminRecord(
            locationId: 'loc-primary',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'HQ',
            address: '',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
          LocationAdminRecord(
            locationId: 'loc-west',
            operatorId: 'op-seed-1',
            parentOrgUnitId: 'org-root',
            name: 'West Coast',
            address: '',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 4,
            createdAt: created,
            updatedAt: created,
          ),
        ],
      );
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[bundle],
      );
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-seed-1': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Demo Diner Co.',
              operatorId: 'op-seed-1',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-seed-1': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-primary',
              name: 'HQ',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
            HierarchyLocationLeaf(
              locationId: 'loc-west',
              name: 'West Coast',
              operatorId: 'op-seed-1',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      var idempotency = 0;
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
            idempotencyKeyFactory: () =>
                'idem-location-lifecycle-${idempotency++}',
          ),
        ),
      );
      await pumpEventually(tester);

      final primaryDelete = tester.widget<IconButton>(
        find.byKey(const Key('admin_location_remove_loc-primary')),
      );
      expect(primaryDelete.onPressed, isNull);

      final suspendButton = find.byKey(
        const Key('admin_location_suspend_loc-west'),
      );
      await tester.ensureVisible(suspendButton);
      await pumpEventually(tester);
      await tester.tap(suspendButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_location_suspend_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_suspend_reason')),
        'seasonal closure requested',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_suspend_submit')),
      );
      await pumpEventually(tester);

      expect(find.text('Suspended location'), findsOneWidget);
      final suspended = (await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      )).singleWhere((location) => location.locationId == 'loc-west');
      expect(suspended.isSuspended, isTrue);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.suspend'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('seasonal closure requested'),
      );

      final reactivateButton = find.byKey(
        const Key('admin_location_reactivate_loc-west'),
      );
      await tester.ensureVisible(reactivateButton);
      await pumpEventually(tester);
      await tester.tap(reactivateButton);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_reactivate_reason')),
        'location reopened',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_reactivate_submit')),
      );
      await pumpEventually(tester);

      final reactivated = (await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      )).singleWhere((location) => location.locationId == 'loc-west');
      expect(reactivated.isSuspended, isFalse);
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.reactivate'),
      );

      final deleteButton = find.byKey(
        const Key('admin_location_remove_loc-west'),
      );
      await tester.ensureVisible(deleteButton);
      await pumpEventually(tester);
      await tester.tap(deleteButton);
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_hierarchy_location_delete_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_hierarchy_location_delete_reason')),
        'duplicate location record',
      );
      await tester.tap(
        find.byKey(const Key('admin_hierarchy_location_delete_submit')),
      );
      await pumpEventually(tester);

      final locations = await hierarchyGateway.listHierarchyLocations(
        operatorId: 'op-seed-1',
      );
      expect(
        locations.any((location) => location.locationId == 'loc-west'),
        isFalse,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_location_loc-west')),
        findsNothing,
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.action,
        equals('team.location.delete'),
      );
      expect(
        hierarchyGateway.capturedAuditEvents.last.adminReason,
        equals('duplicate location record'),
      );
    },
  );

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
    await pumpEventually(tester);

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
    final gateway = InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[seedBundle()],
    );
    await tester.pumpWidget(
      wrap(OperatorLocationAdminScreen(gateway: gateway)),
    );
    await pumpEventually(tester);

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
    await pumpEventually(tester);

    final locationRow = find.byKey(
      const Key('admin_hierarchy_location_loc-seed-1'),
    );
    await tester.ensureVisible(locationRow);
    await pumpEventually(tester);
    await tester.tap(locationRow);
    await pumpEventually(tester);

    final integrationsTile = find.byKey(
      const Key('admin_business_setup_tile_integrations'),
    );
    await tester.ensureVisible(integrationsTile);
    await pumpEventually(tester);

    expect(integrationsTile, findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);

    await tester.tap(integrationsTile);
    await pumpEventually(tester);
    await chooseScopePrompt(
      tester,
      operatorId: 'op-seed-1',
      scopeType: 'location',
      locationId: 'loc-seed-1',
    );

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
  });

  testWidgets(
    'business Integrations tile requires a location and then mounts live gateway',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(
            operatorId: 'op-integrations',
            primaryLocationId: 'loc-integrations',
            businessName: 'Integrations Cafe',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            vendorConnectionsGateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await pumpEventually(tester);

      final integrationsTile = find.byKey(
        const Key('admin_business_setup_tile_integrations'),
      );
      await tester.ensureVisible(integrationsTile);
      await pumpEventually(tester);
      await tester.tap(integrationsTile);
      await pumpEventually(tester);
      await chooseScopePrompt(
        tester,
        operatorId: 'op-integrations',
        scopeType: 'business',
      );

      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );

      await tester.tap(find.byKey(kAdminBusinessAccountsBackButtonKey));
      await pumpEventually(tester);

      final locationRow = find.byKey(
        const Key('admin_hierarchy_location_loc-integrations'),
      );
      await tester.ensureVisible(locationRow);
      await pumpEventually(tester);
      await tester.tap(locationRow);
      await pumpEventually(tester);
      await tester.ensureVisible(integrationsTile);
      await pumpEventually(tester);
      await tester.tap(integrationsTile);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );

      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsOneWidget,
      );
    },
  );

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
    await pumpEventually(tester);

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
    await pumpEventually(tester);

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

  testWidgets('non-admin user is blocked by the admin auth gate', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);
    await tester.pumpWidget(AdminConsoleApp(authSource: source));
    await pumpEventually(tester);

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
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
      await pumpEventually(tester);

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
    await pumpEventually(tester);

    await tester.tap(find.byKey(const Key('admin_nav_item_operators')));
    await pumpEventually(tester);

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
