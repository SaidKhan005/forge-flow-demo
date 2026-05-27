// integration_test/admin_pressure/account_notifications/scenario_account_not_01_categories_render.dart
//
// Account/Not-01: Notifications renders event categories and rows.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Account/Not-01: notification categories render', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminNotificationPreferencesRouteId);

    expectAdminKey('admin_notification_preferences_screen');
    expectAdminKey('admin_notification_preferences_header_info');
    expectAdminKey(
      'admin_notification_preferences_event_notif.backfill.complete',
    );
  });
}
