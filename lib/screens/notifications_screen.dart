// Phase 7.55p.4d — Passive in-app notifications screen.
//
// Lightweight read-only list of persisted app-state notifications.
// Opened from the notification icon in the AppShell top bar.
// No push/toast, no background delivery, no unread tracking.

import 'package:flutter/material.dart';
import '../services/app_notification_service.dart';
import '../domain/models/app_notification.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../theme/app_theme.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    final notifications = await AppNotificationService.instance
        .getNotifications(restaurantId);
    if (mounted) {
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Notifications', style: AppTextStyles.display20()),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? Center(
              child: Text('Loading...',
                  style: AppTextStyles.mono11(color: AppColors.textMuted)),
            )
          : _notifications.isEmpty
              ? Center(
                  child: Text('No notifications yet.',
                      style:
                          AppTextStyles.mono11(color: AppColors.textMuted)),
                )
              : ListView.separated(
                  itemCount: _notifications.length,
                  separatorBuilder: (_, __) =>
                      Container(height: 1, color: AppColors.borderSubtle),
                  itemBuilder: (_, i) =>
                      _NotificationTile(notification: _notifications[i]),
                ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppColors.backgroundMid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notification.title,
              style: AppTextStyles.mono12(color: AppColors.textPrimary)),
          const SizedBox(height: 2),
          Text(notification.body,
              style: AppTextStyles.body13(color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(notification.businessDate,
              style: AppTextStyles.mono8(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}
