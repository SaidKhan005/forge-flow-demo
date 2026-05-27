// integration_test/admin_pressure/account_my_account/scenario_account_ma_01_identity_displayed.dart
//
// Lane E — Account/MA-01: the My account route renders the signed-in
// admin identity card with the fixture super-admin email.
//
// The My account screen scaffold tags its scroll surface with
// Key('admin_my_account_screen') (lib/admin/screens/my_account_admin_screen.dart:207)
// and the identity card with Key('admin_my_account_identity_card')
// (:418). In share-preview as super-admin the identity is
// `demo.super.admin@forgeflow.test` per
// lib/admin/admin_auth_gate.dart:230.
//
// This scenario boots the shell, navigates to My account, and asserts:
//   - the screen scaffold + identity card mount,
//   - the seeded super-admin email is visible in the identity card,
//   - one of the identity layout variants (two-column wide or
//     single-column narrow) is in the tree,
//   - no RenderFlex overflow during identity rendering.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Account/MA-01: My account route renders identity card with the '
    'seeded super-admin email',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminMyAccountRouteId);

      // Screen scaffold mounted (Key from
      // lib/admin/screens/my_account_admin_screen.dart:207).
      expect(
        find.byKey(const Key('admin_my_account_screen')),
        findsOneWidget,
        reason:
            'My account screen scaffold (Key=admin_my_account_screen) did '
            'not mount after navigating to the My account route.',
      );

      // Identity card mounted (Key from :418).
      expect(
        find.byKey(const Key('admin_my_account_identity_card')),
        findsOneWidget,
        reason:
            'Identity card (Key=admin_my_account_identity_card) is missing '
            'from the My account screen.',
      );

      // Exactly one of the two layout variants should be in the tree —
      // two-column wide (>= 800 px) or single-column narrow.
      final wide =
          find.byKey(const Key('admin_my_account_identity_two_column'));
      final narrow =
          find.byKey(const Key('admin_my_account_identity_single_column'));
      expect(
        wide.evaluate().isNotEmpty || narrow.evaluate().isNotEmpty,
        isTrue,
        reason:
            'Neither identity layout variant '
            '(admin_my_account_identity_two_column / _single_column) is '
            'in the tree — the LayoutBuilder did not render.',
      );

      // The seeded super-admin email should be visible somewhere in
      // the identity card (or its surrounding header). The fixture
      // identity is demo.super.admin@forgeflow.test
      // (lib/admin/admin_auth_gate.dart:230).
      expect(
        isTextMounted('demo.super.admin@forgeflow.test'),
        isTrue,
        reason:
            'My account did not display the seeded super-admin email — '
            'either the screen did not mount the identity or the '
            'share-preview fixture identity changed.',
      );

      // No overflows on the My account layout.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'My account screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
