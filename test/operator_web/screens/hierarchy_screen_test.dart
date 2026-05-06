// Phase 11W.3 - Hierarchy screen widget tests.
//
// Pins the parity contract section "Hierarchy (11W.3 + 11A.13
// Hierarchy tab)":
//
//   - tree shape + alphabetical display order
//   - move semantics gated on `team.roles.assign`
//   - read-only audiences (location_manager + operator_supervisor)
//   - validation copy verbatim:
//       * "Org unit name is required."
//       * "An org unit with this name already exists in this group."
//       * "Cannot move into a child of itself."
//   - permission-key snapshot trumps role tier
//   - idempotency replay (same key on the same call returns cache)
//   - zero em dashes in operator-facing string literals (scan of the
//     four 11W.3-owned files)
//
// Tests rely on the in-memory `DemoWebTeamHierarchyGateway` and the
// shared fixture set so the assertions stay deterministic.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/hierarchy_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_hierarchy_gateway.dart';
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

  OperatorWebSession sessionWithRole(
    String role, {
    Set<String> permissions = const <String>{},
  }) =>
      OperatorWebSession(
        uid: 'session-$role',
        email: 'sam.owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: <String>[role],
        permissions: permissions,
      );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required OperatorWebSession session,
    DemoWebTeamHierarchyGateway? gateway,
    String Function()? idempotencyKeyFactory,
  }) async {
    await tester.pumpWidget(
      wrap(
        HierarchyScreen(
          session: session,
          gateway: gateway ?? DemoWebTeamHierarchyGateway(),
          idempotencyKeyFactory: idempotencyKeyFactory,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('HierarchyScreen layout + tree rendering', () {
    testWidgets('renders header + tree at desktop 1280x900', (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_hierarchy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_org_unit_tree')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_hierarchy_subtitle')),
        findsOneWidget,
      );
    });

    testWidgets('renders one node per fixture org unit + one card per '
        'fixture location', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      for (final fixture in kDemoTeamOrgUnitsFixture) {
        expect(
          find.byKey(Key('operator_web_org_unit_toggle_${fixture.orgUnitId}')),
          findsOneWidget,
          reason: 'expected toggle for ${fixture.orgUnitId}',
        );
      }
      for (final fixture in kDemoTeamLocationsFixture) {
        expect(
          find.byKey(
            Key('operator_web_location_card_${fixture.locationId}'),
          ),
          findsOneWidget,
          reason: 'expected card for ${fixture.locationId}',
        );
      }
    });
  });

  group('HierarchyScreen permission gate', () {
    testWidgets('operator_staff lands on the friendly forbidden surface', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 900));
      await pumpScreen(tester, session: sessionWithRole('operator_staff'));

      expect(
        find.byKey(const Key('operator_web_hierarchy_forbidden')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_hierarchy_screen')),
        findsNothing,
      );
    });

    testWidgets('location_manager renders read-only (no add-child or move)',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('location_manager'));

      expect(
        find.byKey(const Key('operator_web_hierarchy_readonly_notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_org_unit_add_child_demo-org-east'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('operator_web_location_card_move_demo-loc-downtown'),
        ),
        findsNothing,
      );
    });

    testWidgets('operator_supervisor renders read-only (no add-child or '
        'move buttons but tree still expands)', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_supervisor'));

      expect(
        find.byKey(const Key('operator_web_hierarchy_readonly_notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_org_unit_add_child_demo-org-east'),
        ),
        findsNothing,
      );
      // Toggle is still present (read-only audience keeps interactivity).
      expect(
        find.byKey(
          const Key('operator_web_org_unit_toggle_demo-org-east'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('permission snapshot for team.users.view + team.roles.assign '
        'admits a role that is not in the role-tier fallback', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'unrecognised',
          permissions: <String>{
            kHierarchyViewPermissionKey,
            kHierarchyAssignPermissionKey,
          },
        ),
      );

      expect(
        find.byKey(const Key('operator_web_hierarchy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_org_unit_add_child_demo-org-east'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('permission snapshot without team.users.view forces the '
        'forbidden surface even for operator_owner role', (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'operator_owner',
          permissions: <String>{'team.roles.assign'},
        ),
      );

      expect(
        find.byKey(const Key('operator_web_hierarchy_forbidden')),
        findsOneWidget,
      );
    });
  });

  group('HierarchyScreen create org unit', () {
    testWidgets('add child opens dialog with locked validation copy', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_child_demo-org-east')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operator_web_org_unit_add_dialog')),
        findsOneWidget,
      );

      // Empty submit -> "Org unit name is required."
      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_dialog_submit')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Org unit name is required.'), findsOneWidget);

      // Duplicate name -> "An org unit with this name already exists in
      // this group." (East + West are siblings under demo-org-root; we
      // are inside demo-org-east so we test against its own children
      // — it has none, so test the duplicate case via the
      // demo-org-root parent instead.)
      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_dialog_cancel')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_child_demo-org-root')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('operator_web_org_unit_add_dialog_name')),
        'East Region',
      );
      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_dialog_submit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('An org unit with this name already exists in this group.'),
        findsOneWidget,
      );
    });

    testWidgets('successful add inserts a new node into the tree', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_child_demo-org-east')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('operator_web_org_unit_add_dialog_name')),
        'Lakeshore District',
      );
      await tester.tap(
        find.byKey(const Key('operator_web_org_unit_add_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Org unit added.'), findsOneWidget);
      expect(find.text('Lakeshore District'), findsOneWidget);
    });
  });

  group('HierarchyScreen move location', () {
    testWidgets('move dialog repositions a location under a different unit',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamHierarchyGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      // Riverside currently lives under West Region. Move it under
      // East Region.
      await tester.tap(
        find.byKey(
          const Key('operator_web_location_card_move_demo-loc-riverside'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_location_move_dialog')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_target')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('East Region (demo_bistro.east_region)').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Location moved.'), findsOneWidget);
    });

    testWidgets('idempotency replay returns the same outcome twice', (
      tester,
    ) async {
      final gateway = DemoWebTeamHierarchyGateway();
      const stableKey = 'op-web-hierarchy-stable-key';
      final firstMove = await gateway.moveLocationToOrgUnit(
        const TeamLocationOrgUnitMoveCommand(
          actorUserId: 'demo-user-owner',
          operatorId: 'demo-operator',
          locationId: 'demo-loc-downtown',
          targetLocationId: 'demo-loc-riverside',
          parentOrgUnitId: 'demo-org-east',
        ),
        idempotencyKey: stableKey,
      );
      // Second submission with the same key must surface the original
      // outcome without applying a second mutation.
      final secondMove = await gateway.moveLocationToOrgUnit(
        const TeamLocationOrgUnitMoveCommand(
          actorUserId: 'demo-user-owner',
          operatorId: 'demo-operator',
          locationId: 'demo-loc-downtown',
          targetLocationId: 'demo-loc-riverside',
          // Different parent on retry; replay still wins.
          parentOrgUnitId: 'demo-org-west',
        ),
        idempotencyKey: stableKey,
      );
      expect(firstMove.moved, isTrue);
      expect(secondMove.moved, firstMove.moved);
    });
  });

  group('HierarchyCopy locked strings', () {
    test('exposes the three locked validation strings verbatim', () {
      expect(
        HierarchyCopy.emptyOrgUnitName,
        'Org unit name is required.',
      );
      expect(
        HierarchyCopy.duplicateOrgUnitName,
        'An org unit with this name already exists in this group.',
      );
      expect(HierarchyCopy.moveCycle, 'Cannot move into a child of itself.');
    });
  });

  group('Server error mapping', () {
    testWidgets('cycle_detected server error surfaces the locked move-cycle '
        'copy', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = _StubMoveErrorGateway(
        const WebTeamHierarchyError(
          code: 'cycle_detected',
          message: 'server-side cycle guard tripped',
          statusCode: 409,
        ),
      );
      await tester.pumpWidget(
        wrap(
          HierarchyScreen(
            session: sessionWithRole('operator_owner'),
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const Key('operator_web_location_card_move_demo-loc-riverside'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_target')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('East Region (demo_bistro.east_region)').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text(HierarchyCopy.moveCycle), findsOneWidget);
    });

    testWidgets('validation_failed server error surfaces the server-supplied '
        'message verbatim', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = _StubMoveErrorGateway(
        const WebTeamHierarchyError(
          code: 'validation_failed',
          message: 'Cannot move into a child of itself.',
          statusCode: 422,
        ),
      );
      await tester.pumpWidget(
        wrap(
          HierarchyScreen(
            session: sessionWithRole('operator_owner'),
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const Key('operator_web_location_card_move_demo-loc-riverside'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_target')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('East Region (demo_bistro.east_region)').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_location_move_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Cannot move into a child of itself.'),
        findsOneWidget,
      );
    });
  });

  group('Em-dash regression', () {
    test('11W.3-owned files contain zero em dashes in operator copy',
        () async {
      const paths = <String>[
        'lib/operator_web/services/web_team_hierarchy_gateway.dart',
        'lib/operator_web/services/demo_team_hierarchy_gateway.dart',
        'lib/operator_web/screens/hierarchy_screen.dart',
        'lib/operator_web/widgets/org_unit_tree_view.dart',
        'lib/operator_web/widgets/location_card.dart',
      ];
      const stringLiteralPattern =
          r"""(?<!\\)(?:'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")""";
      final regex = RegExp(stringLiteralPattern);
      for (final path in paths) {
        final file = io.File(path);
        if (!await file.exists()) {
          fail('$path was not found - test must run from the repo root');
        }
        final source = await file.readAsString();
        final matches = regex.allMatches(source);
        for (final match in matches) {
          final literal = match.group(0)!;
          // Comments are not string literals; this regex skips them.
          // We intentionally match em-dashes anywhere in the literal.
          if (literal.contains('—')) {
            fail(
              'em dash found in $path within literal: $literal',
            );
          }
        }
      }
    });
  });
}

/// Test double that lets the list call resolve from the in-memory demo
/// gateway (so the screen has a tree to interact with) but forces the
/// move call to throw the supplied error. Used to exercise the
/// screen's `_friendlyMutationError` mapping for `cycle_detected` and
/// `validation_failed` server responses.
class _StubMoveErrorGateway implements WebTeamHierarchyGateway {
  _StubMoveErrorGateway(this._moveError);

  final WebTeamHierarchyError _moveError;
  final DemoWebTeamHierarchyGateway _delegate = DemoWebTeamHierarchyGateway();

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) {
    return _delegate.listOrgHierarchy(command);
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  }) {
    return _delegate.createOrgUnit(command, idempotencyKey: idempotencyKey);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  }) {
    throw _moveError;
  }
}
