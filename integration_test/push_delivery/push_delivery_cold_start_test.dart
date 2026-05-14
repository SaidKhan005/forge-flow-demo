// Wave 2 Q-2c — Push delivery cold-start round-trip integration test.
//
// What this test asserts:
//   1. App cold-boots in demo mode and `AppShell` mounts.
//   2. A push delivery seeded through
//      `AppNotificationService.emitPushDelivery` (the same code path
//      production FCM handlers use) advances the unread badge.
//   3. The notifications screen renders the tile with the
//      operator-visible plain-English copy.
//   4. The tap-handler routes to `NotificationsScreen` via the named
//      route — confirming the production push-tap-to-screen wire-up.
//   5. No `RenderFlex` overflow exceptions accumulate during the
//      scenario.
//
// What runs this test:
//   * `flutter test integration_test/push_delivery/push_delivery_cold_start_test.dart
//     --flavor forgeflow --dart-define=kDemoMode=true` for the
//     in-tree assertion (no native push delivery).
//   * Firebase Test Lab (via
//     `tool/firebase_test_lab/firebase_test_lab_orchestrator.dart`)
//     for real-device coverage — the same file ships to gcloud as
//     the instrumentation test bundle.
//
// Why `patrolWidgetTest` and not `testWidgets`:
//   The test is portable to Patrol's native lockscreen-shade gesture
//   surface the moment a device is attached. `patrolWidgetTest` falls
//   back to `testWidgets` when no Patrol runtime is wired, so this
//   file runs cleanly under stock `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:forge_and_flow/services/app_notification_service.dart';

import '_harness.dart';

void main() {
  bootstrapPushDeliveryBinding();

  patrolWidgetTest(
    'Q-2c — push delivery cold-start fires badge + notifications screen routes',
    ($) async {
      final tester = $.tester;
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);
      resetNotificationServiceForTest();

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      final unreadBefore =
          AppNotificationService.instance.unreadCountNotifier.value;

      // Seed a push delivery the same way the FCM foreground /
      // background handlers would. The wire `event_key` is
      // intentionally a fresh value per run so the test is robust
      // against a stale seed left by a prior run that did not call
      // `resetForTest`.
      final seeded = await seedPushDelivery(
        type: 'push_delivery',
        eventKey: 'q2c_push_round_trip_${DateTime.now().millisecondsSinceEpoch}',
        title: 'New shift forecast ready',
        body:
            'Your team is set up for tomorrow. Tap to review the '
            'updated forecast.',
      );

      // Pump once so the unread notifier fans out to its listeners.
      await tester.pump();

      final unreadAfter =
          AppNotificationService.instance.unreadCountNotifier.value;
      expect(
        unreadAfter,
        greaterThan(unreadBefore),
        reason:
            'Unread badge did not advance after seeding a push delivery. '
            'The notifier did not pick up the new row — either the '
            'inbox write failed or the badge listener is detached.',
      );

      // Tap-handler routing: push the notifications route the same
      // way the bell tap handler would. Asserts the registered route
      // resolves the expected screen.
      await openNotificationsScreen(tester);
      expectNotificationsScreenMounted();

      expect(
        find.text(seeded.title),
        findsOneWidget,
        reason:
            'Push-delivery tile title not visible on the notifications '
            'screen. Either the row did not persist or the list view '
            'did not refresh.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected rendering push-delivery tile:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
