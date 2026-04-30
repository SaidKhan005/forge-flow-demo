// Phase 7.55p.4d - Passive in-app notifications screen.
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
        title: Row(
          children: [
            ClipOval(
              child: Image.asset(
                'assets/images/forge_flow_splash_icon.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Text('Notifications', style: AppTextStyles.display20()),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 28),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const _NotificationsLoading()
            : _notifications.isEmpty
            ? const _NotificationsEmpty()
            : RefreshIndicator(
                onRefresh: () async {
                  setState(() => _isLoading = true);
                  await _load();
                },
                color: AppColors.sunsetDark,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: _notifications.length,
                  itemBuilder: (_, i) =>
                      _NotificationTile(notification: _notifications[i]),
                ),
              ),
      ),
    );
  }
}

class _NotificationsLoading extends StatelessWidget {
  const _NotificationsLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Loading notifications…',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _NotificationsEmpty extends StatelessWidget {
  const _NotificationsEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.sunset.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.sunset.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.notifications_none_outlined,
                size: 32,
                color: AppColors.sunsetDark,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "You're all caught up",
              textAlign: TextAlign.center,
              style: AppTextStyles.display20(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              'New week snapshots, cycle rollovers, and security events will land here.',
              textAlign: TextAlign.center,
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(notification.type);
    final icon = _iconFor(notification.type);
    final relative = _formatRelativeTime(notification.createdAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.5),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(icon, size: 16, color: accent),
                        ),
                        const SizedBox(width: 10),
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
                                      style: AppTextStyles.body14(
                                        color: AppColors.textPrimary,
                                      ).copyWith(fontWeight: FontWeight.w600),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (relative.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      relative,
                                      style: AppTextStyles.mono10(
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                notification.body,
                                style: AppTextStyles.body13(
                                  color: AppColors.textSecondary,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}

Color _accentFor(String type) {
  switch (type) {
    case 'new_week_snapshot':
      return AppColors.peacockDark;
    case 'cycle_rollover':
      return AppColors.sunsetDark;
    case 'mfa_authenticator_removed':
      return AppColors.warning;
    default:
      return AppColors.textSecondary;
  }
}

IconData _iconFor(String type) {
  switch (type) {
    case 'new_week_snapshot':
      return Icons.event_available_rounded;
    case 'cycle_rollover':
      return Icons.cached_rounded;
    case 'mfa_authenticator_removed':
      return Icons.lock_reset_rounded;
    default:
      return Icons.notifications_outlined;
  }
}

String _formatRelativeTime(String createdAt) {
  final t = DateTime.tryParse(createdAt);
  if (t == null) return '';
  final now = DateTime.now();
  final delta = now.difference(t);
  if (delta.isNegative) return 'just now';
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  if (delta.inDays == 1) return 'yesterday';
  if (delta.inDays < 7) return '${delta.inDays}d ago';
  if (delta.inDays < 30) {
    final weeks = (delta.inDays / 7).floor();
    return '${weeks}w ago';
  }
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
