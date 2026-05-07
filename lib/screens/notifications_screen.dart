// Phase 7.55p.4d - Passive in-app notifications screen.
// W2.A — extended with per-tile mark-as-read tap, "Mark all as read"
// AppBar action, and a visual read/unread treatment so the bell badge
// has a place to bottom out at zero.
//
// Lightweight read-only list of persisted app-state notifications.
// Opened from the notification icon in the AppShell top bar.

import 'package:flutter/material.dart';
import '../services/app_notification_service.dart';
import '../domain/models/app_notification.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../theme/app_theme.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  static const routeName = '/notifications';

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = [];
  bool _isLoading = true;
  String? _restaurantId;

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
        _restaurantId = restaurantId;
        _notifications = notifications;
        _isLoading = false;
      });
    }
  }

  Future<void> _markAllAsRead() async {
    final restaurantId = _restaurantId;
    if (restaurantId == null) return;
    await AppNotificationService.instance.markAllAsRead(restaurantId);
    await _load();
  }

  Future<void> _markTileAsRead(AppNotification notification) async {
    if (notification.readAt != null) return;
    await AppNotificationService.instance.markAsRead(notification.notificationId);
    await _load();
  }

  bool get _hasUnread => _notifications.any((n) => n.readAt == null);

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
        actions: [
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all, size: 24),
            onPressed: _hasUnread ? _markAllAsRead : null,
          ),
        ],
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
                  itemBuilder: (_, i) => _NotificationTile(
                    notification: _notifications[i],
                    onTap: () => _markTileAsRead(_notifications[i]),
                  ),
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
  final VoidCallback onTap;
  const _NotificationTile({required this.notification, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(notification.type);
    final icon = _iconFor(notification.type);
    final relative = _formatRelativeTime(notification.createdAt);
    final isUnread = notification.readAt == null;
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
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
                            if (isUnread) ...[
                              const Padding(
                                padding: EdgeInsets.only(top: 6, right: 8),
                                child: CircleAvatar(
                                  radius: 4,
                                  backgroundColor: AppColors.sunsetDark,
                                ),
                              ),
                            ],
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
                                          ).copyWith(
                                            fontWeight: isUnread
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                          ),
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
        ),
      ),
    );
    return Opacity(opacity: isUnread ? 1.0 : 0.6, child: tile);
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
