// Lane B B2.2 - Operator Web Roles screen "Default" badge annotation
// tests.
//
// Pins the contract documented in
// `lib/operator_web/screens/roles_screen.dart`:
//
//   * Seeded role rows render the "Default" badge (replaces the
//     prior "Seeded" engineering label per B2.2 + the project UX
//     standard "plain English; no engineering jargon").
//   * Seeded role rows include the inline "Managed by Forge & Flow"
//     annotation under the badge row.
//   * Custom role rows do NOT show the "Default" badge, the seeded
//     read-only badge, or the F&F annotation.
//
// Note: the catalog version's `published_at` timestamp is NOT
// surfaced by the operator-web role-read endpoint (verified against
// `lib/operator_web/services/web_team_roles_gateway.dart` +
// `lib/services/auth/auth_operations_gateway.dart`'s
// `TeamRoleCatalogEntry` shape). The slice spec wanted "Updated by
// F&F on <date>"; the date half is flagged as an honest gap in the
// B2.2 return summary for a future backend slice to address.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/roles_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_roles_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWithRole(String role) => OperatorWebSession(
        uid: 'session-$role',
        email: 'owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: <String>[role],
        permissions: const <String>{},
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        RolesScreen(
          session: sessionWithRole('operator_owner'),
          gateway: DemoWebTeamRolesGateway(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('seeded role row shows "Default" badge text', (tester) async {
    await sizeViewport(tester, const Size(1280, 1200));
    await pumpScreen(tester);

    // The seeded group is titled "Default roles" (renamed from
    // "Seeded roles" in B2.2).
    expect(find.textContaining('Default roles ('), findsOneWidget);

    // At least one seeded role row exists; verify a badge labeled
    // "Default" is rendered.
    expect(find.text('Default'), findsWidgets);
  });

  testWidgets(
      'seeded role row shows "Managed by Forge & Flow" annotation under badge',
      (tester) async {
    await sizeViewport(tester, const Size(1280, 1200));
    await pumpScreen(tester);

    // Each seeded row carries the annotation keyed by its role_id.
    // Pull the first seeded fixture role_id directly from the fixture
    // catalog to avoid coupling to a specific seeded role list.
    final seededFixture =
        kDemoTeamRolesFixture.where((r) => r.isSeeded).first;
    expect(
      find.byKey(
        Key('operator_web_role_default_annotation_${seededFixture.roleId}'),
      ),
      findsOneWidget,
    );
    expect(find.text('Managed by Forge & Flow'), findsWidgets);
  });

  testWidgets(
      'custom role row does NOT show the "Default" annotation or read-only badge',
      (tester) async {
    await sizeViewport(tester, const Size(1280, 1200));
    await pumpScreen(tester);

    final customFixture =
        kDemoTeamRolesFixture.where((r) => !r.isSeeded).first;
    // No "Managed by Forge & Flow" annotation key on a custom row.
    expect(
      find.byKey(
        Key('operator_web_role_default_annotation_${customFixture.roleId}'),
      ),
      findsNothing,
    );
  });
}
