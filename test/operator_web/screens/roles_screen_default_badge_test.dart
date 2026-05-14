// Lane B B2.2 + B2.4 — Operator Web Roles screen "Default" annotation
// pure-function tests.
//
// Wave 2 S-3 (RP-8) repurposed this file. The Roles list view is now
// simplified per debug.md:34: rows show only the role name + first
// sentence of the description + Edit / View button. The "Default"
// badge, the read-only badge, and the inline F&F annotation are no
// longer surfaced on the list — they move into the editor screen.
//
// The pure-function helper `defaultAnnotationCopyForCatalogPublishedAt`
// is still useful (the editor screen's metadata card uses the same
// shape) so we keep that test and replace the widget assertions with
// the S-3 simplified-row contract:
//
//   * Seeded rows render NO "Default" badge and NO "Managed by Forge
//     & Flow" annotation on the list.
//   * Custom rows render NO badge / annotation either.
//   * Both kinds render display_name + first-sentence description
//     + Edit / View button.

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

  testWidgets(
    'Wave 2 S-3 (RP-8): seeded row does NOT render the "Default" badge '
    'or the "Managed by Forge & Flow" annotation on the list',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester);

      final seededFixture =
          kDemoTeamRolesFixture.where((r) => r.isSeeded).first;
      // No annotation key on the simplified row.
      expect(
        find.byKey(
          Key('operator_web_role_default_annotation_${seededFixture.roleId}'),
        ),
        findsNothing,
      );
      // The string "Default" appears in the group title ("Default
      // roles (N)") but the badge text is no longer rendered on a
      // tile, and the annotation copy is gone.
      expect(find.text('Managed by Forge & Flow'), findsNothing);
    },
  );

  testWidgets(
    'Wave 2 S-3 (RP-8): custom row does NOT render the badge or '
    'annotation either',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester);

      final customFixture =
          kDemoTeamRolesFixture.where((r) => !r.isSeeded).first;
      expect(
        find.byKey(
          Key('operator_web_role_default_annotation_${customFixture.roleId}'),
        ),
        findsNothing,
      );
    },
  );

  group('Lane B B2.4 — catalog_published_at annotation helper', () {
    test(
      'defaultAnnotationCopyForCatalogPublishedAt: null → '
      'fallback copy; UTC timestamp → localized Mon D, YYYY format',
      () {
        // Null path.
        expect(
          defaultAnnotationCopyForCatalogPublishedAt(null),
          equals('Managed by Forge & Flow'),
        );
        // Non-null path — pick a time where the local date matches
        // the UTC date in every plausible CI TZ offset.
        final utc = DateTime.utc(2026, 3, 7, 12, 0);
        final local = utc.toLocal();
        final expected =
            'Updated by F&F on Mar ${local.day}, ${local.year}';
        expect(
          defaultAnnotationCopyForCatalogPublishedAt(utc),
          equals(expected),
        );
      },
    );
  });
}
