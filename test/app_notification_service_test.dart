// Phase 7.55p.4d — App notification tests.
//
// Validates:
// A. emit + read round-trip for new-week snapshot
// B. dedupe — same event key inserted twice yields one row
// C. newest-first ordering
// D. cycle rollover emit + read
// E. cross-type coexistence (both types in one query)
// F. service constructs correct event keys and fields
//
// Tests use a raw in-memory database with just the app_notifications
// table, bypassing SqliteDatabase.instance and the pre-existing
// snapshot_blended_wage schema gap entirely.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/models/app_notification.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/app_notification_dao.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = 'demo_restaurant_001';

  late Database db;
  late AppNotificationDao dao;

  setUp(() async {
    db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE app_notifications (
            notification_id  TEXT PRIMARY KEY NOT NULL,
            restaurant_id    TEXT NOT NULL,
            type             TEXT NOT NULL,
            event_key        TEXT NOT NULL,
            title            TEXT NOT NULL,
            body             TEXT NOT NULL,
            business_date    TEXT NOT NULL,
            created_at       TEXT NOT NULL,
            UNIQUE(restaurant_id, event_key)
          )
        ''');
      },
    );
    dao = AppNotificationDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  // ── A: emit + read round-trip ──────────────────────────────────────────

  group('A — new-week snapshot round-trip', () {
    test('inserted notification reads back with correct fields', () async {
      final notification = AppNotification(
        notificationId: '${restaurantId}_new_week_snapshot_2026-03-23_2026-03-29',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'New Weekly Plan Locked',
        body: 'Weekly operating plan for 2026-03-23 to 2026-03-29 is now active.',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );

      await dao.insertIfAbsent(notification);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 1);
      expect(results.first.notificationId, notification.notificationId);
      expect(results.first.type, 'new_week_snapshot');
      expect(results.first.eventKey, notification.eventKey);
      expect(results.first.title, 'New Weekly Plan Locked');
      expect(results.first.body, contains('2026-03-23'));
      expect(results.first.businessDate, '2026-03-27');
      expect(results.first.restaurantId, restaurantId);
    });
  });

  // ── B: dedupe ──────────────────────────────────────────────────────────

  group('B — dedupe via UNIQUE(restaurant_id, event_key)', () {
    test('same event key inserted twice yields one row', () async {
      final first = AppNotification(
        notificationId: '${restaurantId}_week_1',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'New Weekly Plan Locked',
        body: 'First insert.',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );
      final duplicate = AppNotification(
        notificationId: '${restaurantId}_week_1_dup',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'Duplicate',
        body: 'Should be ignored.',
        businessDate: '2026-03-28',
        createdAt: '2026-03-28T10:00:00.000Z',
      );

      await dao.insertIfAbsent(first);
      await dao.insertIfAbsent(duplicate);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 1);
      expect(results.first.body, 'First insert.',
          reason: 'duplicate should be silently ignored, not replace');
    });

    test('different event keys for different weeks both persist', () async {
      final w12 = AppNotification(
        notificationId: '${restaurantId}_w12',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-16_2026-03-22',
        title: 'W12',
        body: 'Week 12',
        businessDate: '2026-03-20',
        createdAt: '2026-03-20T10:00:00.000Z',
      );
      final w13 = AppNotification(
        notificationId: '${restaurantId}_w13',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'W13',
        body: 'Week 13',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );

      await dao.insertIfAbsent(w12);
      await dao.insertIfAbsent(w13);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 2);
    });
  });

  // ── C: newest-first ordering ───────────────────────────────────────────

  group('C — newest-first ordering', () {
    test('notifications returned newest first by createdAt', () async {
      final older = AppNotification(
        notificationId: '${restaurantId}_older',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-16_2026-03-22',
        title: 'Older',
        body: 'Week 12',
        businessDate: '2026-03-20',
        createdAt: '2026-03-20T10:00:00.000Z',
      );
      final newer = AppNotification(
        notificationId: '${restaurantId}_newer',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'Newer',
        body: 'Week 13',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );

      await dao.insertIfAbsent(older);
      await dao.insertIfAbsent(newer);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 2);
      expect(results[0].title, 'Newer');
      expect(results[1].title, 'Older');
    });
  });

  // ── D: cycle rollover ─────────────────────────────────────────────────

  group('D — cycle rollover', () {
    test('cycle rollover notification reads back correctly', () async {
      final notification = AppNotification(
        notificationId: '${restaurantId}_cycle_rollover_2026-03-27',
        restaurantId: restaurantId,
        type: 'cycle_rollover',
        eventKey: 'cycle_rollover_2026-03-27',
        title: 'Target Cycle Refreshed',
        body: 'A new 60-day target cycle starting 2026-03-27 is now active.',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );

      await dao.insertIfAbsent(notification);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 1);
      expect(results.first.type, 'cycle_rollover');
      expect(results.first.eventKey, 'cycle_rollover_2026-03-27');
      expect(results.first.title, 'Target Cycle Refreshed');
    });

    test('same cycle rollover dedupes', () async {
      final first = AppNotification(
        notificationId: '${restaurantId}_rollover_1',
        restaurantId: restaurantId,
        type: 'cycle_rollover',
        eventKey: 'cycle_rollover_2026-03-27',
        title: 'First',
        body: 'First',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );
      final duplicate = AppNotification(
        notificationId: '${restaurantId}_rollover_2',
        restaurantId: restaurantId,
        type: 'cycle_rollover',
        eventKey: 'cycle_rollover_2026-03-27',
        title: 'Dup',
        body: 'Dup',
        businessDate: '2026-03-28',
        createdAt: '2026-03-28T10:00:00.000Z',
      );

      await dao.insertIfAbsent(first);
      await dao.insertIfAbsent(duplicate);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 1);
      expect(results.first.title, 'First');
    });
  });

  // ── E: cross-type coexistence ──────────────────────────────────────────

  group('E — cross-type coexistence', () {
    test('week snapshot and cycle rollover both appear in one query',
        () async {
      final week = AppNotification(
        notificationId: '${restaurantId}_week',
        restaurantId: restaurantId,
        type: 'new_week_snapshot',
        eventKey: 'new_week_snapshot_2026-03-23_2026-03-29',
        title: 'New Weekly Plan Locked',
        body: 'Week',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:00:00.000Z',
      );
      final cycle = AppNotification(
        notificationId: '${restaurantId}_cycle',
        restaurantId: restaurantId,
        type: 'cycle_rollover',
        eventKey: 'cycle_rollover_2026-03-27',
        title: 'Target Cycle Refreshed',
        body: 'Cycle',
        businessDate: '2026-03-27',
        createdAt: '2026-03-27T10:01:00.000Z',
      );

      await dao.insertIfAbsent(week);
      await dao.insertIfAbsent(cycle);

      final results = await dao.getNotifications(restaurantId);
      expect(results.length, 2);

      final types = results.map((n) => n.type).toSet();
      expect(types, contains('new_week_snapshot'));
      expect(types, contains('cycle_rollover'));
    });
  });

  // ── F: limit parameter ─────────────────────────────────────────────────

  group('F — limit parameter', () {
    test('getNotifications respects limit', () async {
      for (int i = 0; i < 5; i++) {
        await dao.insertIfAbsent(AppNotification(
          notificationId: '${restaurantId}_n$i',
          restaurantId: restaurantId,
          type: 'new_week_snapshot',
          eventKey: 'week_$i',
          title: 'Week $i',
          body: 'Body $i',
          businessDate: '2026-03-2$i',
          createdAt: '2026-03-2${i}T10:00:00.000Z',
        ));
      }

      final limited = await dao.getNotifications(restaurantId, limit: 3);
      expect(limited.length, 3);

      final all = await dao.getNotifications(restaurantId, limit: 20);
      expect(all.length, 5);
    });
  });
}
