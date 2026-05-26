import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdminVisualSystem {
  const AdminVisualSystem._();

  static const double minTextScale = 1.16;
  static const double maxTextScale = 1.32;

  static const double screenMaxWidth = 1120;
  static const EdgeInsets screenPadding = EdgeInsets.fromLTRB(28, 28, 28, 36);

  static const double surfaceRadius = 8;
  static const double tabRadius = 8;
  static const double tabStripRadius = 8;
  static const double tabGap = 6;
  static const double tabIconSize = 18;

  static const EdgeInsets surfacePadding = EdgeInsets.all(20);
  static const EdgeInsets panelPadding = EdgeInsets.all(20);
  static const EdgeInsets compactPanelPadding = EdgeInsets.all(18);
  static const EdgeInsets tabPadding = EdgeInsets.symmetric(
    horizontal: 18,
    vertical: 12,
  );
  static const EdgeInsets tabStripPadding = EdgeInsets.all(6);

  static BorderSide get hairline =>
      const BorderSide(color: AppColors.borderSubtle, width: 1);

  static BoxDecoration surfaceDecoration({
    Color color = AppColors.backgroundSurface,
  }) {
    return BoxDecoration(
      color: color,
      border: Border.all(color: AppColors.borderSubtle, width: 1),
      borderRadius: BorderRadius.circular(surfaceRadius),
    );
  }

  static BoxDecoration tabStripDecoration({
    Color color = AppColors.backgroundSurface,
  }) {
    return BoxDecoration(
      color: color,
      border: Border.all(color: AppColors.borderSubtle, width: 1),
      borderRadius: BorderRadius.circular(tabStripRadius),
    );
  }

  static BoxDecoration tabDecoration({required bool selected}) {
    return BoxDecoration(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.13)
          : Colors.transparent,
      border: Border.all(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.42)
            : Colors.transparent,
        width: 1,
      ),
      borderRadius: BorderRadius.circular(tabRadius),
    );
  }

  static TextStyle tabTextStyle({required bool selected}) {
    return AppTextStyles.body14(
      color: selected ? AppColors.sunsetDark : AppColors.textMuted,
    );
  }
}
