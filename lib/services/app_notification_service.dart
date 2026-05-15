// Phase 7.55p.4d — App notification service.
// W2.A — extended with push-delivery emit + read-state + unread-count
// notifier so the bell badge can subscribe to a single source of truth.
//
// Owns emit + dedupe + read for passive in-app notifications.
// Original emit points: new-week snapshot creation, 60-day cycle
// rollover, and MFA authenticator removal. W2.A adds `emitPushDelivery`
// so foreground/background/terminated FCM deliveries land in the same
// inbox table. Dedupe is at the persistence seam via UNIQUE(
// restaurant_id, event_key) + ConflictAlgorithm.ignore.

import 'package:flutter/foundation.dart';

import '../domain/models/app_notification.dart';
import '../domain/repositories/app_notification_repository.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_app_notification_repository.dart';

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  AppNotificationRepository _repo =
      SqliteAppNotificationRepository.instance;

  /// Live unread-count for the active restaurant. The bell badge listens
  /// to this notifier and re-renders when the count changes. Refreshed
  /// after every emit/markAsRead/markAllAsRead and on `start`.
  final ValueNotifier<int> unreadCountNotifier = ValueNotifier<int>(0);

  String? _activeRestaurantId;

  /// Test seam: swap the underlying repository (singleton in production).
  @visibleForTesting
  void overrideRepositoryForTest(AppNotificationRepository repo) {
    _repo = repo;
  }

  /// Test seam: reset to the production singleton + clear the badge.
  @visibleForTesting
  void resetForTest() {
    _repo = SqliteAppNotificationRepository.instance;
    _activeRestaurantId = null;
    unreadCountNotifier.value = 0;
  }

  /// Boot hook — caches the active restaurant for refresh fan-out and
  /// hydrates the unread-count notifier on app start.
  Future<void> start(String restaurantId) async {
    _activeRestaurantId = restaurantId;
    await refreshUnreadCount(restaurantId);
  }

  /// Reads the current unread count and pushes it onto the notifier.
  /// Safe to call repeatedly; idempotent.
  Future<void> refreshUnreadCount(String restaurantId) async {
    _activeRestaurantId = restaurantId;
    final count = await _repo.getUnreadCount(restaurantId);
    if (unreadCountNotifier.value != count) {
      unreadCountNotifier.value = count;
    }
  }

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
    await refreshUnreadCount(restaurantId);
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
    await refreshUnreadCount(restaurantId);
  }

  Future<void> emitMfaAuthenticatorRemoved({
    required String restaurantId,
    required String userId,
    required String requestId,
    required String businessDate,
  }) async {
    final eventKey = 'mfa_authenticator_removed_${userId}_$requestId';
    final notification = AppNotification(
      notificationId: '${restaurantId}_$eventKey',
      restaurantId: restaurantId,
      type: 'mfa_authenticator_removed',
      eventKey: eventKey,
      title: 'Authenticator App Removed',
      body:
          'Two-factor sign-in was removed. Add a new authenticator app if this was unexpected.',
      businessDate: businessDate,
      createdAt: nowIsoUtc(),
    );
    await _repo.insertIfAbsent(notification);
    await refreshUnreadCount(restaurantId);
  }

  /// W2.A — emit a push-delivered notification into the inbox.
  ///
  /// Called from the FCM foreground/background/terminated paths after
  /// the platform notification has been shown so the inbox mirrors what
  /// the operator saw on the lockscreen / shade. The caller maps the
  /// FCM `data` payload to (`type`, `eventKey`, `title`, `body`,
  /// `businessDate`); this method handles persistence + dedupe + badge
  /// refresh in one place.
  Future<void> emitPushDelivery({
    required String restaurantId,
    required String type,
    required String eventKey,
    required String title,
    required String body,
    required String businessDate,
  }) async {
    final notification = AppNotification(
      notificationId: '${restaurantId}_$eventKey',
      restaurantId: restaurantId,
      type: type,
      eventKey: eventKey,
      title: title,
      body: body,
      businessDate: businessDate,
      createdAt: nowIsoUtc(),
    );
    await _repo.insertIfAbsent(notification);
    await refreshUnreadCount(restaurantId);
  }

  /// Marks a single notification as read and refreshes the badge.
  Future<void> markAsRead(String notificationId) async {
    await _repo.markAsRead(notificationId);
    final restaurantId = _activeRestaurantId;
    if (restaurantId != null) {
      await refreshUnreadCount(restaurantId);
    }
  }

  /// Marks every still-unread notification for [restaurantId] as read.
  Future<void> markAllAsRead(String restaurantId) async {
    await _repo.markAllAsRead(restaurantId);
    await refreshUnreadCount(restaurantId);
  }

  /// Returns the most recent notifications for [restaurantId], newest first.
  Future<List<AppNotification>> getNotifications(
      String restaurantId, {int limit = 20}) {
    return _repo.getNotifications(restaurantId, limit: limit);
  }
}
