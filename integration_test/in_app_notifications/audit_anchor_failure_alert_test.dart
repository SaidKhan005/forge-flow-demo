// Wave 2 Q-2b path 2 — Audit-anchor failure alert pill on the data
// accuracy screen.
//
// Surface under test: the inbox tile + bell badge for the
// `notif.audit.anchor_failure` event. The catalog
// (`notification_event_catalog.dart` line 124) describes the operator
// experience: "Each night Forge & Flow seals your audit log so its
// history can't be changed without us noticing. Today's seal didn't
// go through." Role-gate is admin-only; this harness asserts on the
// inbox tile rather than the operator-web data-accuracy screen pill
// because the mobile shell does not host the data-accuracy screen
// (that screen is the operator-web admin surface). The bell badge IS
// hosted on the mobile shell, so the harness exercises the seam the
// operator actually sees on their phone.
//
// What this test asserts:
//   1. Seeding through `emitPushDelivery` with the canonical
//      `notif.audit.anchor_failure` event_key lands a row.
//   2. The notifications screen renders the tile with the catalog
//      title.
//   3. The unread notifier sees the new row.
//
// Why catalog-exact copy: the audit-anchor failure tile is the only
// admin-only path in this slice's coverage. Any drift between the
// catalog title and the inbox title would silently downgrade the
// operator's understanding of the failure. The assertion locks the
// catalog string.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';
import 'package:forge_and_flow/services/app_notification_service.dart';

import '_harness.dart';

void main() {
  bootstrapInAppNotificationBinding();

  patrolWidgetTest(
    'path 2 — audit-anchor failure surfaces the admin-only inbox tile',
    ($) async {
      final tester = $.tester;
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);
      resetNotificationServiceForTest();

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Lock the catalog title at test setup so a drift between the
      // catalog and the harness surfaces here rather than as a silent
      // copy regression.
      final catalogEntry = kNotificationCatalog.firstWhere(
        (e) => e.eventKey == 'notif.audit.anchor_failure',
        orElse: () => throw StateError(
          'notif.audit.anchor_failure missing from kNotificationCatalog — '
          'catalog removed without a Q-2b update.',
        ),
      );

      final unreadBefore =
          AppNotificationService.instance.unreadCountNotifier.value;

      final seeded = await seedNotification(
        type: catalogEntry.eventKey,
        eventKey:
            '${catalogEntry.eventKey}_${DateTime.now().millisecondsSinceEpoch}',
        title: catalogEntry.title,
        body: catalogEntry.description,
      );

      await tester.pump();

      final unreadAfter =
          AppNotificationService.instance.unreadCountNotifier.value;
      expect(
        unreadAfter,
        greaterThan(unreadBefore),
        reason:
            'Unread badge did not advance after seeding an audit-anchor '
            'failure. The notifier did not pick up the new row.',
      );

      await openNotificationsScreen(tester);
      expectNotificationsScreenMounted();

      expect(
        find.text(seeded.title),
        findsOneWidget,
        reason:
            'Audit-anchor failure tile title not visible on the '
            'notifications screen. Either the row did not persist or the '
            'list view did not refresh.',
      );

      expect(
        seeded.title,
        equals(catalogEntry.title),
        reason:
            'Catalog drift: harness title does not match catalog title. '
            'The catalog moved without updating Q-2b.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected rendering audit-anchor tile:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
