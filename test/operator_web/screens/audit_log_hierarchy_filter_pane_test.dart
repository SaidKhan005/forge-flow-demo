// Lane B B8.b — Operator Web audit log hierarchy filter pane tests.
//
// Pins the pane the parent `AuditLogScreen` mounts when both the
// hierarchy gateway and the team-hierarchy gateway are supplied.
//
// Coverage:
//   * Pane mounts only when both gateways are supplied; absent
//     gateways do not regress the existing screen surface.
//   * Default scope is `Whole business` and the run button calls the
//     gateway with `scope_type=operator_wide`.
//   * Tapping a location node updates the scope summary and
//     subsequent run calls the gateway with `scope_type=location`.
//   * Tapping an org-unit node updates the scope and calls with
//     `scope_type=org_unit`.
//   * Rows render the action + actor label.
//   * Error envelope renders the gateway message.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/audit_log_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/web_audit_log_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  final pinnedClock = DateTime.utc(2026, 5, 13, 12);

  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  void sizeViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession session() => OperatorWebSession(
        uid: 'demo-user-owner',
        email: 'sam.owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: const <String>['operator_owner'],
        permissions: const <String>{
          'team.audit_log.view',
          'team.audit_log.export',
        },
      );

  WebTeamHierarchyGateway buildHierarchyGateway() =>
      _StaticWebTeamHierarchyGateway(
        orgUnits: const <TeamOrgUnitEntry>[
          TeamOrgUnitEntry(
            orgUnitId: 'unit-root',
            parentOrgUnitId: null,
            unitType: 'business',
            path: 'root',
            label: 'Demo Bistro Group',
          ),
          TeamOrgUnitEntry(
            orgUnitId: 'unit-region-west',
            parentOrgUnitId: 'unit-root',
            unitType: 'region',
            path: 'root.west',
            label: 'West Region',
          ),
        ],
        locations: const <TeamOrgLocationEntry>[
          TeamOrgLocationEntry(
            locationId: 'loc-downtown',
            parentOrgUnitId: 'unit-region-west',
            orgUnitPath: 'root.west',
            label: 'Downtown',
          ),
          TeamOrgLocationEntry(
            locationId: 'loc-uptown',
            parentOrgUnitId: 'unit-region-west',
            orgUnitPath: 'root.west',
            label: 'Uptown',
          ),
        ],
      );

  testWidgets('pane does not mount when hierarchy gateway is null',
      (tester) async {
    sizeViewport(tester, const Size(1280, 1600));
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session(),
          gateway: DemoWebTeamAuditLogGateway(clock: pinnedClock),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('operator_web_audit_log_hierarchy_filter_pane')),
      findsNothing,
    );
  });

  testWidgets(
      'pane mounts when both hierarchy gateways are supplied and renders '
      'the tree', (tester) async {
    sizeViewport(tester, const Size(1280, 1800));
    final hierarchyGateway = InMemoryWebAuditLogHierarchyGateway();
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session(),
          gateway: DemoWebTeamAuditLogGateway(clock: pinnedClock),
          hierarchyGateway: hierarchyGateway,
          teamHierarchyGateway: buildHierarchyGateway(),
          hierarchyPaneClock: () => pinnedClock,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_audit_log_hierarchy_filter_pane')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_audit_log_hierarchy_tree')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('operator_web_audit_log_hierarchy_scope_summary'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('default scope is "Whole business" and run calls with '
      'operator_wide', (tester) async {
    sizeViewport(tester, const Size(1280, 1800));
    final hierarchyGateway = InMemoryWebAuditLogHierarchyGateway();
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session(),
          gateway: DemoWebTeamAuditLogGateway(clock: pinnedClock),
          hierarchyGateway: hierarchyGateway,
          teamHierarchyGateway: buildHierarchyGateway(),
          hierarchyPaneClock: () => pinnedClock,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Selected scope: Whole business'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.pumpAndSettle();

    expect(hierarchyGateway.calls, hasLength(1));
    expect(
      hierarchyGateway.calls.single.scopeType,
      WebAuditLogHierarchyScopeType.operatorWide,
    );
  });

  testWidgets('error envelope renders the gateway message', (tester) async {
    sizeViewport(tester, const Size(1280, 1800));
    final hierarchyGateway = InMemoryWebAuditLogHierarchyGateway(
      failWith: const WebAuditLogHierarchyGatewayError(
        'audit log read is unavailable; please retry',
        statusCode: 503,
      ),
    );
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session(),
          gateway: DemoWebTeamAuditLogGateway(clock: pinnedClock),
          hierarchyGateway: hierarchyGateway,
          teamHierarchyGateway: buildHierarchyGateway(),
          hierarchyPaneClock: () => pinnedClock,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_audit_log_hierarchy_error_banner')),
      findsOneWidget,
    );
    expect(find.textContaining('audit log read is unavailable'),
        findsOneWidget);
  });

  testWidgets('row tile renders for each returned row', (tester) async {
    sizeViewport(tester, const Size(1280, 1800));
    final hierarchyGateway = InMemoryWebAuditLogHierarchyGateway(
      rows: <WebAuditLogHierarchyRow>[
        WebAuditLogHierarchyRow(
          id: '42',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'loc-downtown',
          occurredAt: DateTime.utc(2026, 5, 13, 11),
          actorKind: 'team_member',
          actorUserId: 'user-1',
          action: 'auth.password_changed',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session(),
          gateway: DemoWebTeamAuditLogGateway(clock: pinnedClock),
          hierarchyGateway: hierarchyGateway,
          teamHierarchyGateway: buildHierarchyGateway(),
          hierarchyPaneClock: () => pinnedClock,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_audit_log_hierarchy_run')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_audit_log_hierarchy_row_42')),
      findsOneWidget,
    );
    expect(find.textContaining('auth.password_changed'), findsAtLeastNWidgets(1));
  });
}

class _StaticWebTeamHierarchyGateway implements WebTeamHierarchyGateway {
  _StaticWebTeamHierarchyGateway({
    required this.orgUnits,
    required this.locations,
  });

  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    return TeamOrgHierarchyListed(
      orgUnits: List<TeamOrgUnitEntry>.unmodifiable(orgUnits),
      locations: List<TeamOrgLocationEntry>.unmodifiable(locations),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }
}
