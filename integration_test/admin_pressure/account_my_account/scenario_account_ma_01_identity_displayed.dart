// Stub — Scenario Account/MA-01 (my account identity).
//
// Placeholder asserting the admin shell mounts after a share-preview
// boot. Replace the TODO below with surface-specific assertions when
// landing this scenario.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Account/MA-01 (stub): share-preview boot leaves my account identity reachable',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for my account identity.
    },
  );
}
