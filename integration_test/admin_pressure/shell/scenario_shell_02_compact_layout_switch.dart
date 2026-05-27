// integration_test/admin_pressure/shell/scenario_shell_02_compact_layout_switch.dart
//
// Shell-02: compact and wide layouts both mount the admin shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-02: compact and wide layout switch mounts cleanly',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await tester.binding.setSurfaceSize(const Size(680, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      expectAdminKey('admin_header_bar');

      await tester.binding.setSurfaceSize(const Size(1180, 900));
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      await expectAdminShellMounted(tester);
      expectAdminKey('admin_header_bar');
      expect(tap.overflowErrors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
