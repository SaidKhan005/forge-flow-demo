// Phase 7.55p.4d — App notification service.
//
// Owns emit + dedupe + read for passive in-app notifications.
// Two emit points today: new-week snapshot creation and 60-day cycle
// rollover. Dedupe is at the persistence seam via UNIQUE(restaurant_id,
// event_key) + ConflictAlgorithm.ignore.

import '../domain/models/app_notification.dart';
import '../domain/repositories/app_notification_repository.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_app_notification_repository.dart';

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final AppNotificationRepository _repo =
      SqliteAppNotificationRepository.instance;

  /// Emits a notification for a new weekly plan snapshot.
  ///
  /// Dedupe: if the same week's notification already exists, the insert
  /// is silently ignored via UNIQUE constraint.
  Future<void> emitNewWeekSnapshot({
    required String restaurantId,
    required String weekStart,
    required String weekEnd,
    required String businessDate,
  }) async {
    final eventKey = 'new_week_snapshot_${weekStart}_$weekEnd';
    final notification = AppNotification(
      notificationId: '${restaurantId}_$eventKey',
      restaurantId: restaurantId,
      type: 'new_week_snapshot',
      eventKey: eventKey,
      title: 'New Weekly Plan Locked',
      body: 'Weekly operating plan for $weekStart to $weekEnd is now active.',
      businessDate: businessDate,
      createdAt: nowIsoUtc(),
    );
    await _repo.insertIfAbsent(notification);
  }

  /// Emits a notification for a 60-day cycle rollover.
  ///
  /// Dedupe: if the same cycle start's notification already exists, the
  /// insert is silently ignored via UNIQUE constraint.
  Future<void> emitCycleRollover({
    required String restaurantId,
    required String cycleEffectiveStart,
    required String businessDate,
  }) async {
    final eventKey = 'cycle_rollover_$cycleEffectiveStart';
    final notification = AppNotification(
      notificationId: '${restaurantId}_$eventKey',
      restaurantId: restaurantId,
      type: 'cycle_rollover',
      eventKey: eventKey,
      title: 'Target Cycle Refreshed',
      body:
          'A new 60-day target cycle starting $cycleEffectiveStart is now active.',
      businessDate: businessDate,
      createdAt: nowIsoUtc(),
    );
    await _repo.insertIfAbsent(notification);
  }

  /// Returns the most recent notifications for [restaurantId], newest first.
  Future<List<AppNotification>> getNotifications(
      String restaurantId, {int limit = 20}) {
    return _repo.getNotifications(restaurantId, limit: limit);
  }
}