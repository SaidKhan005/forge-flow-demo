import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/system_info_service.dart';
import '../theme/app_theme.dart';

/// Full-screen blocking modal shown when the client version is below
/// [SystemInfoSnapshot.forceUpdateBelow].
///
/// The modal cannot be dismissed — it blocks all app interaction until the
/// operator installs a newer build. The primary button opens the appropriate
/// store page via [url_launcher].
class ForceUpdateModal extends StatelessWidget {
  const ForceUpdateModal({
    super.key,
    required this.snapshot,
  });

  final SystemInfoSnapshot snapshot;

  static const routeName = '/force-update';

  /// Shows [ForceUpdateModal] as a full-screen, non-dismissible dialog if
  /// [snapshot.mustForceUpdate] is true. No-op otherwise.
  static void showIfRequired(BuildContext context, SystemInfoSnapshot snapshot) {
    if (!snapshot.mustForceUpdate) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ForceUpdateModal(snapshot: snapshot),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Prevent back-button dismissal on Android.
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.backgroundDeep,
        title: Text(
          'Update Required',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'A newer version of Forge & Flow is required to continue. '
          'Please update the app.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sunsetDark,
              foregroundColor: Colors.white,
              minimumSize: const Size(160, 48),
            ),
            onPressed: () => _openStore(),
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  Future<void> _openStore() async {
    final Uri storeUri;
    if (Platform.isIOS && snapshot.iosAppStoreId.isNotEmpty) {
      storeUri = Uri.parse(
        'https://apps.apple.com/app/id${snapshot.iosAppStoreId}',
      );
    } else {
      storeUri = Uri.parse(
        'https://play.google.com/store/apps/details?id=${snapshot.androidPackageId}',
      );
    }
    if (await canLaunchUrl(storeUri)) {
      await launchUrl(storeUri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Non-blocking banner shown when the client is behind [currentClientVersion]
/// but above [forceUpdateBelow]. Renders a slim amber banner at the top of
/// the screen; operator can dismiss it or tap "Update".
class SoftUpdateBanner extends StatefulWidget {
  const SoftUpdateBanner({
    super.key,
    required this.snapshot,
    required this.child,
  });

  final SystemInfoSnapshot snapshot;
  final Widget child;

  @override
  State<SoftUpdateBanner> createState() => _SoftUpdateBannerState();
}

class _SoftUpdateBannerState extends State<SoftUpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !widget.snapshot.shouldSoftUpdate) {
      return widget.child;
    }
    return Column(
      children: [
        Material(
          color: const Color(0xFFFFF3CD),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 18, color: Color(0xFF856404)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'A new version is available.',
                      style: TextStyle(
                        color: Color(0xFF856404),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF856404),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: _openStore,
                    child: const Text('Update'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: const Color(0xFF856404),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    tooltip: 'Dismiss',
                    onPressed: () => setState(() => _dismissed = true),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }

  Future<void> _openStore() async {
    final snapshot = widget.snapshot;
    final Uri storeUri;
    if (Platform.isIOS && snapshot.iosAppStoreId.isNotEmpty) {
      storeUri = Uri.parse(
        'https://apps.apple.com/app/id${snapshot.iosAppStoreId}',
      );
    } else {
      storeUri = Uri.parse(
        'https://play.google.com/store/apps/details?id=${snapshot.androidPackageId}',
      );
    }
    if (await canLaunchUrl(storeUri)) {
      await launchUrl(storeUri, mode: LaunchMode.externalApplication);
    }
  }
}
