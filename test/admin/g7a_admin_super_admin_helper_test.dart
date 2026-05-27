// G7a — shared admin super_admin editing-gate helper (behavior-preserving).
//
// Authoritative spec:
//   docs/_audits/cross_surface_parity_v1/g7_permission_convergence_spec.md §4
//   "G7a — shared admin super_admin helper (behavior-preserving)."
//
// `lib/admin/admin_routes.dart` previously copy-pasted the editing-gate
// expression `session != null && session.roles.contains('super_admin')`
// at 14 active route-builder sites (plus 3 sites inside legacy
// `// ignore: unused_element` dead builders, which are intentionally
// left untouched). G7a introduces one shared predicate
// `_isAdminSuperAdmin(session)` and aliases the bare `'super_admin'`
// literal to the frozen catalog constant `PermissionKeys.roleSuperAdmin`.
//
// `_isAdminSuperAdmin` is a private top-level function, so it cannot be
// called directly from a test. Instead this test pins the two
// invariants that make the refactor byte-identical / behavior-preserving:
//
//   1. `PermissionKeys.roleSuperAdmin == 'super_admin'` (byte-equal) —
//      so `.contains('super_admin')` ≡ `.contains(roleSuperAdmin)`.
//   2. The equivalence of the OLD inline expression and the NEW
//      helper-shaped expression over the decision matrix
//      (`super_admin`, `ff_support`, `operator_owner`, null, empty).
//   3. A grep-guard over the active builders of `admin_routes.dart`:
//      zero bare `roles.contains('super_admin')` remain in live code,
//      exactly 14 `_isAdminSuperAdmin(session)` call sites exist, and
//      the shared helper + `permission_keys.dart` import are present.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

/// Mirrors the production private helper body exactly:
///   `s != null && s.roles.contains(PermissionKeys.roleSuperAdmin)`.
/// Kept in lock-step with `_isAdminSuperAdmin` in admin_routes.dart.
bool helperShaped(AdminAuthSession? s) =>
    s != null && s.roles.contains(PermissionKeys.roleSuperAdmin);

/// The OLD copy-pasted inline expression that G7a replaced (bare
/// literal). The oracle: this must produce byte-identical decisions
/// to [helperShaped] for every input.
bool oldInline(AdminAuthSession? s) =>
    s != null && s.roles.contains('super_admin');

AdminAuthSession sessionWithRoles(List<String> roles) => AdminAuthSession(
  uid: 'u1',
  email: 'admin@example.test',
  displayName: 'Admin',
  roles: roles,
);

void main() {
  group('G7a byte-equality of catalog constants vs literals', () {
    test('PermissionKeys.roleSuperAdmin == "super_admin"', () {
      expect(PermissionKeys.roleSuperAdmin, equals('super_admin'));
    });

    test('PermissionKeys.roleFfSupport == "ff_support"', () {
      expect(PermissionKeys.roleFfSupport, equals('ff_support'));
    });
  });

  group('G7a behavior-preserving: helper ≡ old inline expression', () {
    // Decision matrix from the spec's §4 verify block.
    final cases = <String, AdminAuthSession?>{
      'super_admin': sessionWithRoles(const <String>['super_admin']),
      'ff_support': sessionWithRoles(const <String>['ff_support']),
      'operator_owner': sessionWithRoles(const <String>['operator_owner']),
      'super_admin + ff_support': sessionWithRoles(const <String>[
        'ff_support',
        'super_admin',
      ]),
      'empty roles': sessionWithRoles(const <String>[]),
      'null session': null,
    };

    cases.forEach((label, session) {
      test('$label → helper result == old inline result', () {
        expect(
          helperShaped(session),
          equals(oldInline(session)),
          reason:
              'G7a must be byte-identical: '
              '.contains("super_admin") ≡ .contains(roleSuperAdmin)',
        );
      });
    });

    test('decision outcomes are the expected booleans', () {
      expect(helperShaped(cases['super_admin']), isTrue);
      expect(helperShaped(cases['super_admin + ff_support']), isTrue);
      expect(helperShaped(cases['ff_support']), isFalse);
      expect(helperShaped(cases['operator_owner']), isFalse);
      expect(helperShaped(cases['empty roles']), isFalse);
      expect(helperShaped(cases['null session']), isFalse);
    });
  });

  group('G7a grep-guard over admin_routes.dart active builders', () {
    late final String source;
    late final String activeSource;

    setUpAll(() {
      source = File('lib/admin/admin_routes.dart').readAsStringSync();

      // Strip every `// ignore: unused_element` legacy builder/class
      // body so the guard only inspects LIVE code. We walk from each
      // marker, find the first `{`, then track brace depth to its
      // matching close (same algorithm the G7a transform used).
      final lines = source.split('\n');
      final keep = <String>[];
      var i = 0;
      while (i < lines.length) {
        final line = lines[i];
        if (RegExp(r'^\s*//\s*ignore:\s*unused_element\s*$').hasMatch(line)) {
          // Skip the marker + the entire following declaration.
          var depth = 0;
          var opened = false;
          var j = i + 1;
          while (j < lines.length) {
            final open = '{'.allMatches(lines[j]).length;
            final close = '}'.allMatches(lines[j]).length;
            depth += open - close;
            if (open > 0) opened = true;
            if (opened && depth <= 0) break;
            j++;
          }
          i = j + 1; // resume after the dead declaration's close brace
          continue;
        }
        keep.add(line);
        i++;
      }
      activeSource = keep.join('\n');
    });

    test('zero bare roles.contains(\'super_admin\') in active builders', () {
      final bare = RegExp(
        r"\.roles\.contains\('super_admin'\)",
      ).allMatches(activeSource).length;
      expect(
        bare,
        0,
        reason:
            'Every active editing-gate site must call '
            '_isAdminSuperAdmin(session); only the 3 legacy '
            '// ignore: unused_element dead builders may still carry '
            'the bare literal (they are stripped before this check).',
      );
    });

    test(
      'the 3 dead-builder bare literals are still present in raw source',
      () {
        // Sanity: the dead builders were intentionally NOT changed, so
        // the raw (un-stripped) file still has exactly 3 bare sites.
        final bareRaw = RegExp(
          r"\.roles\.contains\('super_admin'\)",
        ).allMatches(source).length;
        expect(
          bareRaw,
          3,
          reason:
              '3 legacy // ignore: unused_element builders keep the bare '
              'literal (dead code, out of G7a scope).',
        );
      },
    );

    test('exactly 12 _isAdminSuperAdmin(session) call sites', () {
      // UX-parity Slice E1 moved the single, non-destructive Pricing
      // editing gate from `_isAdminSuperAdmin(session)` to the new
      // capability-key helper `adminCanEdit(session, requiredKey:
      // PermissionKeys.adminPricingTierEdit)` (extracted to
      // `lib/admin/admin_capability_gate.dart` so the frozen-ceiling
      // monolith shrinks instead of grows). That helper is
      // byte-identical for an EMPTY permissions set (it falls back to
      // the same super-admin role check), so the decision is
      // unchanged — only the call shape at that ONE site changed. The
      // active `_isAdminSuperAdmin(session)` count therefore dropped from
      // 14 to 13. The Integrations route later moved provider-key rotation
      // to `integration.key_rotate` + fresh MFA, dropping the active count
      // to 12.
      final calls = RegExp(
        r'_isAdminSuperAdmin\(session\)',
      ).allMatches(activeSource).length;
      expect(calls, 12);
    });

    test('exactly 2 bare adminCanEdit(session, ...) call sites', () {
      // UX-parity Slice E1 applied the key-first helper directly at ONE
      // site (the non-destructive, single-key Pricing route) — that bare
      // `adminCanEdit(session, ...)` call remains. The Audit Log route now
      // has a second active call site for the non-destructive view/export
      // keys so it mirrors ops permission behavior without bundling export
      // under the destructive MFA helper.
      //
      // UX-parity Slice E4 (operator-approved 2026-05-23) keyed the LIVE
      // destructive per-action gates too, but routes them through the
      // EXTRACTED `adminCanEditDestructive(...)` helper in
      // `lib/admin/admin_destructive_gate.dart` (which internally calls
      // `adminCanEdit` AND the MFA-fresh dimension), NOT through bare
      // `adminCanEdit` in the route file. Extraction keeps the
      // frozen-ceiling monolith from growing more than necessary. So the
      // count of BARE `adminCanEdit(session` calls in active builders
      // is now 2; the E4 destructive call sites are counted separately
      // below. The regex excludes
      // `_isAdminSuperAdmin`/`_isAdminMfaFresh`/`adminCanEditDestructive`
      // by requiring the bare `adminCanEdit(` token at a word boundary;
      // `\s*` spans the newline before the wrapped `session` argument.
      final calls = RegExp(
        r'(?<![\w_])adminCanEdit\(\s*session',
      ).allMatches(activeSource).length;
      expect(calls, 2);
    });

    test('exactly 3 adminCanEditDestructive(...) call sites (E4)', () {
      // UX-parity Slice E4 keyed the remaining live destructive per-action
      // gates via the extracted [adminCanEditDestructive] composer. Current
      // origin moved seeded-role gating behind `_canEditSeededRoles`, so the
      // route file has THREE direct call sites in active builders:
      //   * `_canEditSeededRoles` - admin.roles.edit_seeded
      //   * `_canRotateProviderKeys` - integration.key_rotate
      //   * `_buildAuditedSupportActions` - once inside a local
      //     `canDestructive(key)` closure that reset_mfa_factors and
      //     erase_pii forward to
      // Each composes the per-action key (key-first, super_admin
      // fallback) with the unchanged MFA-freshness dimension, so an EMPTY
      // permissions set stays byte-identical to the pre-slice role+MFA
      // outcome (proven by slice_e_admin_capability_key_gating_test.dart).
      // The three `// ignore: unused_element` legacy builders are stripped
      // before this check and were deliberately NOT touched.
      final calls = RegExp(
        r'(?<![\w_])adminCanEditDestructive\(',
      ).allMatches(activeSource).length;
      expect(calls, 3);
    });

    test('admin_destructive_gate import is present (E4 extraction)', () {
      expect(source, contains("import 'admin_destructive_gate.dart';"));
    });

    test('shared helper is defined and aliases the catalog constant', () {
      expect(
        source,
        contains('bool _isAdminSuperAdmin(AdminAuthSession? session) =>'),
      );
      expect(
        source,
        contains('session.roles.contains(PermissionKeys.roleSuperAdmin)'),
      );
    });

    test('permission_keys.dart import is present', () {
      expect(source, contains("import '../auth/permission_keys.dart';"));
    });
  });
}
