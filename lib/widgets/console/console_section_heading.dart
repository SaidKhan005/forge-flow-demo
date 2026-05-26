import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'console_action_bar.dart';

/// Operator-web section label that mirrors the mobile Shift section grammar:
/// accent rail, strong title, and a thin accent rule before the section body.
class OperatorWebSectionHeading extends StatelessWidget {
  const OperatorWebSectionHeading({
    super.key,
    required this.title,
    this.trailing,
    this.collapseBelowWidth = 560,
  });

  final String title;
  final Widget? trailing;
  final double collapseBelowWidth;

  @override
  Widget build(BuildContext context) {
    Widget headingRow({Widget? action}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 4,
            height: 22,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[AppColors.sunset, AppColors.sunsetDark],
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono16(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (action != null) ...<Widget>[const SizedBox(width: 12), action],
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final action = trailing == null
              ? null
              : OperatorWebActionBar(children: <Widget>[trailing!]);
          final shouldStack =
              action != null && constraints.maxWidth < collapseBelowWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (shouldStack) ...<Widget>[
                headingRow(),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: action),
              ] else
                headingRow(action: action),
              const SizedBox(height: 8),
              Container(
                height: 2,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[AppColors.sunset, AppColors.sunsetDark],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A clean card header for the Data accuracy surfaces: a bold title plus
/// an optional trailing action (typically an info "i" button), with NO
/// accent rail and NO accent underline. Matches the approved Data
/// accuracy redesign mockup, where each card reads as a plain bold title
/// and the detail lives behind the small "i".
///
/// This is intentionally separate from [OperatorWebSectionHeading] (the
/// railed/underlined grammar other console screens depend on) so the
/// shared widget stays untouched.
class OperatorWebPlainSectionHeading extends StatelessWidget {
  const OperatorWebPlainSectionHeading({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: AppTextStyles.mono16(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}
