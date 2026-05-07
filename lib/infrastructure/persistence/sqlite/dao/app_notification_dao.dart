// Phase 7.55p.4d — App notification DAO.
// W2.A — extended with read-state operations.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/app_notification.dart';
import '../../../../domain/services/utc_metadata_timestamp.dart';

class AppNotificationDao {
  final Database _db;
  const AppNotificationDao(this._db);

  Future<void> insertIfAbsent(AppNotification notification) async {
    await _db.insert(
      'app_notifications',
      notification.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<AppNotification>> getNotifications(
      String restaurantId, {int limit = 20}) async {
    final rows = await _db.query(
      'app_notifications',
      columns: const [
        'notification_id',
        'restaurant_id',
        'type',
        'event_key',
        'title',
        'body',
        'business_date',
        'created_at',
        'read_at',
      ],
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AppNotification.fromMap).toList();
  }

  Future<void> markAsRead(String notificationId) async {
    await _db.update(
      'app_notifications',
      {'read_at': nowIsoUtc()},
      where: 'notification_id = ? AND read_at IS NULL',
      whereArgs: [notificationId],
    );
  }

  Future<void> markAllAsRead(String restaurantId) async {
    await _db.update(
      'app_notifications',
      {'read_at': nowIsoUtc()},
      where: 'restaurant_id = ? AND read_at IS NULL',
      whereArgs: [restaurantId],
    );
  }

  Future<int> getUnreadCount(String restaurantId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM app_notifications '
      'WHERE restaurant_id = ? AND read_at IS NULL',
      [restaurantId],
    );
    if (rows.isEmpty) return 0;
    final value = rows.first['c'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '0') ?? 0;
  }
}
