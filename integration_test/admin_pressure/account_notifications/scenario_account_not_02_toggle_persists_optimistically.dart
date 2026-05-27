// integration_test/admin_pressure/account_notifications/scenario_account_not_02_toggle_persists_optimistically.dart
//
// Account/Not-02: a notification toggle can be changed without leaving the route.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Account/Not-02: notification toggle changes in place', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminNotificationPreferencesRouteId);

    const toggleKey =
        'admin_notification_preferences_toggle_notif.backfill.complete_push';
    expectAdminKey(toggleKey);
    await tapAdminKey(tester, toggleKey);

    expectAdminKey('admin_notification_preferences_screen');
    expect(find.textContaining('Notifications'), findsAtLeast(1));
  });
}
