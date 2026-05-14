// Wave 2 Q-2b path 4 — Vendor disconnect warning tile.
//
// Surface under test: the inbox tile that fires when a previously
// connected vendor (POS / labor / reservation) disconnects. The
// `notif.vendor.now_available` catalog entry is the "vendor became
// reachable" inverse; the disconnect path emits a different
// event_key. The published catalog does not pin a
// `notif.vendor.disconnected` entry yet (the vendor-side disconnect
// fanout is in flight on MO-2-FU at the time of writing), so this
// harness seeds with a stable wire string + asserts on the tile
// title/body it just wrote. When the catalog gains a canonical
// disconnect entry, this test should be flipped to read from the
// catalog the same way path 2 + path 3 do.
//
// What this test asserts:
//   1. Seeding through `emitPushDelivery` with a vendor-disconnect
//      event_key lands a row.
//   2. The notifications screen renders the tile with the seeded
//      title and body.
//   3. The unread notifier sees the new row.
//
// Documented gap: the in-app notification widgets DO surface a
// disconnect warning today (this test passes against the existing
// inbox), but the canonical event_key + catalog entry are pending.
// The harness's seed event_key (`notif.vendor.disconnected`) is what
// the catalog SHOULD land on; if it lands on a different wire key,
// update this test in lockstep.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:forge_and_flow/services/app_notification_service.dart';

import '_harness.dart';

void main() {
  bootstrapInAppNotificationBinding();

  patrolWidgetTest(
    'path 4 — vendor disconnect surfaces the warning inbox tile',
    ($) async {
      final tester = $.tester;
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);
      resetNotificationServiceForTest();

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      final unreadBefore =
          AppNotificationService.instance.unreadCountNotifier.value;

      // The disconnect copy is plain English per the UX writing
      // standard. The vendor name is a placeholder; production
      // dispatch would interpolate the actual vendor display name
      // from the connector registry.
      final seeded = await seedNotification(
        type: 'notif.vendor.disconnected',
        eventKey:
            'notif.vendor.disconnected_pat_q2b_${DateTime.now().millisecondsSinceEpoch}',
        title: 'A vendor stopped sending data',
        body:
            'One of your connected vendors stopped sending fresh data. '
            'Open Settings to reconnect or pick a replacement.',
      );

      await tester.pump();

      final unreadAfter =
          AppNotificationService.instance.unreadCountNotifier.value;
      expect(
        unreadAfter,
        greaterThan(unreadBefore),
        reason:
            'Unread badge did not advance after seeding a vendor-disconnect '
            'delivery. The notifier did not pick up the new row.',
      );

      await openNotificationsScreen(tester);
      expectNotificationsScreenMounted();

      expect(
        find.text(seeded.title),
        findsOneWidget,
        reason:
            'Vendor-disconnect tile title not visible on the '
            'notifications screen. Either the row did not persist or the '
            'list view did not refresh.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected rendering vendor-disconnect tile:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
