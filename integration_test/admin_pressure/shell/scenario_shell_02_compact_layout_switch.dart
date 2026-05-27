// integration_test/admin_pressure/shell/scenario_shell_02_compact_layout_switch.dart
//
// Lane A — Shell-02: switching between the compact (< 720 px) and wide
// (>= 1180 px) viewports keeps the admin shell mounted, keeps the
// header bar in the tree, and emits no RenderFlex overflows.
//
// Background: the admin shell rebuilds its nav rail vs compact-drawer
// layout at the 720 px breakpoint, and its header picker resizes
// across 980 / 1180 / 1440 (see lib/admin/admin_shell.dart:635
// _pickerWidthFor). Resizing rebuilds child widgets; any future
// regression that loses the header or fails the layout swap will
// trip this guard.
//
// Keys:
//   - admin_shell_scaffold (lib/admin/admin_shell.dart:270 — via harness)
//   - admin_header_bar     (:506)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-02: compact -> wide -> compact viewport switch keeps shell '
    'mounted with no RenderFlex overflow',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      // Boot in compact (under the 720 px breakpoint).
      await tester.binding.setSurfaceSize(const Size(680, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      expect(
        find.byKey(const Key('admin_header_bar')),
        findsOneWidget,
        reason: 'Header bar missing after compact boot.',
      );

      // Resize to wide.
      await tester.binding.setSurfaceSize(const Size(1180, 900));
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);
      await expectAdminShellMounted(tester);
      expect(
        find.byKey(const Key('admin_header_bar')),
        findsOneWidget,
        reason: 'Header bar lost during compact -> wide resize.',
      );

      // Resize back to compact — verify the swap is symmetric.
      await tester.binding.setSurfaceSize(const Size(680, 900));
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);
      await expectAdminShellMounted(tester);
      expect(
        find.byKey(const Key('admin_header_bar')),
        findsOneWidget,
        reason: 'Header bar lost during wide -> compact resize.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected during compact <-> wide layout '
            'switch: ${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
