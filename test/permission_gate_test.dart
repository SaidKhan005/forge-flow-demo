// Phase 9.7 - PermissionGate + PermissionContext widget tests.
//
// Uses the 9.6 in-memory snapshot + PermissionGate widget. No DB,
// no HTTP, no Firebase. Demonstrates the runtime gate pattern that
// lib/screens/auth/permission_gate.dart provides; production wiring
// of the proxy-side permission guard is parallel to the 9.2
// `package:postgres` binding.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/permission_cache.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/screens/auth/permission_gate.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:forge_and_flow/state/permission_context.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = '33333333-3333-3333-3333-333333333333';
const String _userX = '55555555-5555-5555-5555-555555555555';
const String _userY = '66666666-6666-6666-6666-666666666666';

PermissionContext buildContext({
  String userId = _userX,
  String operatorId = _opA,
  String locationId = _locA,
  Map<String, PermissionEffect>? entries,
  Set<String> requiresMfa = const <String>{},
  DateTime? evaluatedAt,
}) {
  return PermissionContext(
    snapshot: PermissionSnapshot(
      userId: userId,
      rolesVersion: 1,
      operatorId: operatorId,
      locationId: locationId,
      evaluatedAt: evaluatedAt ?? DateTime.utc(2026, 4, 26, 12),
      entries: entries ??
          <String, PermissionEffect>{
            'forgeflow.shift.view': PermissionEffect.allow,
          },
    ),
    requiresMfaKeys: requiresMfa,
  );
}

Widget wrap({
  required PermissionContext? permission,
  required Widget child,
  AuthSessionNotifier? authNotifier,
}) {
  Widget tree = child;
  if (permission != null) {
    tree = Provider<PermissionContext>.value(value: permission, child: tree);
  }
  if (authNotifier != null) {
    tree = ChangeNotifierProvider<AuthSessionNotifier>.value(
      value: authNotifier,
      child: tree,
    );
  }
  return MaterialApp(home: Scaffold(body: tree));
}

AuthSessionNotifier buildNotifierWithFresh({required bool fresh}) {
  final now = DateTime.utc(2026, 4, 26, 12);
  final notifier = AuthSessionNotifier(
    loginService: const ScaffoldFailingAuthLoginService(),
    storage: InMemorySecureSessionStorage(),
    now: () => now,
    freshnessWindow: const Duration(minutes: 5),
  );
  notifier.debugSetSession(AuthSession(
    userId: _userX,
    operatorId: _opA,
    locationId: _locA,
    firebaseIdToken: 't',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: fresh
        ? now.subtract(const Duration(minutes: 1))
        : now.subtract(const Duration(minutes: 30)),
    roles: const <String>['operator_owner'],
    mfaEnrolled: true,
  ));
  return notifier;
}

void main() {
  group('PermissionContext', () {
    test('hasPermission returns true for allowed keys', () {
      final ctx = buildContext();
      expect(ctx.hasPermission('forgeflow.shift.view'), isTrue);
    });

    test('hasPermission returns false for denied keys', () {
      final ctx = buildContext(
        entries: <String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.deny,
        },
      );
      expect(ctx.hasPermission('forgeflow.shift.view'), isFalse);
    });

    test('hasPermission returns false for unmapped keys (default deny)', () {
      final ctx = buildContext(entries: const <String, PermissionEffect>{});
      expect(ctx.hasPermission('forgeflow.shift.view'), isFalse);
    });

    test('requiresFreshAuth returns true only for keys in the MFA set', () {
      final ctx = buildContext(
        requiresMfa: const <String>{'admin.users.erase_pii'},
      );
      expect(ctx.requiresFreshAuth('admin.users.erase_pii'), isTrue);
      expect(ctx.requiresFreshAuth('forgeflow.shift.view'), isFalse);
    });

    test('allowedCount + deniedCount diagnostics', () {
      final ctx = buildContext(
        entries: <String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
          'forgeflow.variance.view': PermissionEffect.allow,
          'admin.users.erase_pii': PermissionEffect.deny,
        },
      );
      expect(ctx.allowedCount, equals(2));
      expect(ctx.deniedCount, equals(1));
    });
  });

  group('PermissionGate widget', () {
    testWidgets('renders child when permission is granted', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          child: Text('shift-view-here'),
        ),
      ));
      expect(find.text('shift-view-here'), findsOneWidget);
    });

    testWidgets('hides child when permission is denied', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(
          entries: <String, PermissionEffect>{
            'forgeflow.shift.view': PermissionEffect.deny,
          },
        ),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          denied: SizedBox.shrink(key: Key('denied-marker')),
          child: Text('shift-view-here'),
        ),
      ));
      expect(find.text('shift-view-here'), findsNothing);
      expect(find.byKey(const Key('denied-marker')), findsOneWidget);
    });

    testWidgets('hides child when key is unmapped (default deny)',
        (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(entries: const <String, PermissionEffect>{}),
        child: const PermissionGate(
          permissionKey: 'admin.users.erase_pii',
          child: Text('admin-only'),
        ),
      ));
      expect(find.text('admin-only'), findsNothing);
    });

    testWidgets('cross-tenant denial: a session with operator A cannot '
        'see content gated by an operator-B permission map', (tester) async {
      // Two ops, two contexts. The widget under test pulls the
      // operator-A PermissionContext; we wrap it with an
      // operator-A-only allow, simulating that the proxy refused
      // the operator-B grant inside its tenant transaction.
      await tester.pumpWidget(wrap(
        permission: buildContext(
          operatorId: _opA,
          entries: <String, PermissionEffect>{
            'forgeflow.shift.view': PermissionEffect.allow,
          },
        ),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          child: Text('opA-shift'),
        ),
      ));
      expect(find.text('opA-shift'), findsOneWidget);

      // Now swap to operator B's context. The same key is intentionally
      // not granted because operator B's grants don't include it.
      await tester.pumpWidget(wrap(
        permission: buildContext(
          operatorId: _opB,
          entries: const <String, PermissionEffect>{},
        ),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          child: Text('opB-shift'),
        ),
      ));
      expect(find.text('opB-shift'), findsNothing);
    });

    testWidgets('hides child when permission requires fresh auth and the '
        'session is stale (5+ minutes since auth_time)', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(
          entries: <String, PermissionEffect>{
            'admin.users.erase_pii': PermissionEffect.allow,
          },
          requiresMfa: const <String>{'admin.users.erase_pii'},
        ),
        authNotifier: buildNotifierWithFresh(fresh: false),
        child: const PermissionGate(
          permissionKey: 'admin.users.erase_pii',
          child: Text('erase-pii-action'),
        ),
      ));
      expect(find.text('erase-pii-action'), findsNothing);
    });

    testWidgets('renders child when permission requires fresh auth AND '
        'session is fresh', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(
          entries: <String, PermissionEffect>{
            'admin.users.erase_pii': PermissionEffect.allow,
          },
          requiresMfa: const <String>{'admin.users.erase_pii'},
        ),
        authNotifier: buildNotifierWithFresh(fresh: true),
        child: const PermissionGate(
          permissionKey: 'admin.users.erase_pii',
          child: Text('erase-pii-action'),
        ),
      ));
      expect(find.text('erase-pii-action'), findsOneWidget);
    });

    testWidgets('without a PermissionContext provider in the tree, the gate '
        'fails closed and hides the child', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const PermissionGate(
            permissionKey: 'forgeflow.shift.view',
            child: Text('should-not-render'),
          ),
        ),
      ));
      expect(find.text('should-not-render'), findsNothing);
    });

    testWidgets('without an AuthSessionNotifier provider AND a fresh-auth '
        'requirement, the gate hides the child', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(
          entries: <String, PermissionEffect>{
            'admin.users.erase_pii': PermissionEffect.allow,
          },
          requiresMfa: const <String>{'admin.users.erase_pii'},
        ),
        // No authNotifier here.
        child: const PermissionGate(
          permissionKey: 'admin.users.erase_pii',
          child: Text('erase-pii-action'),
        ),
      ));
      expect(find.text('erase-pii-action'), findsNothing);
    });

    testWidgets('different user does not inherit allowed set (cross-user '
        'isolation)', (tester) async {
      await tester.pumpWidget(wrap(
        permission: buildContext(
          userId: _userX,
          entries: <String, PermissionEffect>{
            'forgeflow.shift.view': PermissionEffect.allow,
          },
        ),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          child: Text('userX-allowed'),
        ),
      ));
      expect(find.text('userX-allowed'), findsOneWidget);

      // Swap to userY whose snapshot doesn't include the key.
      await tester.pumpWidget(wrap(
        permission: buildContext(
          userId: _userY,
          entries: const <String, PermissionEffect>{},
        ),
        child: const PermissionGate(
          permissionKey: 'forgeflow.shift.view',
          child: Text('userY-allowed'),
        ),
      ));
      expect(find.text('userY-allowed'), findsNothing);
    });
  });
}
