// integration_test/admin_pressure/shell/scenario_shell_04_signout_button_present.dart
//
// Shell-04: share-preview keeps sign-out hidden and identity visible.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Shell-04: sign-out is hidden in share-preview', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);

    expectAdminKey('admin_header_identity');
    expectAdminKey('admin_header_signout', matcher: findsNothing);
  });
}
