import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Backgrounds — Shell + warm cream (beach-sand base) ───────────────────
  static const Color backgroundDeep = Color(0xFFF8EDE6);
  static const Color backgroundMid = Color(0xFFEFE8E0);
  static const Color backgroundSurface = Color(0xFFFFFFFF);

  // ── Brand — Sunset primary + Peacock secondary ────────────────────────────
  static const Color sunset = Color(0xFFCC7A3E);
  static const Color sunsetDark = Color(0xFF9A5C2A);
  static const Color jade = Color(0xFFA8D8D0);

  // ── Text hierarchy — warm darks on light ──────────────────────────────────
  static const Color textPrimary = Color(0xFF2C2C2C);
  static const Color textSecondary = Color(0xFF5A524A);
  static const Color textMuted = Color(0xFF5E564E);

  // ── Directional — must be immediately readable on light ───────────────────
  static const Color positive = Color(0xFF256B29);
  static const Color negative = Color(0xFFC62828);
  static const Color warning = Color(0xFF997000);
  static const Color neutral = Color(0xFF5E564E);

  // ── Premium surface — soft gradient helpers ────────────────────────────────
  static const Color shimmer = Color(0xFFE8E2DA);
  static const Color cardGlow = Color(0xFFF2ECE4);

  // ── Borders ───────────────────────────────────────────────────────────────
  static const Color borderSubtle = Color(0xFFDDD6CC);
  static const Color borderStrong = Color(0xFFCC7A3E);

  // ── Named inspo palette ────────────────────────────────────────────────────
  static const Color redSand = Color(0xFFE8A87C);
  static const Color peacock = Color(0xFF0E8080);
  static const Color peacockDark = Color(0xFF0A6060);
  static const Color ocean = Color(0xFF14B4AC);
  static const Color shell = Color(0xFFF8EDE6);
  static const Color warningBadgeBg = Color(0x26997000); // warning @ 15%

  // ── Backward-compatible aliases ───────────────────────────────────────────
  static const Color background = backgroundDeep;
  static const Color surface = backgroundMid;
  static const Color primaryText = textPrimary;
  static const Color secondaryText = textSecondary;
  static const Color accent = sunset;
  static const Color rule = borderSubtle;
}

class AppTextStyles {
  static bool get _isWidgetTestBinding =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  static bool get _usesRuntimeGoogleFonts => !_isWidgetTestBinding && !kIsWeb;

  static TextStyle _playfair(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.playfairDisplay(textStyle: style)
      : style;

  static TextStyle _mono(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.ibmPlexMono(textStyle: style)
      : style;

  static TextStyle _sans(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.ibmPlexSans(textStyle: style)
      : style;
  // ── Display — Playfair Display ────────────────────────────────────────────
  static TextStyle display36({Color? color}) => _playfair(
    TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w700,
      color: color ?? AppColors.textPrimary,
      height: 1.1,
    ),
  );

  static TextStyle display28({Color? color}) => _playfair(
    TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.textPrimary,
      height: 1.2,
    ),
  );

  static TextStyle display20({Color? color}) => _playfair(
    TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.textPrimary,
      height: 1.3,
    ),
  );

  static TextStyle display16({Color? color}) => _playfair(
    TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.textPrimary,
    ),
  );

  // ── Mono — IBM Plex Mono ──────────────────────────────────────────────────
  static TextStyle mono28({Color? color, FontWeight? weight}) => _mono(
    TextStyle(
      fontSize: 28,
      fontWeight: weight ?? FontWeight.w700,
      color: color ?? AppColors.textPrimary,
      height: 1.1,
    ),
  );

  static TextStyle mono22({Color? color}) => _mono(
    TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      color: color ?? AppColors.textPrimary,
    ),
  );

  static TextStyle mono20({Color? color, FontWeight? weight}) => _mono(
    TextStyle(
      fontSize: 20,
      fontWeight: weight ?? FontWeight.w700,
      color: color ?? AppColors.textPrimary,
    ),
  );

  static TextStyle mono16({Color? color}) => _mono(
    TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: color ?? AppColors.textPrimary,
    ),
  );

  static TextStyle mono15({Color? color, FontWeight? weight}) => _mono(
    TextStyle(
      fontSize: 15,
      fontWeight: weight ?? FontWeight.w500,
      color: color ?? AppColors.textPrimary,
    ),
  );

  static TextStyle mono14({Color? color, FontWeight? weight}) => _mono(
    TextStyle(
      fontSize: 14,
      fontWeight: weight ?? FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.4,
    ),
  );

  static TextStyle mono12({Color? color, FontWeight? weight}) => _mono(
    TextStyle(
      fontSize: 12,
      fontWeight: weight ?? FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.4,
    ),
  );

  static TextStyle mono11({Color? color}) => _mono(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textMuted,
    ),
  );

  static TextStyle mono10({Color? color}) => _mono(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      height: 1.4,
    ),
  );

  static TextStyle mono8({Color? color}) => _mono(
    TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textSecondary,
    ),
  );

  static TextStyle mono7({Color? color}) => _mono(
    TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textSecondary,
    ),
  );

  // ── Body — IBM Plex Sans ──────────────────────────────────────────────────
  static TextStyle body15({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.5,
      fontStyle: style,
    ),
  );

  static TextStyle body14({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.textPrimary,
      fontStyle: style,
    ),
  );

  static TextStyle body13({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.6,
      fontStyle: style,
    ),
  );

  static TextStyle body12({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      fontStyle: style ?? FontStyle.italic,
    ),
  );

  static TextStyle body11({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      fontStyle: style ?? FontStyle.italic,
    ),
  );

  static TextStyle pageTitle({Color? color}) => _sans(
    TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      color: color ?? AppColors.textPrimary,
      height: 1.18,
    ),
  );

  static TextStyle sectionTitle({Color? color}) => _sans(
    TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: color ?? AppColors.textPrimary,
      height: 1.35,
    ),
  );

  static TextStyle uiLabel({
    Color? color,
    FontWeight? weight,
    FontStyle? style,
  }) => _sans(
    TextStyle(
      fontSize: 12,
      fontWeight: weight ?? FontWeight.w700,
      color: color ?? AppColors.textMuted,
      height: 1.25,
      fontStyle: style,
    ),
  );

  static TextStyle chipLabel({Color? color}) => _sans(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: color ?? AppColors.textSecondary,
      height: 1.2,
    ),
  );
}

class AppTheme {
  static ThemeData get themeData => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.backgroundDeep,
    colorScheme: const ColorScheme.light(
      surface: AppColors.backgroundMid,
      primary: AppColors.sunsetDark,
      onPrimary: AppColors.backgroundSurface,
      onSurface: AppColors.textPrimary,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.backgroundSurface,
      selectedItemColor: AppColors.sunsetDark,
      unselectedItemColor: AppColors.textMuted,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      showSelectedLabels: true,
      showUnselectedLabels: true,
      selectedLabelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
      ),
    ),
    dividerColor: AppColors.borderSubtle,
    cardColor: AppColors.backgroundSurface,
    textTheme: AppTextStyles._usesRuntimeGoogleFonts
        ? GoogleFonts.ibmPlexSansTextTheme(
            const TextTheme(
              bodyMedium: TextStyle(color: AppColors.textPrimary),
              bodySmall: TextStyle(color: AppColors.textSecondary),
            ),
          )
        : const TextTheme(
            bodyMedium: TextStyle(color: AppColors.textPrimary),
            bodySmall: TextStyle(color: AppColors.textSecondary),
          ),
    useMaterial3: true,
  );
}
