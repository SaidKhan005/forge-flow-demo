// G30 (cross-surface parity v1) — CI tripwire for the bare-string →
// `PermissionKeys` constant aliasing in
// `lib/operator_web/auth/firebase_operator_web_auth_source.dart`.
//
// Spec: docs/_audits/cross_surface_parity_v1/g7_permission_convergence_spec.md §2.
//
// G30 is *pure aliasing*: the console-access / role-inference logic in
// `_inferRoles` and `_hasConsoleAccess` now references the frozen
// `PermissionKeys` catalog constants instead of bare permission-string
// literals. They are byte-equal today, so behaviour is unchanged. The
// risk this guards against is a *future* catalog rename silently
// desyncing the auth source while per-screen gates (already
// catalog-aliased) stay correct.
//
// Two assertions:
//   1. Constant-equality — each replaced literal still equals its
//      `PermissionKeys` constant. A future rename of the constant's
//      *value* trips this and forces the auth-source decision to be
//      re-examined.
//   2. Source grep-guard — no bare literal of those four keys remains
//      in the auth source. A future hand-edit that reintroduces a bare
//      literal (re-opening the desync hole) trips this.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  group('G30 — operator-web auth source permission-string aliasing', () {
    test('replaced literals are byte-equal to their PermissionKeys '
        'constants (catalog-rename tripwire)', () {
      expect('integrations.configure', PermissionKeys.integrationsConfigure);
      expect('team.users.view', PermissionKeys.teamUsersView);
      expect('admin.users.view', PermissionKeys.adminUsersView);
      expect('forgeflow.settings.view', PermissionKeys.forgeflowSettingsView);
    });

    test('no bare literal of the four G30 keys remains in '
        'firebase_operator_web_auth_source.dart', () {
      // Resolve relative to the test working directory (repo root under
      // `flutter test`).
      final source = File(
        'lib/operator_web/auth/firebase_operator_web_auth_source.dart',
      );
      expect(
        source.existsSync(),
        isTrue,
        reason: 'Expected auth source at ${source.path} '
            '(cwd=${Directory.current.path})',
      );
      final text = source.readAsStringSync();

      // Single-quoted Dart string literals for the four catalog keys.
      const bannedLiterals = <String>[
        "'integrations.configure'",
        "'team.users.view'",
        "'admin.users.view'",
        "'forgeflow.settings.view'",
      ];
      for (final literal in bannedLiterals) {
        expect(
          text.contains(literal),
          isFalse,
          reason: 'Bare permission literal $literal must be referenced '
              'via the PermissionKeys catalog constant (G30). A bare '
              'literal re-opens the catalog-rename desync the per-screen '
              'gates already avoid.',
        );
      }

      // Sanity: the constants are actually wired in (guards against a
      // future revert that drops the references *and* the literals).
      expect(
        text.contains('PermissionKeys.integrationsConfigure'),
        isTrue,
      );
      expect(text.contains('PermissionKeys.teamUsersView'), isTrue);
      expect(text.contains('PermissionKeys.adminUsersView'), isTrue);
      expect(
        text.contains('PermissionKeys.forgeflowSettingsView'),
        isTrue,
      );
    });
  });
}
