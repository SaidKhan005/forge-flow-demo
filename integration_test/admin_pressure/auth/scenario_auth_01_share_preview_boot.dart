// integration_test/admin_pressure/auth/scenario_auth_01_share_preview_boot.dart
//
// Lane A — Auth-01: cold boot in share-preview mode lands on the admin
// shell with no login screen, no Firebase, no proxy.
//
// Verifies: the three dart-defines together (ADMIN_SHARE_PREVIEW,
// ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN, ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH)
// drive main_admin.dart through the share-preview branch, the admin
// shell scaffold mounts, the demo banner is present, and the seeded
// super-admin identity chip is rendered in the header.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Auth-01: cold boot in share-preview mode mounts the admin shell '
    'without a login screen',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);

      // Assertion 1: admin shell mounted.
      await expectAdminShellMounted(tester);

      // Assertion 2: identity chip in the header is the seeded
      // super-admin's email. Key from lib/admin/admin_shell.dart:653.
      expect(
        find.byKey(const Key('admin_header_identity')),
        findsOneWidget,
        reason:
            'Header identity chip (Key=admin_header_identity) is missing — '
            'share-preview fixture identity was not threaded into the shell.',
      );

      // Assertion 3: demo banner present. Key from
      // lib/admin/widgets/admin_demo_banner.dart:38.
      expect(
        find.byKey(const Key('admin_demo_banner')),
        findsOneWidget,
        reason:
            'AdminDemoBanner missing — share-preview should always render '
            'the demo banner so the operator knows fixtures are in use.',
      );

      // Assertion 4: no RenderFlex overflows on boot. The 2026-05-22
      // pressure test surfaced a 76 px header overflow; this lane is
      // the canary for "boot is clean".
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflows detected on admin cold-boot: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
