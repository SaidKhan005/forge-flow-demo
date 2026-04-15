// Phase 7.55p.4d — App notification repository interface.

import '../models/app_notification.dart';

abstract class AppNotificationRepository {
  Future<void> insertIfAbsent(AppNotification notification);
  Future<List<AppNotification>> getNotifications(String restaurantId,
      {int limit = 20});
}
