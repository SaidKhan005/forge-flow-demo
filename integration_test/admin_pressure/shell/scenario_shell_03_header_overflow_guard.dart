// integration_test/admin_pressure/shell/scenario_shell_03_header_overflow_guard.dart
//
// Lane A — Shell-03 / regression: header layout must not overflow at
// the 720 px compact-shell breakpoint or at typical narrow desktop
// widths.
//
// Background: the 2026-05-22 manual pressure test reported a 76 px
// RenderFlex overflow in the admin header (`Key=admin_header_bar`) at
// the compact / narrow viewport. The header is a Row with three
// Expanded zones plus a fixed-width scope picker; the picker width
// schedule lives at lib/admin/admin_shell.dart:635 (`_pickerWidthFor`).
//
// This scenario boots the admin app, forces several viewport widths
// across the compact / standard / wide thresholds, and asserts no
// RenderFlex overflow fires from the header. Any future regression on
// the header constraint maths will trip this guard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

const List<Size> _kViewportProbe = <Size>[
  // Just under the compact-shell breakpoint (720 px).
  Size(680, 900),
  // Just over the compact-shell breakpoint.
  Size(760, 900),
  // Typical narrow laptop (the historical overflow zone).
  Size(980, 900),
  // Standard laptop.
  Size(1180, 900),
  // Wide desktop — the picker pulls to 540 px here.
  Size(1480, 900),
];

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-03 (regression): admin header bar does not RenderFlex-overflow '
    'across compact / narrow / wide viewports',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      // Start at a known-wide viewport so the boot is clean.
      await tester.binding.setSurfaceSize(_kViewportProbe.last);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      // Confirm the header is in the tree (Key from
      // lib/admin/admin_shell.dart:506).
      expect(
        find.byKey(const Key('admin_header_bar')),
        findsOneWidget,
        reason:
            'Header bar (Key=admin_header_bar) missing — share-preview '
            'wiring failed before we could exercise the layout.',
      );

      for (final size in _kViewportProbe) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        await pumpUntil(tester, budget: kAdminNavBudget);
        await expectAdminShellMounted(tester);
        expect(
          tap.overflowErrors,
          isEmpty,
          reason:
              'RenderFlex overflow detected after resizing to '
              '${size.width.toInt()}x${size.height.toInt()}: '
              '${tap.overflowErrors.map((e) => e.exception).join(', ')}. '
              'This is the 2026-05-22 admin-header overflow regression — '
              'see lib/admin/admin_shell.dart:506 _AdminHeaderBar.',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
