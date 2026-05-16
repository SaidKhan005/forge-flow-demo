// G7b — admin consumes catalog constants (behavior-preserving).
//
// Authoritative spec:
//   docs/_audits/cross_surface_parity_v1/g7_permission_convergence_spec.md §4
//   "G7b — admin consumes catalog constants."
//
// G7-pre (#871) refreshed the `PermissionKeys` role catalog; G7a (#885)
// introduced the shared `_isAdminSuperAdmin` helper in admin_routes.dart.
// G7b replaces the REMAINING bare `'super_admin'` / `'ff_support'`
// value-literals in the admin auth wiring with the frozen catalog
// constants (`PermissionKeys.roleSuperAdmin` / `roleFfSupport`), ONLY
// where byte-equal and behavior-preserving:
//
//   * lib/admin/admin_auth_gate.dart — `kAdminConsoleRoles` set, the
//     `is_super_admin`/`is_ff_support` claims→roles map, and the demo /
//     test fixture role lists.
//   * lib/admin/admin_shell.dart — the role-pill `switch` arms.
//   * lib/admin/screens/my_account_admin_screen.dart — the
//     `_readableAdminRole` value-equality checks.
//   * lib/admin/services/integration_admin_gateway.dart — the
//     `roles.contains('ff_support')` read-only gates.
//
// This is a pure literal→constant alias. The two invariants that make
// it byte-identical / behavior-preserving:
//
//   1. PermissionKeys.roleSuperAdmin == 'super_admin' (byte-equal) and
//      roleFfSupport == 'ff_support' (byte-equal).
//   2. `kAdminConsoleRoles` membership, `extractRolesFromClaims` output,
//      `isAdmin` admit decisions, and demo-fixture role lists are
//      identical before and after the substitution.
//
// PermissionResolver is deliberately NOT threaded into the admin
// client (spec §4 G7b: "No PermissionResolver threading into admin
// client (deferred; proxy enforces)"); this slice is literal aliasing
// only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

/// The OLD bare-literal claims projection that G7b replaced. Oracle:
/// `extractRolesFromClaims` must produce a byte-identical list to this
/// for every claims shape.
List<String> oldExtractRoles(Map<String, Object?> claims) {
  final roles = <String>[];
  if (claims['is_super_admin'] == true) roles.add('super_admin');
  if (claims['is_ff_support'] == true) roles.add('ff_support');
  return List<String>.unmodifiable(roles);
}

void main() {
  group('G7b byte-equality of catalog constants vs literals', () {
    test('PermissionKeys.roleSuperAdmin == "super_admin"', () {
      expect(PermissionKeys.roleSuperAdmin, equals('super_admin'));
      // Length + codeUnits guard against any zero-width / homoglyph drift.
      expect(PermissionKeys.roleSuperAdmin.codeUnits, 'super_admin'.codeUnits);
    });

    test('PermissionKeys.roleFfSupport == "ff_support"', () {
      expect(PermissionKeys.roleFfSupport, equals('ff_support'));
      expect(PermissionKeys.roleFfSupport.codeUnits, 'ff_support'.codeUnits);
    });
  });

  group('G7b kAdminConsoleRoles membership is unchanged', () {
    test('still exactly {super_admin, ff_support} (literal-stated)', () {
      expect(
        kAdminConsoleRoles,
        equals(<String>{'super_admin', 'ff_support'}),
      );
    });

    test('expressed via the catalog constants resolves to the same set',
        () {
      expect(
        kAdminConsoleRoles,
        equals(<String>{
          PermissionKeys.roleSuperAdmin,
          PermissionKeys.roleFfSupport,
        }),
      );
    });
  });

  group('G7b claims→roles map equivalence (constant ≡ old literal)', () {
    final claimsCases = <String, Map<String, Object?>>{
      'both flags true': const <String, Object?>{
        'is_super_admin': true,
        'is_ff_support': true,
      },
      'only super_admin': const <String, Object?>{'is_super_admin': true},
      'only ff_support': const <String, Object?>{'is_ff_support': true},
      'neither flag': const <String, Object?>{},
      'flags false': const <String, Object?>{
        'is_super_admin': false,
        'is_ff_support': false,
      },
      'truthy-string not admitted': const <String, Object?>{
        'is_super_admin': 'true',
      },
    };

    claimsCases.forEach((label, claims) {
      test('$label → extractRolesFromClaims == old literal projection', () {
        expect(
          FirebaseAdminAuthSource.extractRolesFromClaims(claims),
          equals(oldExtractRoles(claims)),
          reason:
              'G7b must be byte-identical: roles.add(roleSuperAdmin) ≡ '
              "roles.add('super_admin'); same for ff_support.",
        );
      });
    });

    test('both-flags case preserves order [super_admin, ff_support]', () {
      expect(
        FirebaseAdminAuthSource.extractRolesFromClaims(
          const <String, Object?>{
            'is_super_admin': true,
            'is_ff_support': true,
          },
        ),
        equals(<String>['super_admin', 'ff_support']),
      );
    });
  });

  group('G7b demo/test fixtures still carry the expected roles', () {
    test('signedInAsSuperAdmin admits via roleSuperAdmin', () {
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      final state = source.current;
      expect(state, isA<AdminAuthAuthenticated>());
      final session = (state as AdminAuthAuthenticated).session;
      expect(session.roles, equals(<String>['super_admin']));
      expect(session.roles, equals(<String>[PermissionKeys.roleSuperAdmin]));
      expect(session.isAdmin, isTrue);
      source.dispose();
    });

    test('signedInAsSupport admits via roleFfSupport', () {
      final source = DemoAdminAuthSource.signedInAsSupport();
      final state = source.current;
      expect(state, isA<AdminAuthAuthenticated>());
      final session = (state as AdminAuthAuthenticated).session;
      expect(session.roles, equals(<String>['ff_support']));
      expect(session.roles, equals(<String>[PermissionKeys.roleFfSupport]));
      expect(session.isAdmin, isTrue);
      source.dispose();
    });

    test('demo registry sign-in: super.admin → admitted super_admin',
        () async {
      final source = DemoAdminAuthSource.signedOut();
      await source.signInWithEmailPassword(
        email: 'super.admin@forgeflow.test',
        password: 'x',
      );
      final state = source.current;
      expect(state, isA<AdminAuthAuthenticated>());
      expect(
        (state as AdminAuthAuthenticated).session.roles,
        equals(<String>[PermissionKeys.roleSuperAdmin]),
      );
      source.dispose();
    });

    test('demo registry sign-in: support → admitted ff_support', () async {
      final source = DemoAdminAuthSource.signedOut();
      await source.signInWithEmailPassword(
        email: 'support@forgeflow.test',
        password: 'x',
      );
      final state = source.current;
      expect(state, isA<AdminAuthAuthenticated>());
      expect(
        (state as AdminAuthAuthenticated).session.roles,
        equals(<String>[PermissionKeys.roleFfSupport]),
      );
      source.dispose();
    });

    test('non-admin demo operator still fails closed (unchanged)', () async {
      final source = DemoAdminAuthSource.signedOut();
      await source.signInWithEmailPassword(
        email: 'operator@forgeflow.test',
        password: 'x',
      );
      expect(source.current, isA<AdminAuthForbidden>());
      source.dispose();
    });
  });

  group('G7b grep-guard: no bare role value-literal in active admin '
      'auth wiring', () {
    // Scoped to the four files G7b touched. Comments and the const
    // sample-log payload / display-name catalogs that are NOT auth
    // value-equality uses are intentionally out of scope (spec §4 G7b
    // + G7c/G7d defer the v1→v2 display-name reconciliation).
    const authWiringFiles = <String>[
      'lib/admin/admin_auth_gate.dart',
      'lib/admin/admin_shell.dart',
      'lib/admin/screens/my_account_admin_screen.dart',
      'lib/admin/services/integration_admin_gateway.dart',
    ];

    /// Strips // line comments and /// doc comments so a bare literal
    /// quoted inside prose (e.g. admin_auth_gate.dart doc header) does
    /// not trip the guard. Block comments are not used in these files
    /// for role prose, so a simple line-prefix strip is sufficient.
    String stripComments(String src) {
      return src
          .split('\n')
          .map((line) {
            final trimmed = line.trimLeft();
            if (trimmed.startsWith('//')) return '';
            return line;
          })
          .join('\n');
    }

    for (final path in authWiringFiles) {
      test('no bare \'super_admin\'/\'ff_support\' literal in $path', () {
        final code = stripComments(File(path).readAsStringSync());
        expect(
          RegExp(r"'super_admin'").hasMatch(code),
          isFalse,
          reason:
              "$path: every active 'super_admin' role value must be "
              'PermissionKeys.roleSuperAdmin.',
        );
        expect(
          RegExp(r"'ff_support'").hasMatch(code),
          isFalse,
          reason:
              "$path: every active 'ff_support' role value must be "
              'PermissionKeys.roleFfSupport.',
        );
      });
    }

    test('each touched file imports the permission_keys catalog', () {
      expect(
        File('lib/admin/admin_auth_gate.dart').readAsStringSync(),
        contains("import '../auth/permission_keys.dart';"),
      );
      expect(
        File('lib/admin/admin_shell.dart').readAsStringSync(),
        contains("import '../auth/permission_keys.dart';"),
      );
      expect(
        File('lib/admin/screens/my_account_admin_screen.dart')
            .readAsStringSync(),
        contains("import '../../auth/permission_keys.dart';"),
      );
      expect(
        File('lib/admin/services/integration_admin_gateway.dart')
            .readAsStringSync(),
        contains("import '../../auth/permission_keys.dart';"),
      );
    });
  });
}
