import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Shared screen-level identity header for the operator-web console.
///
/// Before this widget each screen hand-rolled its own header `Row`
/// (a leading icon + a `display20` title, sometimes with trailing
/// action buttons). They drifted apart on small details: whether the
/// title could wrap, whether the actions collapsed under the title on
/// narrow widths, the gap between icon and title, etc. This widget is
/// the single source of truth for that block so every screen's
/// identity header looks and behaves the same:
///
///   * Leading [icon] at 22px in [AppColors.sunsetDark].
///   * [title] in `display20`, allowed to wrap to two lines then
///     ellipsize, so long location names never overflow.
///   * Optional [subtitle] in `body13` / [AppColors.textSecondary] for
///     the screen's one-line orientation copy.
///   * Optional trailing [actions] (buttons). On widths below
///     [collapseBelowWidth] the actions stack beneath the title instead
///     of being squeezed onto the same row.
///
/// Callers pass [titleKey] when a test pins the title text by key
/// (e.g. the business-setup nav title).
class OperatorWebScreenHeader extends StatelessWidget {
  const OperatorWebScreenHeader({
    super.key,
    required this.icon,
    required this.title,
    this.titleKey,
    this.subtitle,
    this.actions = const <Widget>[],
    this.collapseBelowWidth = 560,
  });

  /// Leading glyph rendered at 22px in [AppColors.sunsetDark].
  final IconData icon;

  /// Screen title, rendered in `display20`.
  final String title;

  /// Optional key pinned on the title `Text` for tests that assert it.
  final Key? titleKey;

  /// Optional one-line orientation copy under the title.
  final String? subtitle;

  /// Trailing action buttons (e.g. "Invite member", "New role").
  final List<Widget> actions;

  /// Below this width the [actions] stack beneath the title block
  /// rather than sharing its row.
  final double collapseBelowWidth;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 22, color: AppColors.sunsetDark),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                key: titleKey,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (actions.isEmpty) return titleBlock;

    final actionBar = Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: actions,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < collapseBelowWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              titleBlock,
              const SizedBox(height: 12),
              actionBar,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: titleBlock),
            const SizedBox(width: 16),
            actionBar,
          ],
        );
      },
    );
  }
}
