// A9.SY3 — Push cold-start persistence tests.
//
// Validates that [MobilePushRouteIntentController] persists intents to
// [MobilePushIntentDiskStore] and that no intent is lost when
// takePendingIntents runs before the async cold-start intent arrives.
//
// Uses [InMemoryMobilePushIntentStore] so no real SharedPreferences I/O.
//
// Scenario: the cold-start race is that getInitialMessage() is async,
// and if it completes after the stream listener is set up, the intent
// goes only to the stream (good path). The disk store guards against
// a narrower race: intent was added to _pending (no listener yet) but
// a subsequent crash or process restart means the in-memory list was
// lost. Persisting to disk lets the next process drain it.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mobile_push/mobile_push_notification_service.dart';

void main() {
  test(
    'SY3-a: intent added to in-memory pending is also persisted to disk',
    () async {
      final store = InMemoryMobilePushIntentStore();
      final controller = MobilePushRouteIntentController(diskStore: store);

      const intent = MobilePushRouteIntent.notifications(
        notificationId: 'notif-001',
      );
      controller.add(intent);

      // Let microtasks run so persistIntent completes.
      await Future<void>.microtask(() {});

      // Disk store should contain the intent.
      expect(store.stored, hasLength(1));
      expect(
        store.stored.first.destination,
        MobilePushRouteDestination.notifications,
      );
      expect(store.stored.first.notificationId, 'notif-001');

      await controller.dispose();
    },
  );

  test(
    'SY3-b: takePendingIntents drains in-memory list and clears disk store',
    () async {
      final store = InMemoryMobilePushIntentStore();
      final controller = MobilePushRouteIntentController(diskStore: store);

      const intent = MobilePushRouteIntent.notifications(
        notificationId: 'notif-002',
      );
      controller.add(intent);
      await Future<void>.microtask(() {});

      final taken = controller.takePendingIntents();

      expect(taken, hasLength(1));
      expect(taken.first.notificationId, 'notif-002');

      // Allow clearPersistedIntents microtask to run.
      await Future<void>.microtask(() {});

      // Disk store should be cleared after drain.
      expect(store.stored, isEmpty);

      await controller.dispose();
    },
  );

  test(
    'SY3-c: disk drain re-publishes persisted intents to active stream listeners',
    () async {
      // Simulate: an intent was left on disk by a prior process run
      // (cold-start crash scenario). When a stream listener subscribes
      // and takePendingIntents is called, the disk drain re-publishes
      // the intent via the stream.

      final store = InMemoryMobilePushIntentStore();

      // Pre-seed the disk store as if a prior process had persisted it.
      const coldStartIntent = MobilePushRouteIntent.notifications(
        notificationId: 'notif-cold-start',
      );
      await store.persistIntent(coldStartIntent);
      expect(store.stored, hasLength(1));

      final controller = MobilePushRouteIntentController(diskStore: store);

      // Set up a stream listener (simulating screen subscription).
      final received = <MobilePushRouteIntent>[];
      final sub = controller.intents.listen(received.add);
      addTearDown(sub.cancel);

      // Call takePendingIntents — triggers _drainDiskAsync.
      final taken = controller.takePendingIntents();
      // In-memory is empty on first call.
      expect(taken, isEmpty);

      // Let the async drain complete.
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});

      // The persisted intent should be re-published to the stream.
      expect(received, hasLength(1));
      expect(received.first.notificationId, 'notif-cold-start');

      await controller.dispose();
    },
  );

  test(
    'SY3-d: multiple intents all survive round-trip through disk store',
    () async {
      final store = InMemoryMobilePushIntentStore();
      final controller = MobilePushRouteIntentController(diskStore: store);

      // Add three intents without a listener so they go to pending + disk.
      const i1 = MobilePushRouteIntent.notifications(notificationId: 'a');
      const i2 = MobilePushRouteIntent.notifications(notificationId: 'b');
      const i3 = MobilePushRouteIntent.notifications(notificationId: null);

      controller.add(i1);
      controller.add(i2);
      controller.add(i3);
      await Future<void>.microtask(() {});

      expect(store.stored, hasLength(3));

      final taken = controller.takePendingIntents();
      expect(taken, hasLength(3));
      expect(
        taken.map((i) => i.notificationId).toList(),
        containsAll(['a', 'b', null]),
      );

      await controller.dispose();
    },
  );
}
