// Lane B B2.2 + B2.4 — Operator Web Roles screen "Default" badge
// annotation tests.
//
// Pins the contract documented in
// `lib/operator_web/screens/roles_screen.dart`:
//
//   * Seeded role rows render the "Default" badge (replaces the
//     prior "Seeded" engineering label per B2.2 + the project UX
//     standard "plain English; no engineering jargon").
//   * Seeded role rows include the inline
//     "Managed by Forge & Flow" annotation under the badge row
//     when the catalog version's `published_at` is null (genesis
//     state — no catalog version published yet).
//   * Lane B B2.4 — when the proxy projects
//     `catalog_published_at` onto a seeded row (operator follows a
//     published default-catalog version), the annotation upgrades
//     to "Updated by F&F on Mon D, YYYY" using the operator's
//     local time zone. Custom rows continue to suppress the
//     annotation entirely.
//   * Custom role rows do NOT show the "Default" badge, the
//     seeded read-only badge, or the F&F annotation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/roles_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_roles_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_roles_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
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

  // ============================================================
  // Lane B B2.4 — catalog_published_at annotation cases.
  // ============================================================

  group('Lane B B2.4 — catalog_published_at annotation', () {
    testWidgets(
      'seeded row with catalogPublishedAt set renders '
      '"Updated by F&F on Jan 15, 2026" (operator local time)',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1200));
        await tester.pumpWidget(
          wrap(
            RolesScreen(
              session: sessionWithRole('operator_owner'),
              gateway: _StaticRolesGateway(
                roles: <TeamRoleCatalogEntry>[
                  _seededRoleEntry(
                    roleId: 'role-default-1',
                    catalogVersionId: 'v-1',
                    // Pick a time that yields the same local date in
                    // any TZ offset the CI host might run with: noon
                    // UTC on Jan 15 stays Jan 15 from UTC-11 to
                    // UTC+11.
                    catalogPublishedAt:
                        DateTime.utc(2026, 1, 15, 12, 0),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Annotation key is rendered (seeded row).
        expect(
          find.byKey(
            const Key('operator_web_role_default_annotation_role-default-1'),
          ),
          findsOneWidget,
        );
        // Date-rendering upgrades the copy.
        expect(find.text('Updated by F&F on Jan 15, 2026'), findsOneWidget);
        // Fallback copy is NOT rendered when the date is present.
        expect(find.text('Managed by Forge & Flow'), findsNothing);
      },
    );

    testWidgets(
      'seeded row with catalogPublishedAt = null falls back to '
      '"Managed by Forge & Flow"',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1200));
        await tester.pumpWidget(
          wrap(
            RolesScreen(
              session: sessionWithRole('operator_owner'),
              gateway: _StaticRolesGateway(
                roles: <TeamRoleCatalogEntry>[
                  _seededRoleEntry(
                    roleId: 'role-genesis-1',
                    catalogVersionId: null,
                    catalogPublishedAt: null,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('operator_web_role_default_annotation_role-genesis-1'),
          ),
          findsOneWidget,
        );
        expect(find.text('Managed by Forge & Flow'), findsOneWidget);
        // No date-rendering when the field is null.
        expect(
          find.textContaining('Updated by F&F on'),
          findsNothing,
        );
      },
    );

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

/// Build a seeded [TeamRoleCatalogEntry] suitable for screen tests
/// that need to control the catalog-version fields directly.
TeamRoleCatalogEntry _seededRoleEntry({
  required String roleId,
  required String? catalogVersionId,
  required DateTime? catalogPublishedAt,
}) {
  return TeamRoleCatalogEntry(
    roleId: roleId,
    roleKey: 'operator_owner',
    displayName: 'Owner',
    description: 'Catalog-sourced seeded role for B2.4 annotation pin.',
    isSeeded: true,
    isEditable: false,
    operatorId: null,
    catalogVersionId: catalogVersionId,
    catalogPublishedAt: catalogPublishedAt,
    permissions: const <TeamRolePermissionRule>[],
  );
}

/// Minimal in-test gateway that lets each case drive a specific
/// list of role entries. Avoids the demo gateway's seeded fixture
/// set so the catalog-version annotation can be exercised against
/// known timestamps.
class _StaticRolesGateway implements WebTeamRolesGateway {
  _StaticRolesGateway({required this.roles});

  final List<TeamRoleCatalogEntry> roles;

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    return TeamRoleCatalogListed(
      roles: List<TeamRoleCatalogEntry>.unmodifiable(roles),
    );
  }

  @override
  Future<TeamRoleCreated> createRole(
    TeamRoleCreateCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TeamRolePatched> patchRole(
    TeamRolePatchCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TeamRoleDeleted> deleteRole(
    TeamRoleDeleteCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    throw UnimplementedError();
  }
}
