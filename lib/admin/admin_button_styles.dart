import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdminButtonStyles {
  const AdminButtonStyles._();

  static const double radius = 6;
  static const Size defaultMinimumSize = Size(96, 40);
  static const EdgeInsets defaultPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 12,
  );

  static TextStyle get dialogTitleStyle => AppTextStyles.pageTitle(
    color: AppColors.textPrimary,
  ).copyWith(fontSize: 20, height: 1.28);

  static ThemeData applyTo(ThemeData base) {
    return base.copyWith(
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.backgroundSurface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        titleTextStyle: dialogTitleStyle,
        contentTextStyle: AppTextStyles.body13(color: AppColors.textSecondary),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: primary),
      outlinedButtonTheme: OutlinedButtonThemeData(style: secondary()),
      textButtonTheme: TextButtonThemeData(style: text),
    );
  }

  static ButtonStyle get primary => FilledButton.styleFrom(
    backgroundColor: AppColors.sunset,
    foregroundColor: AppColors.backgroundSurface,
    disabledBackgroundColor: AppColors.sunset.withValues(alpha: 0.45),
    disabledForegroundColor: AppColors.backgroundSurface.withValues(
      alpha: 0.78,
    ),
    minimumSize: defaultMinimumSize,
    padding: defaultPadding,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    textStyle: AppTextStyles.chipLabel(color: AppColors.backgroundSurface),
  );

  static ButtonStyle get danger => FilledButton.styleFrom(
    backgroundColor: AppColors.negative,
    foregroundColor: AppColors.backgroundSurface,
    disabledBackgroundColor: AppColors.negative.withValues(alpha: 0.32),
    disabledForegroundColor: AppColors.backgroundSurface.withValues(
      alpha: 0.72,
    ),
    minimumSize: defaultMinimumSize,
    padding: defaultPadding,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    textStyle: AppTextStyles.chipLabel(color: AppColors.backgroundSurface),
  );

  static ButtonStyle secondary({
    Color foregroundColor = AppColors.sunsetDark,
    Color borderColor = AppColors.sunset,
    double minWidth = 96,
    double minHeight = 40,
    bool emphasized = false,
    EdgeInsetsGeometry? padding,
  }) {
    return OutlinedButton.styleFrom(
      minimumSize: Size(minWidth, minHeight),
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      foregroundColor: foregroundColor,
      disabledForegroundColor: AppColors.textMuted.withValues(alpha: 0.55),
      side: BorderSide(color: borderColor, width: emphasized ? 1.2 : 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.chipLabel(color: foregroundColor),
    );
  }

  static ButtonStyle dangerSecondary({double minWidth = 96}) => secondary(
    foregroundColor: AppColors.negative,
    borderColor: AppColors.negative,
    minWidth: minWidth,
  );

  static ButtonStyle tonal({required bool destructive}) {
    final foreground = destructive ? AppColors.negative : AppColors.sunsetDark;
    final background = destructive
        ? AppColors.negative.withValues(alpha: 0.15)
        : AppColors.sunset.withValues(alpha: 0.15);
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      disabledBackgroundColor: AppColors.borderSubtle.withValues(alpha: 0.6),
      disabledForegroundColor: AppColors.textMuted.withValues(alpha: 0.65),
      minimumSize: defaultMinimumSize,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.chipLabel(color: foreground),
    );
  }

  static ButtonStyle filter({
    required bool active,
    Color activeColor = AppColors.sunsetDark,
    Color inactiveColor = AppColors.textPrimary,
  }) {
    final foreground = active ? activeColor : inactiveColor;
    return OutlinedButton.styleFrom(
      backgroundColor: active
          ? AppColors.sunset.withValues(alpha: 0.12)
          : AppColors.backgroundSurface,
      foregroundColor: foreground,
      side: BorderSide(
        color: active ? AppColors.sunset : AppColors.borderSubtle,
        width: active ? 1.2 : 1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      minimumSize: const Size(40, 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.body12(color: foreground),
    );
  }

  static ButtonStyle approval({required bool selected}) {
    final background = selected
        ? AppColors.positive
        : AppColors.positive.withValues(alpha: 0.85);
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: AppColors.backgroundSurface,
      minimumSize: const Size(88, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.chipLabel(color: AppColors.backgroundSurface),
    );
  }

  static ButtonStyle reject({required bool selected}) => secondary(
    foregroundColor: AppColors.negative,
    borderColor: selected
        ? AppColors.negative
        : AppColors.negative.withValues(alpha: 0.6),
    minWidth: 88,
    minHeight: 36,
    emphasized: selected,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  static ButtonStyle get text => TextButton.styleFrom(
    foregroundColor: AppColors.sunsetDark,
    disabledForegroundColor: AppColors.textMuted.withValues(alpha: 0.55),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    textStyle: AppTextStyles.chipLabel(color: AppColors.sunsetDark),
  );
}
