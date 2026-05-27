// integration_test/admin_pressure/account_notifications/scenario_account_not_01_categories_render.dart
//
// Lane E — Account/Not-01: the Notifications route renders the full
// NotificationCategory catalog as section panels. The screen scaffold
// tags itself with Key('admin_notification_preferences_screen')
// (lib/admin/screens/admin_notification_preferences_screen.dart:295)
// and each category renders as
// Key('admin_notification_preferences_category_<categoryName>') (:428).
//
// The categories enum lives at
// lib/domain/models/notification_event_catalog.dart:28
// (backfill, vendor, audit, shift, plan, security).
//
// This scenario asserts the screen mounts and AT LEAST ONE category
// panel renders. We use "at least one" instead of "all six" because
// the admin screen renders only categories that have catalog entries
// — gating one of them in the future must not break this scenario.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Account/Not-01: Notifications route mounts and renders at least '
    'one category section panel',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminNotificationPreferencesRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_notification_preferences_screen')),
        findsOneWidget,
        reason:
            'Notification preferences screen scaffold did not mount after '
            'navigating to the Notifications route.',
      );

      // At least one category panel rendered. The categories enum lives
      // at lib/domain/models/notification_event_catalog.dart:28.
      var foundCategory = false;
      for (final category in NotificationCategory.values) {
        final categoryKey =
            Key('admin_notification_preferences_category_${category.name}');
        if (find.byKey(categoryKey).evaluate().isNotEmpty) {
          foundCategory = true;
          break;
        }
      }
      expect(
        foundCategory,
        isTrue,
        reason:
            'No notification category panels rendered — the screen mounted '
            'but the catalog produced zero category sections. Expected at '
            'least one of '
            '${NotificationCategory.values.map((c) => c.name).join(", ")}.',
      );

      // Header info button present (Key from :353).
      expect(
        find.byKey(const Key('admin_notification_preferences_header_info')),
        findsOneWidget,
        reason: 'Notifications header info button is missing.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Notifications screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
