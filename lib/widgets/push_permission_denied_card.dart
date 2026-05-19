import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

import '../services/mobile_push/push_permission_state.dart';
import '../theme/app_theme.dart';

/// Inline card shown when the operator has denied push notification
/// permission. Renders only when [PushPermissionStateNotifier] is
/// [MobilePushPermissionStatus.denied]; otherwise renders nothing.
///
/// Usage — place on any screen that wants to surface the recovery prompt:
/// ```dart
/// PushPermissionDeniedCard(notifier: pushPermissionNotifier),
/// ```
///
/// The "Open Settings" button calls [AppSettings.openNotificationSettings]
/// which deep-links the operator directly to the per-app notification
/// settings page on both iOS and Android.
class PushPermissionDeniedCard extends StatelessWidget {
  const PushPermissionDeniedCard({
    super.key,
    required this.notifier,
  });

  final PushPermissionStateNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobilePushPermissionStatus>(
      valueListenable: notifier,
      builder: (context, status, _) {
        if (status != MobilePushPermissionStatus.denied) {
          return const SizedBox.shrink();
        }
        return _DeniedCard();
      },
    );
  }
}

class _DeniedCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.backgroundMid,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: AppColors.borderSubtle,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.notifications_off_outlined,
              size: 22,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Notifications are off',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Open Settings to turn on notifications for Forge & Flow.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sunsetDark,
                      side: const BorderSide(color: AppColors.sunsetDark),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      minimumSize: const Size(0, 34),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onPressed: () =>
                        AppSettings.openAppSettings(
                          type: AppSettingsType.notification,
                        ),
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
