// integration_test/admin_pressure/auth/scenario_auth_02_role_pill_and_identity.dart
//
// Lane A — Auth-02: header shows the super-admin identity chip and
// sign-out is visible/hidden according to share-preview rules.
//
// In ADMIN_SHARE_PREVIEW=true + ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true
// the shell signs in as `demo.super.admin@forgeflow.test` (see
// lib/admin/admin_auth_gate.dart:230). The header identity chip should
// render this email (truncated with ellipsis on narrow widths).
//
// Sign-out is intentionally hidden in share-preview mode — see
// lib/admin/admin_shell.dart:612 `_signOutControl` ("read-only demo
// walkthroughs never sign out"). This scenario locks both contracts in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Auth-02: header renders super-admin identity chip; sign-out hidden '
    'in share-preview mode',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      // Identity chip present (Key from lib/admin/admin_shell.dart:653).
      final identity = find.byKey(const Key('admin_header_identity'));
      expect(identity, findsOneWidget,
          reason: 'Header identity chip missing in share-preview boot.');

      // The identity widget is a Text node; pull its data and check the
      // email matches the seeded super-admin (see
      // lib/admin/admin_auth_gate.dart:230 — `signedInAsSuperAdmin`).
      final identityText = tester.widget<Text>(identity).data ?? '';
      expect(
        identityText.toLowerCase(),
        contains('forgeflow'),
        reason:
            'Identity chip should display the fixture super-admin email '
            '(demo.super.admin@forgeflow.test); got "$identityText".',
      );

      // Sign-out button hidden in share-preview mode (see
      // lib/admin/admin_shell.dart:612).
      expect(
        find.byKey(const Key('admin_header_signout')),
        findsNothing,
        reason:
            'Sign-out button must be hidden in share-preview mode — '
            'read-only walkthroughs never sign out.',
      );

      // No overflows from the identity / header layout.
      expect(tap.overflowErrors, isEmpty,
          reason:
              'Header layout overflowed: '
              '${tap.overflowErrors.map((e) => e.exception).join(', ')}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
