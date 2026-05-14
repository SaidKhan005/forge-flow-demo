// Wave 2 Q-2b path 3 — First-connect backfill complete celebration tile.
//
// Surface under test: the `notif.backfill.complete` inbox tile. The
// catalog title is "First Connect Backfill complete" and the body is
// "60 days of P.O.S. data has been uploaded and your initial
// benchmark is now live." This is the operator's celebratory moment
// after the Phase 8 connector backfills a fresh vendor connection.
//
// What this test asserts:
//   1. Seeding through `emitPushDelivery` with the canonical
//      `notif.backfill.complete` event_key lands a row.
//   2. The notifications screen renders the tile with the catalog
//      title.
//   3. The unread notifier sees the new row.
//   4. Catalog-exact title (no copy drift).
//
// Latency budget: the seed -> tile-render path stays under
// [kTileRenderBudget] (5s). Anything slower indicates a notifier-fan-out
// hang, which would prevent the bell badge from updating in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';
import 'package:forge_and_flow/services/app_notification_service.dart';

import '_harness.dart';

void main() {
  bootstrapInAppNotificationBinding();

  patrolWidgetTest(
    'path 3 — first-connect backfill complete fires the celebration tile',
    ($) async {
      final tester = $.tester;
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);
      resetNotificationServiceForTest();

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      final catalogEntry = kNotificationCatalog.firstWhere(
        (e) => e.eventKey == 'notif.backfill.complete',
        orElse: () => throw StateError(
          'notif.backfill.complete missing from kNotificationCatalog — '
          'catalog removed without a Q-2b update.',
        ),
      );

      final unreadBefore =
          AppNotificationService.instance.unreadCountNotifier.value;

      final stopwatch = Stopwatch()..start();
      final seeded = await seedNotification(
        type: catalogEntry.eventKey,
        eventKey:
            '${catalogEntry.eventKey}_${DateTime.now().millisecondsSinceEpoch}',
        title: catalogEntry.title,
        body: catalogEntry.description,
      );
      await tester.pump();
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(kTileRenderBudget),
        reason:
            'Backfill-complete seed -> notifier fan-out took '
            '${stopwatch.elapsed.inMilliseconds}ms, exceeds the '
            '${kTileRenderBudget.inMilliseconds}ms tile-render budget. '
            'The notifier is hanging on something.',
      );

      final unreadAfter =
          AppNotificationService.instance.unreadCountNotifier.value;
      expect(
        unreadAfter,
        greaterThan(unreadBefore),
        reason:
            'Unread badge did not advance after seeding a backfill-complete '
            'delivery. The notifier did not pick up the new row.',
      );

      await openNotificationsScreen(tester);
      expectNotificationsScreenMounted();

      expect(
        find.text(seeded.title),
        findsOneWidget,
        reason:
            'Backfill-complete tile title not visible on the '
            'notifications screen. Either the row did not persist or the '
            'list view did not refresh.',
      );

      expect(
        seeded.title,
        equals(catalogEntry.title),
        reason:
            'Catalog drift: harness title does not match catalog title.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow detected rendering backfill-complete tile:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
