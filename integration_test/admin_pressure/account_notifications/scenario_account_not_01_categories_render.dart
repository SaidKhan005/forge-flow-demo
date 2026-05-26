// Stub — Scenario Account/Not-01 (notification categories).
//
// Placeholder asserting the admin shell mounts after a share-preview
// boot. Replace the TODO below with surface-specific assertions when
// landing this scenario.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Account/Not-01 (stub): share-preview boot leaves notification categories reachable',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for notification categories.
    },
  );
}
