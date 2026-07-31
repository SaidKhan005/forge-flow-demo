import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Barrio-private colors for the internal shell.
///
/// Light theme drawn from the Barrio Legado app icon: warm cream page,
/// deep navy text, teal accents (the "BL" mark is deep navy with teal
/// leaves on a cream ground). These extend the Forge & Flow palette with
/// warmer, hospitality-driven tones for the Barrio shell experience.
class BarrioColors {
  BarrioColors._();

  // Shell backgrounds — warm cream light theme (icon palette)
  static const Color shellDeep    = Color(0xFFF7F3EA); // warm cream page base
  static const Color shellMid     = Color(0xFFFFFFFF); // card surface (white)
  static const Color shellSurface = Color(0xFFF1F5F0); // raised element, faint mint

  // Barrio Legado brand palette
  static const Color cream     = Color(0xFFFAF7F2); // warm cream (light mode only)
  static const Color navy      = Color(0xFF1A2456); // deep navy accent
  static const Color gold      = Color(0xFFDFAA40); // warm gold — richer
  static const Color botanical = Color(0xFF2D5A3D); // botanical green

  // Destination accent identities — each destination owns a bloom color
  static const Color accentHandbook  = Color(0xFFD4584C); // warm brick red
  static const Color accentPlaybook  = Color(0xFF2ECC71); // emerald green
  static const Color accentJimTaylor = Color(0xFF3A6ED0); // royal blue — matches book
  static const Color accentPreston   = Color(0xFFCC8A3A); // warm amber — matches photo
  static const Color accentForge     = Color(0xFF3A82FF); // electric blue

  // Training-bubble accent identities (2026-07-11 training-drop slice)
  static const Color accentSeafoam = Color(0xFF5FB8A6); // seafoam — table manicuring
  static const Color accentPlum    = Color(0xFFB06AC9); // plum — three pillars
  static const Color accentCoffee  = Color(0xFF9A6B4F); // roasted brown — coffee
  static const Color accentHerb    = Color(0xFF7FA84C); // herb green — ingredients
  static const Color accentSteel   = Color(0xFF5A7BD8); // steel blue: bold by design
  static const Color accentFresh   = Color(0xFF52B788); // fresh green: food safety

  // Brand teal — tealWarm stays for fills/accents; tealDeep is the
  // legible teal for TEXT or thin borders on the cream ground.
  static const Color tealWarm  = Color(0xFF40CFCF); // slightly brighter/more saturated
  static const Color tealGlow  = Color(0xFF2CBCBC);
  static const Color tealMuted = Color(0xFF1A9898);
  static const Color tealFaint = Color(0x1A40CFCF);
  static const Color tealDeep  = Color(0xFF2E9B8F); // icon-leaf teal — teal text on cream
  // Bold, vivid deep teal for key-term emphasis on cream: AA-compliant at
  // 4.74:1 against shellDeep (#F7F3EA), and far more saturated than the
  // prior #1E7268 (HSL S ~0.82 vs ~0.58) so the rollout reads bolder.
  // Paired with w700 as the required non-color cue. (tealDeep is only
  // ~3.06:1 and FAILS AA for body text; use tealInk for key-term emphasis.)
  static const Color tealInk   = Color(0xFF0C7A68);

  // Text hierarchy — deep navy on cream (icon palette)
  static const Color textPrimary   = Color(0xFF16243B); // deep navy
  static const Color textSecondary = Color(0xFF44586A); // slate navy
  static const Color textMuted     = Color(0xFF7B8A94); // muted slate

  // Accents
  static const Color comingSoonTag = Color(0xFF8B6F47);
  static const Color audienceTag   = Color(0xFF1E3A5F);

  // Semantic status tokens (2026-07-31 premium pass) — one source of truth for
  // the green/amber/red that were previously hardcoded across ~10 files.
  static const Color success = Color(0xFF2ECC71); // emerald — correct / positive
  static const Color warning = Color(0xFFF39C12); // amber — caution / quiz accent
  static const Color error   = Color(0xFFE74C3C); // red — wrong / negative

  // Premium frosted-white card fill — previously written three ways
  // (#F2FFFFFF, #E6FFFFFF, shellMid@0.92). One token now.
  static const Color glassFill = Color(0xF2FFFFFF); // ~95% white glass on cream

  // Trophy gold for El Podio — deliberately distinct from brand [gold].
  static const Color trophyGold = Color(0xFFD4AF37);
}

/// Shared corner-radius scale for a cohesive premium feel (2026-07-31).
/// One ladder instead of the prior 6..24 spread. Cards and fields align on
/// [card]; small pills/badges on [chip]; bottom sheets on [sheet].
class BarrioRadii {
  BarrioRadii._();
  static const double chip = 10; // pills, badges, small chips, thumbnails
  static const double card = 16; // cards, flashcards, search fields, rows
  static const double sheet = 24; // bottom sheets
}

/// The one soft neutral lift used by every premium surface (cards, flashcards,
/// quiz cards, search fields). A single navy-tinted drop shadow, NO colored
/// glow — matching the de-glowed home bubbles (2026-07-27 premium pass), so the
/// shadow language is consistent app-wide.
List<BoxShadow> barrioSoftShadow({
  double y = 10,
  double blur = 24,
  double opacity = 0.10,
}) {
  return <BoxShadow>[
    BoxShadow(
      color: BarrioColors.textPrimary.withValues(alpha: opacity),
      blurRadius: blur,
      offset: Offset(0, y),
    ),
  ];
}

// ---------------------------------------------------------------------------
// Premium ambient background — used by all Barrio destination screens
// ---------------------------------------------------------------------------

/// Wraps a screen body in a warm cream background with a soft, low-alpha
/// accent bloom. Use this on every Barrio destination screen so the
/// premium light feel is consistent.
///
/// The bloom is atmospheric only — no interaction.
class BarrioPremiumBackground extends StatelessWidget {
  final Widget child;

  /// The accent color for the top-corner bloom. Use one of the
  /// [BarrioColors.accent*] constants per destination.
  final Color accentColor;

  /// Where to position the primary bloom. Defaults to top-right.
  final AlignmentGeometry bloomAlignment;

  const BarrioPremiumBackground({
    super.key,
    required this.child,
    this.accentColor = BarrioColors.tealWarm,
    this.bloomAlignment = const Alignment(0.75, -0.9),
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Primary accent bloom — top corner
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: bloomAlignment,
                  radius: 1.05,
                  colors: [
                    // Soft, low-alpha wash on cream — calm, not saturated.
                    accentColor.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        // Complementary navy bloom — opposite corner, subtle depth
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.85, 0.95),
                  radius: 0.75,
                  colors: [
                    Color(0x1A1A2456),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Premium AppBar builder
// ---------------------------------------------------------------------------

/// Returns a consistent premium AppBar for all Barrio destination screens.
/// Shows the [title] in Playfair Display with [accentColor], a back button,
/// and an optional [trailing] widget (e.g., audience chip). A thin
/// gradient rule in the accent color runs along the bottom of the bar.
PreferredSizeWidget barrioAppBar({
  required BuildContext context,
  required String title,
  Color accentColor = BarrioColors.tealWarm,
  Widget? trailing,
}) {
  return PreferredSize(
    preferredSize: const Size.fromHeight(kToolbarHeight + 1),
    child: AppBar(
      backgroundColor: BarrioColors.shellDeep,
      elevation: 0,
      leading: IconButton(
        // Accessibility (rec #12): the tooltip doubles as the screen
        // reader label for the otherwise unlabeled glyph.
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back, color: BarrioColors.textSecondary),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Text(
        title,
        style: GoogleFonts.playfairDisplay(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: accentColor,
          letterSpacing: 0.2,
        ),
      ),
      actions: trailing != null
          ? [Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: trailing))]
          : null,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              accentColor.withValues(alpha: 0.0),
              accentColor.withValues(alpha: 0.45),
              accentColor.withValues(alpha: 0.0),
            ]),
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Reusable scaffold for generic destination screens (e.g. Preston Lee)
// ---------------------------------------------------------------------------

/// Reusable scaffold for Barrio destination screens.
///
/// Provides consistent premium chrome — dark background with accent
/// bloom, gradient AppBar underline, audience labels, and body text.
class BarrioDestinationScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> audienceLabels;
  final String bodyText;
  final bool isComingSoon;
  final Widget? footer;
  final Color accentColor;

  const BarrioDestinationScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.audienceLabels,
    required this.bodyText,
    this.isComingSoon = false,
    this.footer,
    this.accentColor = BarrioColors.tealWarm,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'Barrio',
        accentColor: accentColor,
      ),
      body: BarrioPremiumBackground(
        accentColor: accentColor,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icon + title block
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accentColor.withValues(alpha: 0.10),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.35),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.20),
                            blurRadius: 14,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: Icon(icon, color: accentColor, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: BarrioColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              color: BarrioColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 22),

                // Audience tags
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (isComingSoon) _buildTag('Coming Soon', BarrioColors.gold),
                    ...audienceLabels.map(
                      (l) => _buildTag(l, accentColor.withValues(alpha: 0.12)),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Divider in accent color
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      accentColor.withValues(alpha: 0.4),
                      accentColor.withValues(alpha: 0.0),
                    ]),
                  ),
                ),

                const SizedBox(height: 24),

                // Body text
                Text(
                  bodyText,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 14,
                    height: 1.75,
                    color: BarrioColors.textSecondary,
                  ),
                ),

                const SizedBox(height: 32),

                // Footer
                if (footer != null) footer!,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTag(String label, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x2216243B)),
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
          color: BarrioColors.textSecondary,
        ),
      ),
    );
  }
}
