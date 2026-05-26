// Stub — Lane A — Shell-04: sign-out button present in live (non
// share-preview) mode.
//
// In share-preview mode the sign-out button is intentionally hidden
// (see scenario_auth_02). This stub is the inverse: a live build
// should render Key=admin_header_signout. Hard to drive from this
// suite without flipping the share-preview dart-define mid-run — left
// as a stub until a separate live-mode lane exists.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-04 (stub): sign-out affordance gating across share-preview '
    'vs live admin builds',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      // TODO(admin-pressure): flesh out assertions for sign-out gating
      // — requires a separate live-mode lane that builds without
      // ADMIN_SHARE_PREVIEW set.
    },
  );
}
