// Wave 2 Q-2b path 1 — Invite-pending -> invite-claimed transition badge.
//
// Surface under test: the bell-icon badge + the NotificationsScreen
// tile that fires when a previously-pending operator invite is
// claimed (the recipient signs up and the role-grant lands). The
// production fire-path is `AppNotificationService.emitPushDelivery`
// out of the FCM message-data handler that the invite-claimed worker
// emits.
//
// Why this path matters: invites are the operator's primary team-grow
// affordance. If the bell does not surface the claim, the operator
// keeps poking the original invite link and either re-invites (audit
// row spam) or assumes the system silently dropped the claim.
//
// What this test asserts:
//   1. Seeding through `emitPushDelivery` lands a row in the inbox.
//   2. The notifications screen renders the tile with the
//      operator-visible plain-English copy.
//   3. The unread badge notifier sees the new row.
//
// Patrol layering: we use `patrolWidgetTest` so the test can be
// promoted to `patrolTest` (native lockscreen-shade tap) the moment
// a device is attached without rewriting the assertions.
// `patrolWidgetTest` falls back to `testWidgets` when no Patrol
// runtime is wired, so this file runs cleanly under stock
// `flutter test integration_test/in_app_notifications/`.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:forge_and_flow/services/app_notification_service.dart';

import '_harness.dart';

void main() {
  bootstrapInAppNotificationBinding();

  patrolWidgetTest(
    'path 1 — invite-pending to invite-claimed transition fires the badge',
    ($) async {
      final tester = $.tester;
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);
      resetNotificationServiceForTest();

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      final unreadBefore =
          AppNotificationService.instance.unreadCountNotifier.value;

      // Seed the invite-claimed delivery the same way the FCM
      // foreground handler would: the data payload's `type` /
      // `event_key` / `title` / `body` are the wire shape the
      // catalog pins. The wire `event_key` for an invite claim is
      // not in the published catalog (the catalog covers
      // server-side fanouts; invite claims are user-direct), so the
      // harness uses a stable wire string that mirrors how the
      // invite worker would tag it.
      final seeded = await seedNotification(
        type: 'invite_claimed',
        eventKey: 'invite_claimed_pat_q2b_001',
        title: 'Invite accepted',
        body:
            'Your team invite was accepted. The new teammate can sign '
            'in now.',
      );

      // Pump once so the unread notifier fans out to its listeners.
      await tester.pump();

      final unreadAfter =
          AppNotificationService.instance.unreadCountNotifier.value;
      expect(
        unreadAfter,
        greaterThan(unreadBefore),
        reason:
            'Unread badge did not advance after seeding an invite-claimed '
            'delivery. The notifier did not pick up the new row.',
      );

      await openNotificationsScreen(tester);
      expectNotificationsScreenMounted();

      expect(
        find.text(seeded.title),
        findsOneWidget,
        reason:
            'Invite-claimed tile title not visible on the notifications '
            'screen. Either the row did not persist or the list view did '
            'not refresh.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected rendering invite-claimed tile:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
