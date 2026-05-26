// Stub — Lane A — Shell-02: compact layout switch boundary (720 px).
//
// The shell flips from the wide left-nav layout to the compact top-nav
// at the _kCompactShellBreakpoint (720 px) in
// lib/admin/admin_shell.dart:26. This stub boots the shell, mounts,
// and leaves a TODO for fleshing out the layout-flip assertions
// (Key=admin_compact_nav and Key=admin_side_nav presence depending on
// width).

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-02 (stub): compact-vs-wide layout flip at 720 px boundary',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for compact/wide
      // layout flip. Walk surface size around 720 px and assert
      // admin_compact_nav vs admin_side_nav presence flips.
    },
  );
}
