import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const Color background = Color(0xFF0D1B2A);
  static const Color surface = Color(0xFF162235);
  static const Color primaryText = Color(0xFFF0F4F8);
  static const Color secondaryText = Color(0xFF7A9BB5);
  static const Color accent = Color(0xFF3DBFBF);
  static const Color positive = Color(0xFF2E9E6B);
  static const Color gold = Color(0xFF3DBFBF);
  static const Color rule = Color(0xFF1E3347);
  static const Color slateTag = Color(0xFF1E3347);
}

class AppTextStyles {
  // Display — Playfair Display
  static TextStyle display28({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.primaryText,
        height: 1.2,
      );

  static TextStyle display20({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.primaryText,
        height: 1.3,
      );

  static TextStyle display16({Color? color}) => GoogleFonts.playfairDisplay(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.primaryText,
      );

  // Mono — IBM Plex Mono
  static TextStyle mono22({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.primaryText,
      );

  static TextStyle mono16({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.primaryText,
      );

  static TextStyle mono14({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 14,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? AppColors.primaryText,
      );

  static TextStyle mono12({Color? color, FontWeight? weight}) =>
      GoogleFonts.ibmPlexMono(
        fontSize: 12,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? AppColors.primaryText,
      );

  static TextStyle mono10({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 10,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.secondaryText,
      );

  static TextStyle mono8({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 8,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: color ?? AppColors.secondaryText,
      );

  static TextStyle mono7({Color? color}) => GoogleFonts.ibmPlexMono(
        fontSize: 7,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.5,
        color: color ?? AppColors.secondaryText,
      );

  // Body — IBM Plex Sans
  static TextStyle body14({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: color ?? AppColors.primaryText,
        fontStyle: style,
      );

  static TextStyle body13({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.primaryText,
        height: 1.6,
        fontStyle: style,
      );

  static TextStyle body12({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.secondaryText,
        fontStyle: style ?? FontStyle.italic,
      );

  static TextStyle body11({Color? color, FontStyle? style}) =>
      GoogleFonts.ibmPlexSans(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: color ?? AppColors.secondaryText,
        fontStyle: style ?? FontStyle.italic,
      );
}

class AppTheme {
  static ThemeData get themeData => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          surface: AppColors.surface,
          primary: AppColors.accent,
          onPrimary: AppColors.primaryText,
          onSurface: AppColors.primaryText,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.accent,
          unselectedItemColor: AppColors.secondaryText,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedLabelStyle: TextStyle(fontSize: 10),
          unselectedLabelStyle: TextStyle(fontSize: 10),
        ),
        dividerColor: AppColors.rule,
        cardColor: AppColors.surface,
        textTheme: GoogleFonts.ibmPlexSansTextTheme(
          const TextTheme(
            bodyMedium: TextStyle(color: AppColors.primaryText),
            bodySmall: TextStyle(color: AppColors.secondaryText),
          ),
        ),
        useMaterial3: true,
      );
}
