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

/// Spacing scale — single source of truth for padding / gaps / insets.
///
/// 4/8pt rhythm. Use these instead of ad-hoc literals so screens share a
/// consistent vertical/horizontal cadence (readability + scannability).
/// See `docs/contracts/mobile_typography_and_spacing_contract.md`.
class AppSpacing {
  AppSpacing._();

  /// 4 — hairline gaps inside a control (icon↔label).
  static const double xs = 4;

  /// 8 — tight gap between closely-related rows.
  static const double sm = 8;

  /// 12 — default gap between items in a list/stack.
  static const double md = 12;

  /// 16 — standard screen edge padding + card inner padding.
  static const double lg = 16;

  /// 24 — separation between distinct sections.
  static const double xl = 24;

  /// 32 — major section / screen-block break.
  static const double xxl = 32;

  /// Standard horizontal screen gutter.
  static const EdgeInsets screenH = EdgeInsets.symmetric(horizontal: lg);

  /// Standard card inner padding.
  static const EdgeInsets card = EdgeInsets.all(lg);

  /// Standard list-row vertical rhythm.
  static const EdgeInsets row = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: md,
  );
}

/// Corner-radius scale — collapses the ad-hoc 2/3/4/6/8/10/12/16/20px
/// zoo into three intentional steps. Premium feel = ONE consistent
/// rounding, not nine. See the typography/spacing contract.
class AppRadius {
  AppRadius._();

  /// 6 — chips, badges, small inline controls.
  static const double small = 6;

  /// 10 — the standard surface: cards, tiles, panels, inputs.
  static const double card = 10;

  /// 999 — fully rounded (pills, avatars).
  static const double pill = 999;

  static const BorderRadius smallR = BorderRadius.all(Radius.circular(small));
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius pillR = BorderRadius.all(Radius.circular(pill));
}

/// Shared surface decorations — one hairline-bordered card treatment so
/// screens stop hand-rolling `Container` + random-alpha `Border.all` +
/// random `borderRadius`. Calmer, consistent, premium.
class AppDecoration {
  AppDecoration._();

  /// Single hairline border opacity (was 0.4–0.7 scattered ad-hoc).
  static const double hairlineAlpha = 0.7;

  static final Border hairline = Border.all(
    color: AppColors.borderSubtle.withValues(alpha: hairlineAlpha),
    width: 1,
  );

  /// Standard elevated surface: white, hairline border, card radius.
  static final BoxDecoration surfaceCard = BoxDecoration(
    color: AppColors.backgroundSurface,
    border: hairline,
    borderRadius: AppRadius.cardR,
  );

  /// Tinted accent chip surface (badges/status). Pass the accent colour;
  /// fill + border opacities are fixed so every chip matches.
  static BoxDecoration accentChip(Color accent) => BoxDecoration(
    color: accent.withValues(alpha: 0.12),
    border: Border.all(color: accent.withValues(alpha: 0.45), width: 1),
    borderRadius: AppRadius.smallR,
  );
}

/// Hairline divider. Replaces hand-rolled
/// `Container(height: 1, color: AppColors.borderSubtle)` so spacing and
/// weight are consistent everywhere.
class AppDivider extends StatelessWidget {
  const AppDivider({super.key, this.indent = 0});

  /// Symmetric horizontal inset (e.g. to align with card padding).
  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: indent),
    child: Container(
      height: 1,
      color: AppColors.borderSubtle.withValues(
        alpha: AppDecoration.hairlineAlpha,
      ),
    ),
  );
}

/// Text scale roles.
///
/// IMPORTANT: the legacy method names below (e.g. `body11`, `mono10`) name a
/// HISTORICAL pixel size, not the current one. The `fontSize:` value in each
/// body is authoritative. Prefer the semantic aliases at the bottom of this
/// class (`bodyText`, `caption`, `sectionHeading`, …) in new code — the raw
/// names are kept only so the existing call sites keep compiling. Full role
/// map: `docs/contracts/mobile_typography_and_spacing_contract.md`.
class AppTextStyles {
  static const String webFallbackFontFamily = 'Arial';

  static bool get _isWidgetTestBinding =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  static bool get _usesRuntimeGoogleFonts => !_isWidgetTestBinding && !kIsWeb;

  static TextStyle _webSafe(TextStyle style) =>
      kIsWeb ? style.copyWith(fontFamily: webFallbackFontFamily) : style;

  static TextStyle _playfair(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.playfairDisplay(textStyle: style)
      : _webSafe(style);

  static TextStyle _mono(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.ibmPlexMono(textStyle: style)
      : _webSafe(style);

  static TextStyle _sans(TextStyle style) => _usesRuntimeGoogleFonts
      ? GoogleFonts.ibmPlexSans(textStyle: style)
      : _webSafe(style);
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
      fontSize: 13,
      fontWeight: weight ?? FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.4,
    ),
  );

  static TextStyle mono11({Color? color}) => _mono(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textMuted,
      height: 1.35,
    ),
  );

  static TextStyle mono10({Color? color}) => _mono(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      height: 1.4,
    ),
  );

  static TextStyle mono8({Color? color}) => _mono(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textSecondary,
      height: 1.3,
    ),
  );

  static TextStyle mono7({Color? color}) => _mono(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: color ?? AppColors.textSecondary,
      height: 1.3,
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
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.textPrimary,
      height: 1.4,
      fontStyle: style,
    ),
  );

  static TextStyle body13({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      height: 1.5,
      fontStyle: style,
    ),
  );

  // Secondary/caption text. Default upright (small italic hurts legibility);
  // callers that want emphasis pass `style: FontStyle.italic` explicitly.
  static TextStyle body12({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      height: 1.45,
      fontStyle: style,
    ),
  );

  static TextStyle body11({Color? color, FontStyle? style}) => _sans(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textSecondary,
      height: 1.4,
      fontStyle: style,
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
      fontSize: 16,
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

  // ── Semantic roles (preferred in new code) ────────────────────────────────
  // Seven honest, named roles. These delegate to the primitives above so
  // there is exactly one place each size/weight lives. Use these names so
  // intent is obvious at the call site and the scale stays scannable.

  /// Screen / page title. One per screen.
  static TextStyle screenTitle({Color? color}) => pageTitle(color: color);

  /// Section heading inside a screen.
  static TextStyle sectionHeading({Color? color}) => sectionTitle(color: color);

  /// Default reading text.
  static TextStyle bodyText({Color? color}) => body13(color: color);

  /// Emphasised reading text (same size, heavier).
  static TextStyle bodyStrong({Color? color}) => body14(color: color);

  /// Secondary / helper / caption text.
  static TextStyle caption({Color? color}) => body11(color: color);

  /// Large numeric metric (hero figures).
  static TextStyle metricLarge({Color? color, FontWeight? weight}) =>
      mono22(color: color);

  /// Inline numeric metric (table cells, chips).
  static TextStyle metricSmall({Color? color, FontWeight? weight}) =>
      mono14(color: color, weight: weight);
}

class AppTheme {
  static ThemeData get themeData => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.backgroundDeep,
    fontFamily: kIsWeb ? AppTextStyles.webFallbackFontFamily : null,
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
          ).apply(
            fontFamily: kIsWeb ? AppTextStyles.webFallbackFontFamily : null,
          ),
    useMaterial3: true,
  );
}
