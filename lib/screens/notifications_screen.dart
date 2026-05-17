// Phase 7.55p.4d - Passive in-app notifications screen.
// W2.A — extended with per-tile mark-as-read tap, "Mark all as read"
// AppBar action, and a visual read/unread treatment so the bell badge
// has a place to bottom out at zero.
//
// Lightweight read-only list of persisted app-state notifications.
// Opened from the notification icon in the AppShell top bar.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../domain/models/notification_event_catalog.dart';
import '../services/app_notification_service.dart';
import '../services/restaurant_scope_service.dart';
import '../domain/models/app_notification.dart';
import '../state/auth_session_notifier.dart';
import '../theme/app_theme.dart';
import '../widgets/operator_brand_mark.dart';

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
    final restaurantId = await RestaurantScopeService.instance
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
    await AppNotificationService.instance.markAsRead(
      notification.notificationId,
    );
    await _load();
  }

  bool get _hasUnread => _notifications.any((n) => n.readAt == null);

  @override
  Widget build(BuildContext context) {
    // Wave 2 W-5-mobile-FU — read `session.logoUrl` for the AppBar
    // brand-mark. Falls back to the F&F splash icon when no session is
    // wired (e.g. widget-test mounts without a notifier) or when the
    // operator has not uploaded a logo. HP #2: no `kDemoMode` reader
    // branch — demo and live read from the same projection.
    String? sessionLogoUrl;
    try {
      sessionLogoUrl = Provider.of<AuthSessionNotifier>(
        context,
        listen: false,
      ).session?.logoUrl;
    } on ProviderNotFoundException {
      sessionLogoUrl = null;
    }
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            OperatorBrandMark(logoUrl: sessionLogoUrl),
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
    final presentation = _presentationFor(notification);
    final accent = presentation.accent;
    final icon = presentation.icon;
    final relative = _formatRelativeTime(notification.createdAt);
    final isUnread = notification.readAt == null;
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: AppRadius.cardR,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: DecoratedBox(
              decoration: AppDecoration.surfaceCard,
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
                                padding: EdgeInsets.only(
                                  top: AppSpacing.sm,
                                  right: AppSpacing.sm,
                                ),
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
                              decoration: AppDecoration.accentChip(accent),
                              child: Icon(icon, size: 16, color: accent),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          presentation.title,
                                          style:
                                              AppTextStyles.body14(
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
                                    presentation.body,
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

class _NotificationPresentation {
  const _NotificationPresentation({
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String body;
  final IconData icon;
  final Color accent;
}

class _FallbackCopy {
  const _FallbackCopy({required this.title, required this.body});

  final String title;
  final String body;
}

const _kLegacyNotificationCopy = <String, _FallbackCopy>{
  'new_week_snapshot': _FallbackCopy(
    title: 'New Weekly Plan Locked',
    body: 'A new weekly operating plan is now active.',
  ),
  'cycle_rollover': _FallbackCopy(
    title: 'Target Cycle Refreshed',
    body: 'A new 60-day target cycle is now active.',
  ),
  'mfa_authenticator_removed': _FallbackCopy(
    title: 'Authenticator App Removed',
    body:
        'Two-factor sign-in was removed. Add a new authenticator app if this was unexpected.',
  ),
};

const _kTemplateOnlyNotificationCopy = <String, _FallbackCopy>{
  'tos_version_updated_notice': _FallbackCopy(
    title: 'Terms of Service updated',
    body:
        'Forge & Flow published updated Terms of Service. Review and accept them on Operator Web the next time you sign in.',
  ),
  'notif.tos.version_updated': _FallbackCopy(
    title: 'Terms of Service updated',
    body:
        'Forge & Flow published updated Terms of Service. Review and accept them on Operator Web the next time you sign in.',
  ),
};

final Map<String, NotificationCatalogEntry> _kCatalogByEventKey =
    <String, NotificationCatalogEntry>{
      for (final entry in kNotificationCatalog) entry.eventKey: entry,
    };

_NotificationPresentation _presentationFor(AppNotification notification) {
  final key = _presentationKeyFor(notification);
  final fallback = _fallbackCopyFor(notification, key);
  final rawTitle = notification.title.trim();
  final rawBody = notification.body.trim();
  return _NotificationPresentation(
    title: _usesGenericTitle(rawTitle) ? fallback.title : rawTitle,
    body: rawBody.isEmpty ? fallback.body : rawBody,
    icon: _iconFor(key),
    accent: _accentFor(key),
  );
}

String _presentationKeyFor(AppNotification notification) {
  final eventKey = notification.eventKey.trim();
  final type = notification.type.trim();
  if (_kCatalogByEventKey.containsKey(eventKey) ||
      _kTemplateOnlyNotificationCopy.containsKey(eventKey)) {
    return eventKey;
  }
  if (_kLegacyNotificationCopy.containsKey(type) ||
      _kCatalogByEventKey.containsKey(type) ||
      _kTemplateOnlyNotificationCopy.containsKey(type)) {
    return type;
  }
  return eventKey.isNotEmpty ? eventKey : type;
}

_FallbackCopy _fallbackCopyFor(AppNotification notification, String key) {
  final catalog = _kCatalogByEventKey[key];
  if (catalog != null) {
    return _FallbackCopy(title: catalog.title, body: catalog.description);
  }
  final templateOnly = _kTemplateOnlyNotificationCopy[key];
  if (templateOnly != null) return templateOnly;
  final legacy = _kLegacyNotificationCopy[key];
  if (legacy != null) return legacy;
  final rawTitle = notification.title.trim();
  final rawBody = notification.body.trim();
  return _FallbackCopy(
    title: rawTitle.isEmpty ? 'Notification' : rawTitle,
    body: rawBody,
  );
}

bool _usesGenericTitle(String title) {
  if (title.isEmpty) return true;
  final normalized = title.toLowerCase();
  return normalized == 'notification' ||
      normalized == 'forge & flow' ||
      normalized == 'forge and flow';
}

Color _accentFor(String key) {
  switch (key) {
    case 'new_week_snapshot':
    case 'notif.plan.updated':
      return AppColors.peacockDark;
    case 'cycle_rollover':
    case 'notif.vendor.now_available':
    case 'notif.star.override':
      return AppColors.sunsetDark;
    case 'mfa_authenticator_removed':
    case 'notif.backfill.failed':
    case 'notif.audit.anchor_failure':
    case 'notif.shift.stale':
      return AppColors.warning;
    case 'notif.backfill.complete':
      return AppColors.positive;
    case 'tos_version_updated_notice':
    case 'notif.tos.version_updated':
      return AppColors.textSecondary;
    default:
      return AppColors.textSecondary;
  }
}

IconData _iconFor(String key) {
  switch (key) {
    case 'new_week_snapshot':
    case 'notif.plan.updated':
      return Icons.event_available_rounded;
    case 'cycle_rollover':
      return Icons.cached_rounded;
    case 'mfa_authenticator_removed':
      return Icons.lock_reset_rounded;
    case 'notif.backfill.complete':
      return Icons.cloud_done_rounded;
    case 'notif.backfill.failed':
      return Icons.cloud_off_rounded;
    case 'notif.vendor.now_available':
      return Icons.storefront_rounded;
    case 'notif.audit.anchor_failure':
      return Icons.gpp_bad_rounded;
    case 'notif.shift.stale':
      return Icons.schedule_rounded;
    case 'notif.star.override':
      return Icons.star_half_rounded;
    case 'tos_version_updated_notice':
    case 'notif.tos.version_updated':
      return Icons.description_rounded;
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
