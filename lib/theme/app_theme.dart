import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Backgrounds — layered depth ──────────────────────────────────────────
  static const Color backgroundDeep = Color(0xFF0D1528);
  static const Color backgroundMid = Color(0xFF152040);
  static const Color backgroundSurface = Color(0xFF1C2E55);

  // ── Brand — from Barrio Legado business plan ─────────────────────────────
  static const Color tealPrimary = Color(0xFF3DCFCF);
  static const Color tealSoft = Color(0xFF2A9E9E);
  static const Color navyAccent = Color(0xFF1A3A6E);

  // ── Text hierarchy ────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB8D4E8);
  static const Color textMuted = Color(0xFF6B8FAF);

  // ── Directional — must be immediately readable ────────────────────────────
  static const Color positive = Color(0xFF2ECC71);
  static const Color negative = Color(0xFFE74C3C);
  static const Color warning = Color(0xFFF39C12);
  static const Color neutral = Color(0xFF6B8FAF);

  // ── Variance specific ─────────────────────────────────────────────────────
  static const Color varianceAlert = Color(0xFFE74C3C);
  static const Color theoreticalColor = Color(0xFFB8D4E8);

  // ── Premium surface ────────────────────────────────────────────────────────
  static const Color shimmer = Color(0xFF1A3050);
  static const Color cardGlow = Color(0xFF0F1E35);

  // ── Borders ───────────────────────────────────────────────────────────────
  static const Color borderSubtle = Color(0xFF1E3A5F);
  static const Color borderStrong = Color(0xFF3DCFCF);

  // ── Backward-compatible aliases ───────────────────────────────────────────
  static const Color background = backgroundDeep;
  static const Color surface = backgroundMid;
  static const Color primaryText = textPrimary;
  static const Color secondaryText = textSecondary;
  static const Color accent = tealPrimary;
  static const Color gold = tealPrimary;
  static const Color rule = borderSubtle;
  static const Color slateTag = navyAccent;
}

class AppTextStyles {
  // ── Display — Playfair Display ────────────────────────────────────────────
  static TextStyle display36({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        color: color ?? AppColors.textPrimary,
        height: 1.1,
      );

  static TextStyle display28({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.textPrimary,
        height: 1.2,
      );

  static TextStyle display20({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.textPrimary,
        height: 1.3,
      );

  static TextStyle display16({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.textPrimary,
      );

  // ── Mono — IBM Plex Mono ──────────────────────────────────────────────────
  static TextStyle mono28({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 28,
        fontWeight: weight ?? FontWeight.w700,
        color: color ?? AppColors.textPrimary,
        height: 1.1,
      );

  static TextStyle mono22({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono20({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 20,
        fontWeight: weight ?? FontWeight.w700,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono16({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono15({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 15,
        fontWeight: weight ?? FontWeight.w500,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono14({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 14,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono12({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 12,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? AppColors.textPrimary,
      );

  static TextStyle mono11({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: color ?? AppColors.textMuted,
      );

  static TextStyle mono10({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 10,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.textSecondary,
      );

  static TextStyle mono8({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 8,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: color ?? AppColors.textSecondary,
      );

  static TextStyle mono7({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 7,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.5,
        color: color ?? AppColors.textSecondary,
      );

  // ── Body — IBM Plex Sans ──────────────────────────────────────────────────
  static TextStyle body15({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.textPrimary,
        height: 1.5,
        fontStyle: style,
      );

  static TextStyle body14({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.textPrimary,
        fontStyle: style,
      );

  static TextStyle body13({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.textPrimary,
        height: 1.6,
        fontStyle: style,
      );

  static TextStyle body12({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.textSecondary,
        fontStyle: style ?? FontStyle.italic,
      );

  static TextStyle body11({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.textSecondary,
        fontStyle: style ?? FontStyle.italic,
      );
}

class AppTheme {
  static ThemeData get themeData => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.backgroundDeep,
        colorScheme: const ColorScheme.dark(
          surface: AppColors.backgroundMid,
          primary: AppColors.tealPrimary,
          onPrimary: AppColors.textPrimary,
          onSurface: AppColors.textPrimary,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.backgroundDeep,
          selectedItemColor: AppColors.tealPrimary,
          unselectedItemColor: AppColors.textMuted,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedLabelStyle:
              TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              TextStyle(fontSize: 10, fontWeight: FontWeight.w400),
        ),
        dividerColor: AppColors.borderSubtle,
        cardColor: AppColors.backgroundMid,
        textTheme: GoogleFonts.ibmPlexSansTextTheme(
          const TextTheme(
            bodyMedium: TextStyle(color: AppColors.textPrimary),
            bodySmall: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        useMaterial3: true,
      );
}
