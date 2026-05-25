import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdminConsoleLayout {
  const AdminConsoleLayout._();

  static const double sideNavWidth = 304;
  static const double maxContentWidth = 1120;
  static const double narrowContentWidth = 760;
  static const double emptyStateMaxWidth = 460;

  static const EdgeInsets screenPadding = EdgeInsets.fromLTRB(24, 24, 24, 32);
  static const EdgeInsets compactScreenPadding = EdgeInsets.all(20);
}

class AdminConsoleChrome {
  const AdminConsoleChrome._();

  static BoxDecoration navSectionDecoration() => BoxDecoration(
    color: AppColors.backgroundSurface.withValues(alpha: 0.58),
    border: Border.all(
      color: AppColors.borderSubtle.withValues(alpha: 0.78),
      width: 1,
    ),
    borderRadius: BorderRadius.circular(8),
  );

  static BoxDecoration navAccentDecoration(Color accent) => BoxDecoration(
    color: accent.withValues(alpha: 0.075),
    border: Border.all(color: accent.withValues(alpha: 0.22), width: 1),
    borderRadius: BorderRadius.circular(8),
  );

  static BoxDecoration iconTileDecoration(Color accent) => BoxDecoration(
    color: accent.withValues(alpha: 0.12),
    borderRadius: BorderRadius.circular(6),
  );
}

class AdminConsoleEmptyState extends StatelessWidget {
  const AdminConsoleEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.action,
    this.icon,
    this.maxWidth = AdminConsoleLayout.emptyStateMaxWidth,
  });

  final String title;
  final String message;
  final Widget? action;
  final IconData? icon;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DecoratedBox(
            decoration: AppDecoration.surfaceCard,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (icon != null) ...<Widget>[
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: AdminConsoleChrome.iconTileDecoration(
                            AppColors.sunset,
                          ),
                          child: Icon(
                            icon,
                            size: 20,
                            color: AppColors.sunsetDark,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style: AppTextStyles.display20(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  if (action != null) ...<Widget>[
                    const SizedBox(height: 18),
                    action!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
