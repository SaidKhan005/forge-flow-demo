// GAP B2 — Wage authority screen: HP #11 scope selector + per-row
// inherited-vs-set-at-scope badge rendering.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/wage_authority_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/hierarchy_map_picker.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  final ts = DateTime.utc(2026, 5, 16);

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession session(List<String> roles) => OperatorWebSession(
    uid: 'u',
    email: 'a@b.com',
    displayName: 'Alex',
    operatorId: 'op-a',
    businessName: 'Brio',
    primaryLocationId: 'loc-harbour',
    primaryLocationName: 'Harbour',
    roles: roles,
    mfaEnrolled: false,
  );

  WageRoleRowRecord rec({
    required String id,
    required String scopeType,
    required String locationId,
    String roleName = 'Server',
    String laborBucket = 'foh',
    required double hourlyRate,
  }) => WageRoleRowRecord(
    wageRoleRowId: id,
    operatorId: 'op-a',
    locationId: locationId,
    restaurantId: 'rest-a',
    roleName: roleName,
    laborBucket: laborBucket,
    hourlyRate: hourlyRate,
    weightedHours: 40,
    source: WageRoleRowSource.adminSeed,
    isActive: true,
    effectiveAt: ts,
    metadata: const <String, Object?>{},
    createdAt: ts,
    updatedAt: ts,
    scopeType: scopeType,
  );

  const nodes = <HierarchyMapNode>[
    HierarchyMapNode(
      id: 'business:op-a',
      label: 'Brio',
      helper: 'Whole business',
      kind: HierarchyMapNodeKind.business,
    ),
    HierarchyMapNode(
      id: 'location:loc-harbour',
      label: 'Harbour',
      helper: 'Location',
      kind: HierarchyMapNodeKind.location,
      parentId: 'business:op-a',
    ),
  ];

  testWidgets('inherited Business rate renders the "Inherited from the whole '
      'business" badge', (tester) async {
    await sizeViewport(tester);
    final gateway = OperatorWebDemoWageAuthorityGateway(
      initial: <WageRoleRowRecord>[
        rec(
          id: 'biz-server',
          scopeType: 'operator_wide',
          locationId: 'loc-harbour',
          hourlyRate: 16.50,
        ),
      ],
    );

    await tester.pumpWidget(
      wrap(
        WageAuthorityScreen(
          session: session(<String>['operator_owner']),
          locationId: 'loc-harbour',
          locationName: 'Harbour',
          gateway: gateway,
          hierarchyNodes: nodes,
          ancestorOrgUnitIdsNearestFirst: const <String>[],
          businessName: 'Brio',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final badge = find.byKey(
      const Key('wage_authority_row_scope_badge_biz-server'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
        of: badge,
        matching: find.text('Inherited from the whole business'),
      ),
      findsOneWidget,
    );
    // The misleading old screen-level "coming in a later wave" notice
    // is gone.
    expect(
      find.byKey(const Key('wage_authority_hierarchy_scope')),
      findsNothing,
    );
    // The scope selector is present (multi-node hierarchy).
    expect(
      find.byKey(const Key('wage_authority_scope_editor')),
      findsOneWidget,
    );
  });

  testWidgets('location-owned rate renders "Set at this location"', (
    tester,
  ) async {
    await sizeViewport(tester);
    final gateway = OperatorWebDemoWageAuthorityGateway(
      initial: <WageRoleRowRecord>[
        rec(
          id: 'loc-server',
          scopeType: 'location',
          locationId: 'loc-harbour',
          hourlyRate: 19.25,
        ),
      ],
    );

    await tester.pumpWidget(
      wrap(
        WageAuthorityScreen(
          session: session(<String>['operator_owner']),
          locationId: 'loc-harbour',
          locationName: 'Harbour',
          gateway: gateway,
          hierarchyNodes: nodes,
          ancestorOrgUnitIdsNearestFirst: const <String>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final badge = find.byKey(
      const Key('wage_authority_row_scope_badge_loc-server'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('Set at this location')),
      findsOneWidget,
    );
  });

  testWidgets(
    'location override hides shadowed Business row for the same role',
    (tester) async {
      await sizeViewport(tester);
      final gateway = OperatorWebDemoWageAuthorityGateway(
        initial: <WageRoleRowRecord>[
          rec(
            id: 'biz-server',
            scopeType: 'operator_wide',
            locationId: '',
            hourlyRate: 16.50,
          ),
          rec(
            id: 'loc-server',
            scopeType: 'location',
            locationId: 'loc-harbour',
            hourlyRate: 19.25,
          ),
        ],
      );

      await tester.pumpWidget(
        wrap(
          WageAuthorityScreen(
            session: session(<String>['operator_owner']),
            locationId: 'loc-harbour',
            locationName: 'Harbour',
            gateway: gateway,
            hierarchyNodes: nodes,
            ancestorOrgUnitIdsNearestFirst: const <String>[],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('wage_authority_row_display_loc-server')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('wage_authority_row_display_biz-server')),
        findsNothing,
      );
      expect(find.textContaining('@ \$19.25/hr'), findsOneWidget);
      expect(find.textContaining('@ \$16.50/hr'), findsNothing);
    },
  );

  testWidgets('no hierarchy → degrades to Location notice, no misleading '
      'backend-only copy', (tester) async {
    await sizeViewport(tester);
    final gateway = OperatorWebDemoWageAuthorityGateway(
      initial: <WageRoleRowRecord>[
        rec(
          id: 'loc-server',
          scopeType: 'location',
          locationId: 'loc-harbour',
          hourlyRate: 19.25,
        ),
      ],
    );

    await tester.pumpWidget(
      wrap(
        WageAuthorityScreen(
          session: session(<String>['operator_owner']),
          locationId: 'loc-harbour',
          locationName: 'Harbour',
          gateway: gateway,
          // No hierarchyNodes — the pre-GAP-B2 single-location host.
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('wage_authority_scope_editor_location_only')),
      findsOneWidget,
    );
    // The old hardcoded "coming in a later wave" notice must not
    // resurface.
    expect(find.textContaining('coming in a later wave'), findsNothing);
    // The per-row badge still renders (resolver works with no
    // ancestors).
    expect(
      find.byKey(const Key('wage_authority_row_scope_badge_loc-server')),
      findsOneWidget,
    );
  });
}
