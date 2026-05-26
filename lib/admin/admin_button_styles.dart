import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'admin_visual_system.dart';

class AdminButtonStyles {
  const AdminButtonStyles._();

  static const double radius = AdminVisualSystem.surfaceRadius;
  static const double controlHeight = 48;
  static const double denseControlHeight = 44;
  static const double iconHitTarget = 50;
  static const double defaultMinWidth = 104;
  static const Size defaultMinimumSize = Size(defaultMinWidth, controlHeight);
  static const EdgeInsets defaultPadding = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 13,
  );

  // Operator-web is the typography gold standard: its dialog titles render
  // in the Playfair display family via [OperatorWebDialog] (display20).
  // Match it here so admin dialogs that lean on the shared dialog theme
  // (DialogThemeData.titleTextStyle below) carry the same Playfair title
  // rather than the smaller sans pageTitle@20 admin used before.
  static TextStyle get dialogTitleStyle =>
      AppTextStyles.display20(color: AppColors.textPrimary);

  static ThemeData applyTo(ThemeData base) {
    return base.copyWith(
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.backgroundSurface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        titleTextStyle: dialogTitleStyle,
        contentTextStyle: AppTextStyles.body13(color: AppColors.textSecondary),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      inputDecorationTheme: _inputDecorationTheme,
      dataTableTheme: _dataTableTheme,
      tabBarTheme: _tabBarTheme,
      listTileTheme: _listTileTheme,
      chipTheme: _chipTheme(base.chipTheme),
      dropdownMenuTheme: _dropdownMenuTheme,
      popupMenuTheme: _popupMenuTheme,
      snackBarTheme: _snackBarTheme,
      tooltipTheme: _tooltipTheme,
      segmentedButtonTheme: _segmentedButtonTheme,
      filledButtonTheme: FilledButtonThemeData(style: primary),
      outlinedButtonTheme: OutlinedButtonThemeData(style: secondary()),
      textButtonTheme: TextButtonThemeData(style: text),
      iconButtonTheme: IconButtonThemeData(style: icon),
    );
  }

  static ButtonStyle get primary => FilledButton.styleFrom(
    backgroundColor: AppColors.sunset,
    foregroundColor: AppColors.backgroundSurface,
    disabledBackgroundColor: AppColors.borderSubtle,
    disabledForegroundColor: AppColors.textMuted,
    minimumSize: defaultMinimumSize,
    padding: defaultPadding,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    textStyle: AppTextStyles.buttonLabel(color: AppColors.backgroundSurface),
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
    textStyle: AppTextStyles.buttonLabel(color: AppColors.backgroundSurface),
  );

  static ButtonStyle secondary({
    Color foregroundColor = AppColors.sunsetDark,
    Color borderColor = AppColors.borderSubtle,
    double minWidth = defaultMinWidth,
    double minHeight = controlHeight,
    bool emphasized = false,
    EdgeInsetsGeometry? padding,
  }) {
    return OutlinedButton.styleFrom(
      minimumSize: Size(minWidth, minHeight),
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      foregroundColor: foregroundColor,
      disabledForegroundColor: AppColors.textMuted.withValues(alpha: 0.55),
      side: BorderSide(
        color: emphasized ? foregroundColor : borderColor,
        width: emphasized ? 1.2 : 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.buttonLabel(color: foregroundColor),
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
      textStyle: AppTextStyles.buttonLabel(color: foreground),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      minimumSize: const Size(44, 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.buttonLabel(color: foreground),
    );
  }

  static ButtonStyle approval({required bool selected}) {
    final background = selected
        ? AppColors.positive
        : AppColors.positive.withValues(alpha: 0.85);
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: AppColors.backgroundSurface,
      minimumSize: const Size(96, 40),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: AppTextStyles.buttonLabel(color: AppColors.backgroundSurface),
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
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    textStyle: AppTextStyles.buttonLabel(color: AppColors.sunsetDark),
  );

  static ButtonStyle get icon => IconButton.styleFrom(
    foregroundColor: AppColors.sunsetDark,
    disabledForegroundColor: AppColors.textMuted.withValues(alpha: 0.55),
    highlightColor: AppColors.sunset.withValues(alpha: 0.10),
    hoverColor: AppColors.sunset.withValues(alpha: 0.08),
    focusColor: AppColors.sunset.withValues(alpha: 0.10),
    minimumSize: const Size(iconHitTarget, iconHitTarget),
    padding: const EdgeInsets.all(8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
  );

  static InputDecorationThemeData get _inputDecorationTheme {
    final radius = BorderRadius.circular(AdminButtonStyles.radius);
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.backgroundSurface,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.sunsetDark, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.negative, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.negative, width: 1.4),
      ),
      labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
      floatingLabelStyle: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
      hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
      helperStyle: AppTextStyles.caption(color: AppColors.textSecondary),
      errorStyle: AppTextStyles.caption(color: AppColors.negative),
    );
  }

  static DataTableThemeData get _dataTableTheme => DataTableThemeData(
    headingTextStyle: AppTextStyles.body15Bold(color: AppColors.textPrimary),
    dataTextStyle: AppTextStyles.body13(color: AppColors.textPrimary),
    headingRowHeight: 56,
    dataRowMinHeight: 56,
    dataRowMaxHeight: 84,
    horizontalMargin: 20,
    columnSpacing: 30,
    dividerThickness: 1,
    decoration: BoxDecoration(
      color: AppColors.backgroundSurface,
      border: Border.all(color: AppColors.borderSubtle, width: 1),
      borderRadius: BorderRadius.circular(radius),
    ),
  );

  static TabBarThemeData get _tabBarTheme => TabBarThemeData(
    labelColor: AppColors.textPrimary,
    unselectedLabelColor: AppColors.textMuted,
    labelStyle: AppTextStyles.body15Bold(color: AppColors.textPrimary),
    unselectedLabelStyle: AppTextStyles.body14(color: AppColors.textMuted),
    labelPadding: AdminVisualSystem.tabPadding,
    indicatorColor: AppColors.sunsetDark,
    indicatorSize: TabBarIndicatorSize.label,
    dividerColor: AppColors.borderSubtle,
  );

  static ListTileThemeData get _listTileTheme => ListTileThemeData(
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    minVerticalPadding: 12,
    titleTextStyle: AppTextStyles.body14(color: AppColors.textPrimary),
    subtitleTextStyle: AppTextStyles.body13(color: AppColors.textSecondary),
    leadingAndTrailingTextStyle: AppTextStyles.body13(
      color: AppColors.textSecondary,
    ),
    iconColor: AppColors.sunsetDark,
  );

  static ChipThemeData _chipTheme(ChipThemeData base) => base.copyWith(
    labelStyle: AppTextStyles.chipLabel(color: AppColors.textPrimary),
    secondaryLabelStyle: AppTextStyles.chipLabel(color: AppColors.textPrimary),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    side: const BorderSide(color: AppColors.borderSubtle, width: 1),
  );

  static DropdownMenuThemeData get _dropdownMenuTheme => DropdownMenuThemeData(
    textStyle: AppTextStyles.body13(color: AppColors.textPrimary),
    inputDecorationTheme: _inputDecorationTheme,
  );

  static PopupMenuThemeData get _popupMenuTheme => PopupMenuThemeData(
    color: AppColors.backgroundSurface,
    surfaceTintColor: Colors.transparent,
    textStyle: AppTextStyles.body13(color: AppColors.textPrimary),
    labelTextStyle: WidgetStatePropertyAll(
      AppTextStyles.body13(color: AppColors.textPrimary),
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: const BorderSide(color: AppColors.borderSubtle, width: 1),
    ),
  );

  static SnackBarThemeData get _snackBarTheme => SnackBarThemeData(
    backgroundColor: AppColors.textPrimary,
    contentTextStyle: AppTextStyles.body13(color: AppColors.backgroundSurface),
    actionTextColor: AppColors.jade,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
  );

  static TooltipThemeData get _tooltipTheme => TooltipThemeData(
    textStyle: AppTextStyles.caption(color: AppColors.backgroundSurface),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppColors.textPrimary,
      borderRadius: BorderRadius.circular(radius),
    ),
  );

  static SegmentedButtonThemeData get _segmentedButtonTheme =>
      SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            AppTextStyles.buttonLabel(color: AppColors.textPrimary),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(44, 40)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      );
}
