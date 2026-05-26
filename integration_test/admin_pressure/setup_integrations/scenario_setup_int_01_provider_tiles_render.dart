// Stub — Scenario Setup/Int-01 (connected services provider tiles).
//
// Placeholder asserting the admin shell mounts after a share-preview
// boot. Replace the TODO below with surface-specific assertions when
// landing this scenario.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/Int-01 (stub): share-preview boot leaves connected services provider tiles reachable',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for connected services provider tiles.
    },
  );
}
