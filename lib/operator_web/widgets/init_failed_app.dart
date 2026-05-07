// Phase 11W.0 — Operator-facing init-failure surface.
//
// Shown when `main_operator_web.dart` catches an error during startup
// (e.g. missing `OPERATOR_WEB_PROXY_BASE_URI` in a live build). The
// widget intentionally does NOT show developer details in the primary
// body — those stay behind a "Show technical details" disclosure that
// support staff can expand from a screenshot or screen-share.
//
// The underlying `StateError` that guards misconfigured deployments is
// NOT removed — it is the dev/CI fail-closed signal. Only the
// rendering changes.

import 'package:flutter/material.dart';

import '../services/operator_web_url_launcher.dart';
import '../../theme/app_theme.dart';

/// Standalone `MaterialApp` rendered when operator-web fails to
/// initialize. Wraps [OperatorWebInitFailedBody] in a bare
/// [MaterialApp] + [Scaffold] using the existing brand theme.
class OperatorWebInitFailedApp extends StatelessWidget {
  const OperatorWebInitFailedApp({
    super.key,
    required this.error,
    required this.stack,
  });

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forge & Flow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        body: Center(
          child: OperatorWebInitFailedBody(error: error, stack: stack),
        ),
      ),
    );
  }
}

/// The operator-facing error body. Separated for widget-testability.
///
/// Layout: centered card, max 480 wide, comfortable padding for both
/// desktop and mobile-web. No red error boxes — calm, polite, brand-
/// consistent.
class OperatorWebInitFailedBody extends StatefulWidget {
  const OperatorWebInitFailedBody({
    super.key,
    required this.error,
    required this.stack,
    this.onEmailSupport,
  });

  final Object error;
  final StackTrace stack;

  /// Override for tests — if null, the button opens the mailto: URI
  /// via [openOperatorWebUrl].
  final VoidCallback? onEmailSupport;

  @override
  State<OperatorWebInitFailedBody> createState() =>
      _OperatorWebInitFailedBodyState();
}

class _OperatorWebInitFailedBodyState
    extends State<OperatorWebInitFailedBody> {
  void _handleEmailSupport() {
    if (widget.onEmailSupport != null) {
      widget.onEmailSupport!();
      return;
    }
    final errorSummary = Uri.encodeComponent(widget.error.toString());
    final uri =
        'mailto:support@forgeflow.app'
        '?subject=Console%20couldn%27t%20start'
        '&body=$errorSummary';
    openOperatorWebRedirect(uri);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border: Border.all(
                color: AppColors.borderSubtle,
                width: 1,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'We couldn’t reach Forge & Flow',
                  key: const Key('init_failed_title'),
                  style: AppTextStyles.display20(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Something on our side is preventing the console from '
                  'starting. Please contact support@forgeflow.app — '
                  'we’ll get this fixed quickly.',
                  key: const Key('init_failed_body'),
                  style: AppTextStyles.body13(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('init_failed_email_support_button'),
                    onPressed: _handleEmailSupport,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunsetDark,
                      foregroundColor: AppColors.backgroundSurface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Text(
                      'Email support',
                      style: AppTextStyles.body14(
                        color: AppColors.backgroundSurface,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    key: const Key('init_failed_technical_details_tile'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      'Show technical details',
                      style: AppTextStyles.body13(
                        color: AppColors.textMuted,
                      ),
                    ),
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundMid,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: AppColors.borderSubtle,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${widget.error.runtimeType}',
                              key: const Key('init_failed_error_type'),
                              style: AppTextStyles.mono12(
                                color: AppColors.textPrimary,
                                weight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${widget.error}',
                              key: const Key('init_failed_error_message'),
                              style: AppTextStyles.mono10(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${widget.stack}',
                              key: const Key('init_failed_stack_trace'),
                              style: AppTextStyles.mono10(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            ), // SingleChildScrollView
          ),
        ),
      ),
    );
  }
}
