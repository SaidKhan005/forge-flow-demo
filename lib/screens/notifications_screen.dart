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
          icon: const Icon(Icons.close, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sunset,
                ),
              ),
            )
          : _notifications.isEmpty
              ? const _NotificationsEmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  itemCount: _notifications.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) =>
                      _NotificationTile(notification: _notifications[i]),
                ),
    );
  }
}

class _NotificationsEmptyState extends StatelessWidget {
  const _NotificationsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.notifications_none_outlined,
              size: 30,
              color: AppColors.sunset,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'All caught up',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'No new notifications right now.',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context) {
    final visual = _NotificationTypeVisual.forType(notification.type);
    final timeLabel = _formatRelativeTime(notification.createdAt);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundMid,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: visual.accent),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: visual.accent.withValues(alpha: 0.14),
                          border: Border.all(
                              color: visual.accent.withValues(alpha: 0.5)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(visual.icon,
                            size: 18, color: visual.accent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    notification.title,
                                    style: AppTextStyles.mono14(
                                      color: AppColors.textPrimary,
                                      weight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (timeLabel != null) ...[
                                  const SizedBox(width: 8),
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: 2),
                                    child: Text(
                                      timeLabel,
                                      style: AppTextStyles.mono10(
                                          color: AppColors.textMuted),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              notification.body,
                              style: AppTextStyles.body13(
                                  color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTypeVisual {
  final IconData icon;
  final Color accent;
  const _NotificationTypeVisual({required this.icon, required this.accent});

  static _NotificationTypeVisual forType(String type) {
    switch (type) {
      case 'new_week_snapshot':
        return _NotificationTypeVisual(
          icon: Icons.event_available_rounded,
          accent: AppColors.sunset,
        );
      case 'cycle_rollover':
        return _NotificationTypeVisual(
          icon: Icons.refresh_rounded,
          accent: AppColors.sunsetDark,
        );
      default:
        return _NotificationTypeVisual(
          icon: Icons.notifications_active_outlined,
          accent: AppColors.textSecondary,
        );
    }
  }
}

/// Renders a stored ISO-8601 UTC timestamp as a short, locale-friendly
/// label in the device's local time zone.
///
/// Examples: `Just now`, `12m ago`, `2h ago`, `Yesterday 3:15 PM`,
/// `Apr 27, 3:15 PM`, `Mar 12 2025`.
String? _formatRelativeTime(String isoUtc) {
  final parsed = DateTime.tryParse(isoUtc);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);

  if (diff.inSeconds < 60 && diff.inSeconds >= -60) return 'Just now';
  if (diff.inMinutes < 60 && diff.inMinutes >= 0) {
    return '${diff.inMinutes}m ago';
  }
  if (diff.inHours < 12 && diff.inHours >= 0) {
    return '${diff.inHours}h ago';
  }

  final today = DateTime(now.year, now.month, now.day);
  final stamp = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(stamp).inDays;

  final time = _formatTimeOfDay(local);
  if (dayDiff == 0) return time;
  if (dayDiff == 1) return 'Yesterday $time';
  if (dayDiff < 7) return '${_weekdayShort(local.weekday)} $time';
  if (local.year == now.year) {
    return '${_monthShort(local.month)} ${local.day}, $time';
  }
  return '${_monthShort(local.month)} ${local.day} ${local.year}';
}

String _formatTimeOfDay(DateTime dt) {
  final hour24 = dt.hour;
  final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = hour24 >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

String _weekdayShort(int weekday) {
  const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return labels[weekday - 1];
}

String _monthShort(int month) {
  const labels = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return labels[month - 1];
}
