// UX-parity Slice B — admin demo-data banner (parity item W2 /
// G72 / X-G70).
//
// Operator-web mounts a slim persistent demo strip
// (`OperatorWebDemoBanner`) once in its shell so a walkthrough viewer
// is never misled into thinking fixture data is their real business.
// Admin had only a tiny "Demo data" pill in the header and no equivalent
// persistent tell. This is the admin parity: a slim strip mounted once
// in the admin shell, gated on the shell's existing `sharePreviewMode`
// flag (admin's demo / share-preview signal).
//
// This is a UX-only demo tell driven by an explicit flag the shell
// already computes — NOT a `kDemoMode` reader-side branch and NOT a
// build-time flag. When `sharePreviewMode == false` it collapses to a
// zero-height [SizedBox.shrink] so production admins never see it.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Slim demo indicator for the admin shell. Renders a single persistent
/// strip when [sharePreviewMode] is true; collapses to a zero-height
/// [SizedBox.shrink] otherwise so production admins never see it.
class AdminDemoBanner extends StatelessWidget {
  const AdminDemoBanner({super.key, required this.sharePreviewMode});

  /// The admin shell's existing demo / share-preview signal. The shell
  /// owns the demo-vs-live discrimination so this widget stays a pure
  /// render of the flag.
  final bool sharePreviewMode;

  @override
  Widget build(BuildContext context) {
    if (!sharePreviewMode) {
      return const SizedBox.shrink();
    }
    return Material(
      key: const Key('admin_demo_banner'),
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.sunsetDark.withValues(alpha: 0.10),
          border: Border(
            bottom: BorderSide(
              color: AppColors.sunsetDark.withValues(alpha: 0.45),
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const Icon(
              Icons.science_outlined,
              color: AppColors.sunsetDark,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Demo data. This is a sample walkthrough, not your real '
                'data.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
