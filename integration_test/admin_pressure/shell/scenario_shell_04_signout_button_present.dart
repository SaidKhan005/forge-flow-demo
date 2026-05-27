// integration_test/admin_pressure/shell/scenario_shell_04_signout_button_present.dart
//
// Lane A — Shell-04 (regression): share-preview mode renders the
// admin header identity chip but MUST keep the sign-out control
// hidden. Share-preview is a read-only demo walkthrough — exposing
// sign-out would let the demo session terminate itself with no
// recovery, and there is no real account to sign out of.
//
// Keys:
//   - admin_header_identity (lib/admin/admin_shell.dart:653)
//   - admin_header_signout  (:615 compact / :624 wide — must NOT be in tree
//                            in share-preview, see :612 guard)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-04 (regression): share-preview header renders identity chip '
    'but the sign-out control is NOT in the tree (compact + wide)',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      // Wide first.
      await tester.binding.setSurfaceSize(const Size(1180, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      // Identity chip present.
      expect(
        find.byKey(const Key('admin_header_identity')),
        findsOneWidget,
        reason:
            'Identity chip missing from the admin header in wide mode — '
            'the share-preview fixture identity is not visible.',
      );

      // Sign-out NOT present in wide mode.
      expect(
        find.byKey(const Key('admin_header_signout')),
        findsNothing,
        reason:
            'Sign-out control was visible in share-preview (wide) — the '
            'read-only demo would let the session terminate itself.',
      );

      // Resize to compact and re-check both invariants.
      await tester.binding.setSurfaceSize(const Size(680, 900));
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);
      await expectAdminShellMounted(tester);

      expect(
        find.byKey(const Key('admin_header_identity')),
        findsOneWidget,
        reason:
            'Identity chip missing from the admin header in compact mode.',
      );
      expect(
        find.byKey(const Key('admin_header_signout')),
        findsNothing,
        reason:
            'Sign-out control was visible in share-preview (compact) — '
            'the read-only demo would let the session terminate itself.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Header overflowed during sign-out visibility check: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
