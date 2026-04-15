// Phase 7.55p.4d — SQLite-backed app notification repository.

import '../../../../domain/models/app_notification.dart';
import '../../../../domain/repositories/app_notification_repository.dart';
import '../dao/app_notification_dao.dart';
import '../sqlite_database.dart';

class SqliteAppNotificationRepository implements AppNotificationRepository {
  SqliteAppNotificationRepository._();
  static final SqliteAppNotificationRepository instance =
      SqliteAppNotificationRepository._();

  AppNotificationDao? _dao;

  Future<AppNotificationDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = AppNotificationDao(db);
    return _dao!;
  }

  @override
  Future<void> insertIfAbsent(AppNotification notification) async {
    final dao = await _daoReady;
    return dao.insertIfAbsent(notification);
  }

  @override
  Future<List<AppNotification>> getNotifications(
      String restaurantId, {int limit = 20}) async {
    final dao = await _daoReady;
    return dao.getNotifications(restaurantId, limit: limit);
  }
}
