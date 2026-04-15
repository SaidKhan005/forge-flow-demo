// Phase 7.55p.4d — App notification DAO.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/app_notification.dart';

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
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AppNotification.fromMap).toList();
  }
}
