// G7d (cross-surface parity v1) — operator-web fallback sets → v2
// constants; drop phantom `operator_admin`; remove the
// `integrations.configure → operator_owner` inflation.
//
// Spec: docs/_audits/cross_surface_parity_v1/g7_permission_convergence_spec.md
//   §2.B + §3 + the OPERATOR DECISIONS block (2026-05-16).
//
// What this pins:
//   1. `_inferRoles` re-based on the v2 default role catalog
//      (`202605150000_phase_r2l_default_role_catalog_v2.sql`). Live
//      `role_labels` are the v2 *display names* (operator-confirmed:
//      no raw v1 role-key labels arrive live). Each display name maps
//      to its `PermissionKeys.role*` v2 constant.
//   2. The phantom `operator_admin` is NEVER synthesized (folded into
//      `operator_owner`). An `*_admin`-style label no longer inflates
//      to a synthetic admin role.
//   3. The `integrations.configure → operator_owner` inflation is
//      removed. A snapshot that allows `integrations.configure` but
//      carries no owner label does NOT mint `operator_owner`. Live
//      path stays neutral because real users carry the hydrated
//      permission snapshot and the per-screen `PermissionKeys.*`
//      gates (+ `_hasConsoleAccess` permission fallback) decide
//      console access — proven here by an `Owner`-labelled session
//      still being admitted.
//   4. The empty-snapshot demo/boot path now fails CLOSED for the
//      removed `operator_admin` collision (operator-accepted): a
//      session whose only signal was the old `*_admin` label +
//      `integrations.configure` no longer auto-admits via a
//      synthesized role; it falls back to the permission-key
//      `_hasConsoleAccess` clause only.
//   5. `location_manager` is a REAL v2 role and is KEPT
//      (`PermissionKeys.roleLocationManager`) — admitted to the
//      console.
//   6. Grep-guard: no bare phantom `'operator_admin'` admit/write
//      role-set literal and no unmapped soft-deleted v1 role-set
//      literal remains across `lib/operator_web/` (the auth source's
//      v1-label *recognition* branches that emit the mapped v2
//      constant are allowed — map, don't drop).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/operator_web/auth/firebase_operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');

  FirebaseAuthCredential buildCredential() {
    final issuedAt = DateTime.utc(2026, 5, 16, 12);
    return FirebaseAuthCredential(
      userId: 'user-1',
      idToken: 'tok-abc',
      idTokenIssuedAt: issuedAt,
      idTokenExpiresAt: issuedAt.add(const Duration(hours: 1)),
      lastFreshAuthAt: issuedAt,
      email: 'person@demo.forgeflow.test',
      displayName: 'Demo Person',
      customClaims: const <String, Object?>{
        'business_name': 'Demo Restaurant Group',
      },
    );
  }

  /// Drives one successful proxy sign-in with the supplied
  /// `role_labels` + permission map, returns the landed state so the
  /// test can read `session.roles` (the public observable of the
  /// private `_inferRoles`) and the admit/forbid verdict.
  Future<OperatorWebAuthState> signInWith({
    required List<String> roleLabels,
    required Map<String, String> permissions,
  }) async {
    final authClient = _StubFirebaseAuthClient()
      ..scriptedSignIn = FirebaseAuthSignInSucceeded(buildCredential());
    final proxyClient = OperatorWebProxyClient(
      baseUri: kProxyBase,
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == OperatorWebProxyClient.authSessionLoginPath) {
          return _json(<String, Object?>{
            'session_id': 'session-uuid-1',
            'user_id': 'user-1',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          });
        }
        if (path == OperatorWebProxyClient.authAccountInfoPath) {
          return _json(<String, Object?>{
            'display_name': 'Demo Person',
            'email': 'person@demo.forgeflow.test',
            'status_label': 'Active',
            'location_label': 'Demo Main Street',
            'role_labels': roleLabels,
            'mfa_enabled': true,
          });
        }
        if (path == OperatorWebProxyClient.authPermissionsSnapshotPath) {
          return _json(<String, Object?>{
            'user_id': 'user-1',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
            'roles_version': 1,
            'evaluated_at': '2026-05-16T12:00:00Z',
            'permissions': permissions,
          });
        }
        return _json(<String, Object?>{
          'error': 'unscripted_route',
          'message': 'no canned response for $path',
        }, status: 500);
      }),
    );
    final source = FirebaseOperatorWebAuthSource(
      authClient: authClient,
      proxyClient: proxyClient,
    );
    addTearDown(source.dispose);
    await _waitFor(source, (s) => s is OperatorWebNeedsSignIn);
    await source.signInWithEmailPassword(
      email: 'person@demo.forgeflow.test',
      password: 'demo-password-1234',
    );
    await _waitFor(
      source,
      (s) => s is OperatorWebCompleted || s is OperatorWebForbidden,
    );
    return source.current;
  }

  group('G7d — _inferRoles re-based on the v2 catalog (display names)', () {
    test('v2 display names map to their PermissionKeys.role* constants', () async {
      final state = await signInWith(
        roleLabels: const <String>[
          'Owner',
          'General Manager',
          'Location Manager',
          'Supervisor',
          'Finance Analyst',
          'Auditor / Compliance',
          'Training Lead',
          'Team Admin',
          'F&F Support',
        ],
        permissions: const <String, String>{},
      );
      final roles = state.session!.roles;
      expect(roles, contains(PermissionKeys.roleOperatorOwner));
      expect(roles, contains(PermissionKeys.roleOperatorGeneralManager));
      expect(roles, contains(PermissionKeys.roleLocationManager));
      expect(roles, contains(PermissionKeys.roleSupervisor));
      expect(roles, contains(PermissionKeys.roleFinanceAnalyst));
      expect(roles, contains(PermissionKeys.roleAuditorCompliance));
      expect(roles, contains(PermissionKeys.roleTrainingLead));
      expect(roles, contains(PermissionKeys.roleTeamAdmin));
      expect(roles, contains(PermissionKeys.roleFfSupport));
      // The phantom is NEVER synthesized.
      expect(roles, isNot(contains('operator_admin')));
      // Owner label admits to the console.
      expect(state, isA<OperatorWebCompleted>());
    });

    test('Owner-labelled session is admitted (live-path neutral)', () async {
      // Real users carry the hydrated snapshot; the Owner display name
      // maps to roleOperatorOwner which is in kOperatorWebAdmittedRoles.
      final state = await signInWith(
        roleLabels: const <String>['Owner'],
        permissions: const <String, String>{
          'team.users.view': 'allow',
          'integrations.configure': 'allow',
        },
      );
      expect(state.session!.roles, <String>[PermissionKeys.roleOperatorOwner]);
      expect(state, isA<OperatorWebCompleted>());
    });

    test('Location Manager (REAL v2 role) is kept and admitted', () async {
      final state = await signInWith(
        roleLabels: const <String>['Location Manager'],
        permissions: const <String, String>{},
      );
      expect(
        state.session!.roles,
        <String>[PermissionKeys.roleLocationManager],
      );
      expect(
        kOperatorWebAdmittedRoles,
        contains(PermissionKeys.roleLocationManager),
      );
      expect(state, isA<OperatorWebCompleted>());
    });
  });

  group('G7d — phantom operator_admin dropped + inflation removed', () {
    test('an *_admin label no longer synthesizes operator_admin', () async {
      // v1-shape label that used to trip the `_admin` branch. With the
      // phantom removed it maps to NOTHING owner-ish; the only console
      // signal is the permission-key `_hasConsoleAccess` clause.
      final state = await signInWith(
        roleLabels: const <String>['Operator Admin'],
        permissions: const <String, String>{},
      );
      final roles = state.session!.roles;
      expect(roles, isNot(contains('operator_admin')));
      expect(roles, isNot(contains(PermissionKeys.roleOperatorOwner)));
      // No console permission either ⇒ fail CLOSED (operator-accepted
      // demo/boot tightening for the removed collision).
      expect(state, isA<OperatorWebForbidden>());
    });

    test(
      'integrations.configure no longer inflates to operator_owner',
      () async {
        // Snapshot allows integrations.configure but no owner label.
        // Pre-G7d this minted operator_owner; post-G7d it does not.
        final state = await signInWith(
          roleLabels: const <String>['Some Custom Role'],
          permissions: const <String, String>{
            'integrations.configure': 'allow',
          },
        );
        expect(
          state.session!.roles,
          isNot(contains(PermissionKeys.roleOperatorOwner)),
        );
        // Live path stays neutral: _hasConsoleAccess still admits via
        // the integrations.configure permission key.
        expect(state, isA<OperatorWebCompleted>());
      },
    );

    test(
      'empty-label snapshot with a console permission falls back to the '
      'v2 General Manager constant (not v1 operator_manager)',
      () async {
        final state = await signInWith(
          roleLabels: const <String>[],
          permissions: const <String, String>{'team.users.view': 'allow'},
        );
        expect(
          state.session!.roles,
          <String>[PermissionKeys.roleOperatorGeneralManager],
        );
        expect(
          state.session!.roles,
          isNot(contains('operator_manager')),
        );
        expect(state, isA<OperatorWebCompleted>());
      },
    );

    test(
      'no labels and no console permission ⇒ fail CLOSED (forbidden)',
      () async {
        final state = await signInWith(
          roleLabels: const <String>[],
          permissions: const <String, String>{},
        );
        expect(state.session!.roles, isEmpty);
        expect(state, isA<OperatorWebForbidden>());
      },
    );
  });

  group('G7d — kOperatorWebAdmittedRoles is the v2 admit set', () {
    test('admits the v2 console-tier constants only', () {
      expect(kOperatorWebAdmittedRoles, <String>{
        PermissionKeys.roleOperatorOwner,
        PermissionKeys.roleOperatorGeneralManager,
        PermissionKeys.roleLocationManager,
      });
      expect(kOperatorWebAdmittedRoles, isNot(contains('operator_admin')));
    });
  });

  group('G7d — grep-guard: no bare phantom / unmapped v1 role-set '
      'literal in lib/operator_web/', () {
    test('no `operator_admin` admit/write set literal; demo session '
        'constants + v1-label recognition branches excepted', () {
      // Scope: the screen + auth-source + shell files G7d owns. The
      // demo session constants in operator_web_auth_source.dart use
      // `operator_owner`/`location_manager` (already correct v2) and
      // the file's v1-label recognition branches deliberately map to
      // the v2 constant (map, don't drop). `demo_team_fixtures.dart`
      // is Q5 (deferred display-only fixture hygiene) — out of scope.
      const ownedFiles = <String>[
        'lib/operator_web/auth/firebase_operator_web_auth_source.dart',
        'lib/operator_web/screens/account_screen.dart',
        'lib/operator_web/screens/audit_log_screen.dart',
        'lib/operator_web/screens/business_setup_screen.dart',
        'lib/operator_web/screens/business_timing_editor_screen.dart',
        'lib/operator_web/screens/data_accuracy_screen.dart',
        'lib/operator_web/screens/hierarchy_screen.dart',
        'lib/operator_web/screens/members_screen.dart',
        'lib/operator_web/screens/my_account_screen.dart',
        'lib/operator_web/screens/roles_screen.dart',
        'lib/operator_web/screens/schedule_screen.dart',
        'lib/operator_web/screens/sessions_screen.dart',
        'lib/operator_web/screens/vendor_connections_screen.dart',
        'lib/operator_web/screens/wage_authority_screen.dart',
        'lib/operator_web/widgets/web_app_shell.dart',
      ];
      // A bare role-SET / role-CHECK literal looks like
      // `'operator_admin',` (set element) or `'operator_admin')`
      // (`.contains('operator_admin')`). We allow it ONLY inside a
      // `//`/`///` comment line (the rationale annotations) and inside
      // `normalized.contains(...)`/`normalized.endsWith(...)` v1-label
      // recognition branches (map-don't-drop, auth source only).
      final bannedRoleStrings = <String>[
        'operator_admin',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ];
      for (final rel in ownedFiles) {
        final file = File(rel);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Expected $rel (cwd=${Directory.current.path})',
        );
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final raw = lines[i];
          final trimmed = raw.trimLeft();
          // Skip comment lines (rationale annotations cite the literal).
          if (trimmed.startsWith('//') || trimmed.startsWith('///') ||
              trimmed.startsWith('*')) {
            continue;
          }
          // Skip the auth source's v1-label recognition branches that
          // map to the v2 constant (map, don't drop — spec §3).
          if (trimmed.contains('normalized.contains(') ||
              trimmed.contains('normalized.endsWith(') ||
              trimmed.contains('normalized ==')) {
            continue;
          }
          for (final role in bannedRoleStrings) {
            final single = "'$role'";
            final double = '"$role"';
            expect(
              raw.contains(single) || raw.contains(double),
              isFalse,
              reason:
                  'Bare phantom/unmapped-v1 role literal "$role" at '
                  '$rel:${i + 1} — must be a PermissionKeys.role* v2 '
                  'constant (phantom dropped / v1 mapped per spec §3).',
            );
          }
        }
      }
    });
  });
}

http.Response _json(Map<String, Object?> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

Future<void> _waitFor(
  FirebaseOperatorWebAuthSource source,
  bool Function(OperatorWebAuthState) predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (predicate(source.current)) return;
  final completer = Completer<void>();
  final sub = source.stream.listen((state) {
    if (!completer.isCompleted && predicate(state)) {
      completer.complete();
    }
  });
  try {
    await completer.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

class _StubFirebaseAuthClient implements FirebaseAuthClient {
  FirebaseAuthSignInOutcome? scriptedSignIn;
  String? currentToken = 'tok-abc';

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return scriptedSignIn ??
        const FirebaseAuthSignInFailed(
          code: 'unscripted',
          message: 'test stub did not script a sign-in outcome',
        );
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return scriptedSignIn ??
        const FirebaseAuthSignInFailed(
          code: 'unscripted',
          message: 'test stub did not script an MFA outcome',
        );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => null;

  @override
  Future<String?> currentIdToken() async => currentToken;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> revokeAllRefreshTokens() async {}
}
