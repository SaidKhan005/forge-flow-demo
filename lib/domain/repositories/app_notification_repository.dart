// Phase 7.55p.4d — App notification repository interface.
// W2.A — extended with read-state operations for push-delivered inbox.

import '../models/app_notification.dart';

abstract class AppNotificationRepository {
  Future<void> insertIfAbsent(AppNotification notification);
  Future<List<AppNotification>> getNotifications(String restaurantId,
      {int limit = 20});

  /// Stamps `read_at` with the current UTC time on a single notification.
  /// No-op (idempotent) if already read or not present.
  Future<void> markAsRead(String notificationId);

  /// Stamps `read_at` on every still-unread row for [restaurantId].
  Future<void> markAllAsRead(String restaurantId);

  /// Returns the count of rows where `read_at IS NULL` for [restaurantId].
  Future<int> getUnreadCount(String restaurantId);
}
