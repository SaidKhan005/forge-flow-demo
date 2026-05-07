// Mobile Settings — pointer row helper.
//
// Mobile Settings is a read-only mirror of the operator-web console.
// Sections that used to host edit affordances on mobile now end with a
// pointer row that nudges the operator to the matching surface in
// `app.forgeflow.app/<path>`. Tap behaviour copies the URL to the
// clipboard and surfaces a snackbar so the operator can paste into a
// browser; an optional [onLaunch] hook lets demo / preview shells
// short-circuit the clipboard step (e.g. to call `url_launcher` once a
// later lane wires it up).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.onLaunch,
  });

  /// Plain-English copy describing what the operator can do at the
  /// Operator Web surface (e.g. "Manage on Operator Web").
  final String label;

  /// Path under `app.forgeflow.app/` (no leading slash). Pass an empty
  /// string when no route exists yet — the row renders the "coming
  /// soon" affordance instead of a tappable link.
  final String opWebPath;

  /// Optional override for tap behaviour. When supplied, it is called
  /// with the resolved URL instead of copying to the clipboard.
  final ValueChanged<String>? onLaunch;

  static const String _baseUrl = 'https://app.forgeflow.app';

  bool get _isComingSoon => opWebPath.trim().isEmpty;

  String get _resolvedUrl => '$_baseUrl/${opWebPath.trim()}';

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
                          _isComingSoon
                              ? '$label (coming soon)'
                              : label,
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
                          style: AppTextStyles.body12(color: AppColors.textMuted),
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
    final url = _resolvedUrl;
    final launch = onLaunch;
    if (launch != null) {
      launch(url);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'URL copied — open in browser',
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
