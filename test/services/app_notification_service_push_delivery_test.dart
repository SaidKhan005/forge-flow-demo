// W2.A — push-delivery extensions to AppNotificationService.
//
// Validates round-trip emit through emitPushDelivery, the unread-count
// notifier hydration, single-tile mark-as-read, and bulk markAllAsRead.
// Uses a fake in-memory repository so the test does not depend on the
// SqliteDatabase singleton or the per-platform sqflite FFI bootstrap.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/app_notification.dart';
import 'package:forge_and_flow/domain/repositories/app_notification_repository.dart';
import 'package:forge_and_flow/services/app_notification_service.dart';

class _FakeRepo implements AppNotificationRepository {
  final List<AppNotification> _rows = <AppNotification>[];
  final Map<String, String> _readAt = <String, String>{};

  AppNotification _withRead(AppNotification source) {
    final read = _readAt[source.notificationId];
    if (read == null) return source;
    return AppNotification(
      notificationId: source.notificationId,
      restaurantId: source.restaurantId,
      type: source.type,
      eventKey: source.eventKey,
      title: source.title,
      body: source.body,
      businessDate: source.businessDate,
      createdAt: source.createdAt,
      readAt: read,
    );
  }

  @override
  Future<void> insertIfAbsent(AppNotification notification) async {
    final exists = _rows.any(
      (r) =>
          r.restaurantId == notification.restaurantId &&
          r.eventKey == notification.eventKey,
    );
    if (exists) return;
    _rows.add(notification);
  }

  @override
  Future<List<AppNotification>> getNotifications(
    String restaurantId, {
    int limit = 20,
  }) async {
    final filtered = _rows
        .where((r) => r.restaurantId == restaurantId)
        .map(_withRead)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered.take(limit).toList();
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    if (_readAt.containsKey(notificationId)) return;
    _readAt[notificationId] = DateTime.now().toUtc().toIso8601String();
  }

  @override
  Future<void> markAllAsRead(String restaurantId) async {
    final ts = DateTime.now().toUtc().toIso8601String();
    for (final row in _rows.where((r) => r.restaurantId == restaurantId)) {
      _readAt.putIfAbsent(row.notificationId, () => ts);
    }
  }

  @override
  Future<int> getUnreadCount(String restaurantId) async {
    return _rows
        .where(
          (r) =>
              r.restaurantId == restaurantId &&
              !_readAt.containsKey(r.notificationId),
        )
        .length;
  }
}

void main() {
  const restaurantId = 'demo_restaurant_001';

  setUp(() {
    AppNotificationService.instance.resetForTest();
    AppNotificationService.instance.overrideRepositoryForTest(_FakeRepo());
  });

  tearDown(() {
    AppNotificationService.instance.resetForTest();
  });

  test('emitPushDelivery persists the notification and ticks unread count',
      () async {
    final svc = AppNotificationService.instance;
    await svc.start(restaurantId);
    expect(svc.unreadCountNotifier.value, 0);

    await svc.emitPushDelivery(
      restaurantId: restaurantId,
      type: 'push_delivery',
      eventKey: 'evt_1',
      title: 'Hello',
      body: 'Body',
      businessDate: '2026-05-07',
    );

    final list = await svc.getNotifications(restaurantId);
    expect(list, hasLength(1));
    expect(list.single.type, 'push_delivery');
    expect(list.single.eventKey, 'evt_1');
    expect(list.single.readAt, isNull);
    expect(svc.unreadCountNotifier.value, 1);
  });

  test('repeated emit with same event key dedupes through the repo', () async {
    final svc = AppNotificationService.instance;
    await svc.start(restaurantId);
    await svc.emitPushDelivery(
      restaurantId: restaurantId,
      type: 'push_delivery',
      eventKey: 'evt_dup',
      title: 'A',
      body: 'B',
      businessDate: '2026-05-07',
    );
    await svc.emitPushDelivery(
      restaurantId: restaurantId,
      type: 'push_delivery',
      eventKey: 'evt_dup',
      title: 'A',
      body: 'B',
      businessDate: '2026-05-07',
    );
    final list = await svc.getNotifications(restaurantId);
    expect(list, hasLength(1));
    expect(svc.unreadCountNotifier.value, 1);
  });

  test('markAsRead clears one badge unit and stamps the read tile', () async {
    final svc = AppNotificationService.instance;
    await svc.start(restaurantId);
    await svc.emitPushDelivery(
      restaurantId: restaurantId,
      type: 'push_delivery',
      eventKey: 'evt_a',
      title: 'A',
      body: 'A',
      businessDate: '2026-05-07',
    );
    await svc.emitPushDelivery(
      restaurantId: restaurantId,
      type: 'push_delivery',
      eventKey: 'evt_b',
      title: 'B',
      body: 'B',
      businessDate: '2026-05-07',
    );
    expect(svc.unreadCountNotifier.value, 2);

    final notifications = await svc.getNotifications(restaurantId);
    final first = notifications.first;
    await svc.markAsRead(first.notificationId);

    expect(svc.unreadCountNotifier.value, 1);
    final refreshed = await svc.getNotifications(restaurantId);
    final readEntry = refreshed.firstWhere(
      (n) => n.notificationId == first.notificationId,
    );
    expect(readEntry.readAt, isNotNull);
  });

  test('markAllAsRead zeros the badge', () async {
    final svc = AppNotificationService.instance;
    await svc.start(restaurantId);
    for (var i = 0; i < 3; i++) {
      await svc.emitPushDelivery(
        restaurantId: restaurantId,
        type: 'push_delivery',
        eventKey: 'evt_$i',
        title: 'T$i',
        body: 'B$i',
        businessDate: '2026-05-07',
      );
    }
    expect(svc.unreadCountNotifier.value, 3);

    await svc.markAllAsRead(restaurantId);

    expect(svc.unreadCountNotifier.value, 0);
    final refreshed = await svc.getNotifications(restaurantId);
    expect(refreshed.every((n) => n.readAt != null), isTrue);
  });

  test(
    'refreshUnreadCount hydrates the notifier when called without start',
    () async {
      final svc = AppNotificationService.instance;
      // Seed two unread rows directly via emit, then forget the activeId
      // by resetting and re-injecting the same repo (simulating cold boot).
      final repo = _FakeRepo();
      svc.overrideRepositoryForTest(repo);
      await repo.insertIfAbsent(
        AppNotification(
          notificationId: '${restaurantId}_evt_x',
          restaurantId: restaurantId,
          type: 'push_delivery',
          eventKey: 'evt_x',
          title: 'X',
          body: 'X',
          businessDate: '2026-05-07',
          createdAt: '2026-05-07T10:00:00.000Z',
        ),
      );

      expect(svc.unreadCountNotifier.value, 0);
      await svc.refreshUnreadCount(restaurantId);
      expect(svc.unreadCountNotifier.value, 1);
    },
  );
}
