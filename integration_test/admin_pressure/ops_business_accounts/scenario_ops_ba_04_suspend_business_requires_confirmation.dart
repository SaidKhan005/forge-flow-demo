// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_04_suspend_business_requires_confirmation.dart
//
// Ops/BA-04: suspending a business account opens the audited reason gate
// and refuses an empty reason.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/BA-04: suspend-business requires an admin reason before it runs',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerBusinessScope(tester);

      final hadActiveBefore = isTextMounted('Active');

      await tapAdminKey(tester, 'admin_operator_suspend_button');
      expectAdminKey('admin_operator_suspend_dialog');
      expectAdminKey('admin_operator_suspend_reason');

      await tapAdminKey(tester, 'admin_operator_suspend_submit');
      expect(find.text('Add a reason before continuing.'), findsOneWidget);

      if (hadActiveBefore) {
        expect(isTextMounted('Active'), isTrue);
      }

      expect(tap.overflowErrors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
