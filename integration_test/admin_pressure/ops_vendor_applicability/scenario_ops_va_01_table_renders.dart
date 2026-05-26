// Stub — Scenario Ops/VA-01 (vendor applicability table).
//
// Placeholder asserting the admin shell mounts after a share-preview
// boot. Replace the TODO below with surface-specific assertions when
// landing this scenario.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/VA-01 (stub): share-preview boot leaves vendor applicability table reachable',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for vendor applicability table.
    },
  );
}
