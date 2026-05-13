// Mobile Settings - pointer row helper.
//
// Mobile Settings is a read-only mirror of the operator-web console.
// Sections that used to host edit affordances on mobile now end with a
// pointer row that nudges the operator to the matching surface in
// `app.forgeflow.app/<path>`. C-5 replaces the default tap behavior
// with the redemption-code handoff flow and keeps clipboard as the
// explicit offline/proxy-5xx fallback.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/auth/handoff_code_client.dart';
import '../../services/auth/handoff_code_gateway.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

/// Pointer to an Operator Web surface for sections whose editor lives
/// outside the mobile app. When [opWebPath] is empty, the row renders
/// as "coming soon" copy and tapping is a no-op.
class SettingsPointerRow extends StatelessWidget {
  const SettingsPointerRow({
    super.key,
    required this.label,
    required this.opWebPath,
    this.navId,
    this.handoffCodeGateway,
    this.launchExternalUrl,
    this.copyToClipboard,
    this.onLaunch,
  });

  /// Plain-English copy describing what the operator can do at the
  /// Operator Web surface.
  final String label;

  /// Path under `app.forgeflow.app/` (no leading slash). Pass an empty
  /// string when no route exists yet - the row renders the "coming
  /// soon" affordance instead of a tappable link.
  final String opWebPath;

  /// Stable Operator Web nav id carried by `/handoff?nav=...`.
  final String? navId;

  /// Gateway that mints the one-time redemption code before launch.
  final HandoffCodeGateway? handoffCodeGateway;

  /// Test seam for `url_launcher`.
  final Future<bool> Function(Uri url)? launchExternalUrl;

  /// Test seam for clipboard writes.
  final Future<void> Function(String value)? copyToClipboard;

  /// Older preview/test hook. New C-5 callers should inject
  /// [handoffCodeGateway] and [launchExternalUrl] instead.
  final ValueChanged<String>? onLaunch;

  static const String _baseUrl = 'https://app.forgeflow.app';

  bool get _isComingSoon => opWebPath.trim().isEmpty;

  String get _resolvedUrl => '$_baseUrl${_targetPath()}';

  String get _resolvedNavId {
    final explicit = navId?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return opWebPath.trim().replaceAll('-', '_').replaceAll('/', '');
  }

  String _targetPath() {
    final trimmed = opWebPath.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SettingsCard(
        children: [
          InkWell(
            onTap: _isComingSoon ? null : () => _onTap(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _isComingSoon
                        ? Icons.hourglass_empty_rounded
                        : Icons.open_in_new_rounded,
                    size: 18,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isComingSoon ? '$label (coming soon)' : label,
                          style: AppTextStyles.mono12(
                            color: AppColors.textPrimary,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _isComingSoon
                              ? 'This section will move to Operator Web in an upcoming release.'
                              : _resolvedUrl,
                          style: AppTextStyles.body12(
                            color: AppColors.textMuted,
                          ),
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
    );
  }

  Future<void> _onTap(BuildContext context) async {
    final launch = onLaunch;
    if (launch != null) {
      launch(_resolvedUrl);
      return;
    }

    final gateway = handoffCodeGateway;
    if (gateway != null) {
      try {
        final link = await gateway.createDeepLink(
          target: HandoffDeepLinkTarget(
            navId: _resolvedNavId,
            targetPath: _targetPath(),
          ),
        );
        final launcher = launchExternalUrl ?? _launchExternalUrl;
        final opened = await launcher(link.url);
        if (!opened) {
          await _copy(link.url.toString());
          if (context.mounted) {
            _showSnackBar(context, 'Handoff link copied - open in browser');
          }
          return;
        }
        if (context.mounted) {
          _showSnackBar(context, 'Opening Operator Web');
        }
        return;
      } catch (error) {
        if (shouldFallbackToClipboardForHandoff(error)) {
          await _copy(_resolvedUrl);
          if (context.mounted) {
            _showSnackBar(
              context,
              'Operator Web link copied - open in browser',
            );
          }
          return;
        }
        if (context.mounted) {
          _showSnackBar(context, _handoffErrorText(error));
        }
        return;
      }
    }

    await _copy(_resolvedUrl);
    if (!context.mounted) return;
    _showSnackBar(context, 'URL copied - open in browser');
  }

  Future<void> _copy(String value) async {
    final writer = copyToClipboard;
    if (writer != null) {
      await writer(value);
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
  }

  static Future<bool> _launchExternalUrl(Uri url) {
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _handoffErrorText(Object error) {
    if (error is HandoffCodeMintRejected) {
      if (error.code == 'rate_limit_exceeded') {
        return 'Too many handoff links. Try again in a few minutes.';
      }
      if (error.code == 'no_id_token' || error.statusCode == 401) {
        return 'Sign in again before opening Operator Web.';
      }
      return error.message;
    }
    return 'Could not open Operator Web. Please try again.';
  }
}
