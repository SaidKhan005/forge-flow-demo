// A9.SY1 — Write-action button that gates on connectivity.
//
// Wraps an ElevatedButton with the app's standard primary button style.
// When the device is offline the button is disabled, the label changes
// to "Requires connection", and a small hint explains why. When online
// the button behaves normally and shows the caller-supplied label.
//
// Connectivity state is sourced from the nearest
// [ConnectivityNotifier] registered in the Provider tree. If no
// provider is found the button is treated as always-online so the app
// degrades gracefully in widget tests that don't wire the notifier.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/connectivity_notifier.dart';
import '../theme/app_theme.dart';

/// A primary action button that disables itself and shows an
/// "offline" state when the device has no connectivity.
///
/// Usage:
/// ```dart
/// ConnectivityRequiredButton(
///   label: 'DONE',
///   onPressed: _done,
/// )
/// ```
class ConnectivityRequiredButton extends StatelessWidget {
  const ConnectivityRequiredButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  /// Label shown when the device is online.
  final String label;

  /// Callback invoked when the button is tapped online. Pass `null`
  /// to disable the button even when online (e.g. while an async
  /// operation is in flight).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool isOnline = _resolveOnline(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor:
                isOnline ? AppColors.sunset : AppColors.backgroundMid,
            foregroundColor:
                isOnline ? AppColors.backgroundDeep : AppColors.textMuted,
            disabledBackgroundColor: AppColors.backgroundMid,
            disabledForegroundColor: AppColors.textMuted,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: const RoundedRectangleBorder(),
            elevation: 0,
          ),
          onPressed: isOnline ? onPressed : null,
          child: Text(
            isOnline ? label : 'Requires connection',
            style: AppTextStyles.mono8(
              color:
                  isOnline ? AppColors.backgroundDeep : AppColors.textMuted,
            ),
          ),
        ),
        if (!isOnline) ...[
          const SizedBox(height: 4),
          Text(
            'Reconnect to save changes.',
            textAlign: TextAlign.center,
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }

  static bool _resolveOnline(BuildContext context) {
    try {
      return context.watch<ConnectivityNotifier>().isOnline;
    } on ProviderNotFoundException {
      return true; // graceful degradation in tests / non-mobile routes
    }
  }
}
