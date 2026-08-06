import 'dart:math' as math;

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

  // The ink for text and icons painted directly on a saturated accent fill.
  // Deliberately deeper than [textPrimary] (#16243B): a badge label sitting on
  // a bright accent needs more contrast headroom than body text does on cream.
  // Reach for it through [barrioOnAccent] so the light/dark branch is never
  // dropped — hardcoding this side is a latent bug on a dark accent.
  static const Color onAccentDark = Color(0xFF10151F);

  // Semantic status tokens (2026-07-31 premium pass) — one source of truth for
  // the green/amber/red that were previously hardcoded across ~10 files.
  static const Color success = Color(0xFF2ECC71); // emerald — correct / positive
  static const Color warning = Color(0xFFF39C12); // amber — caution / quiz accent
  static const Color error   = Color(0xFFE74C3C); // red — wrong / negative

  // Premium frosted-white card fill — previously written three ways
  // (#F2FFFFFF, #E6FFFFFF, shellMid@0.92). One token now.
  static const Color glassFill = Color(0xF2FFFFFF); // ~95% white glass on cream

  // The one deliberately lighter glass: input fields that should let a
  // little of the cream page read through so they sit *in* the page
  // rather than on top of it. Previously written as shellMid@0.80.
  // Only two rungs exist: [glassFill] for surfaces, this for fields.
  static const Color glassFillSoft = Color(0xCCFFFFFF); // 80% white glass

  // The resting hairline border on white/cream surfaces: chips, option
  // rows, rail buttons, close-chips. ~13% navy — visible as an edge, never
  // as a line. Was copy-pasted at 11 sites across 8 files.
  static const Color hairline = Color(0x2216243B);

  // The complementary navy bloom every destination background carries in
  // its opposite corner. Owned by [BarrioPremiumBackground]; screens get it
  // by using that widget, not by re-declaring the gradient stop.
  static const Color navyBloom = Color(0x1A1A2456);

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

/// Shared motion scale for a calm, deliberate feel (2026-08-06, audit B10).
///
/// Before this the module ran fifteen different durations (150, 180, 220,
/// 250, 280, 300, 320, 350, 400, 500, 700, 800, 900 ms and up) against nine
/// curves. Four rungs and two curves now cover everything:
///
///  * [fast] acknowledges a touch: press scale, chip highlight, a cue fading.
///  * [base] moves content: option reveal, container morph, a page turn.
///  * [slow] is a deliberate reveal the reader is meant to watch land.
///  * [hero] is a one-shot screen entrance, never a response to a tap.
///
/// [curve] is the house curve. Overshoot curves (`easeOutBack`, `elasticOut`)
/// are deliberately absent: a bounce reads playful, and this is a training
/// tool for staff on shift. [curveEmphasis] is the one alternative, for a
/// wordmark or crown that should land with a little more authority.
///
/// Timers that are not animation (input debounce, an auto-advance dwell) and
/// the celebration overlay's own lifetime are NOT on this scale; they are
/// wall-clock choices, documented where they live.
class BarrioMotion {
  BarrioMotion._();

  /// Touch acknowledgement.
  static const Duration fast = Duration(milliseconds: 150);

  /// Content movement: the default for anything that is not a press or a
  /// screen entrance.
  static const Duration base = Duration(milliseconds: 250);

  /// A deliberate reveal.
  static const Duration slow = Duration(milliseconds: 400);

  /// One-shot screen entrance.
  static const Duration hero = Duration(milliseconds: 700);

  /// The house curve: decelerate into place, never past it.
  static const Curve curve = Curves.easeOutCubic;

  /// Slightly sharper deceleration for a hero moment.
  static const Curve curveEmphasis = Curves.easeOutQuart;

  /// The one press-scale. 0.97 with [curve] instead of the old 0.95 with
  /// `easeOutBack`: on a 350dp card the overshoot read as a cheap pop.
  static const double pressScale = 0.97;

  /// Wall-clock budget for a whole staggered entrance: first item starting
  /// to last item settled. Capped so an eight-option card is never sluggish
  /// (the old `100 * index` delay started the last option 800ms in).
  static const Duration stagger = Duration(milliseconds: 300);

  /// Longest gap between two neighbouring items in a cascade. A short list
  /// gets the full step; a long one compresses so [stagger] still holds.
  static const Duration staggerStep = Duration(milliseconds: 45);

  /// Share of [stagger] one item's own fade + slide occupies (the rest is
  /// the room the cascade offsets live in).
  static const double _staggerWindow = 0.6;
}

/// The slice of a parent controller's 0..1 timeline that item [slot] of
/// [count] animates over in a staggered entrance (audit B11).
///
/// [parent] is the owning controller's duration, so the result honours
/// [BarrioMotion.staggerStep] and [BarrioMotion.stagger] in real
/// milliseconds no matter how long that controller runs. [delay] pushes the
/// whole cascade later inside the same timeline, which is how one controller
/// can run a hero reveal and then a list cascade behind it.
///
/// Ticker-driven staggering replaced one `Future.delayed` per item. Those
/// timers were not owned by any ticker, so they kept firing while the app was
/// backgrounded, drifted under load, and ignored reduce-motion.
Interval barrioStaggerInterval({
  required int slot,
  required int count,
  Duration parent = BarrioMotion.stagger,
  Duration delay = Duration.zero,
}) {
  final totalMs = parent.inMilliseconds.toDouble();
  if (totalMs <= 0) return const Interval(0, 1, curve: BarrioMotion.curve);

  final windowMs =
      BarrioMotion.stagger.inMilliseconds * BarrioMotion._staggerWindow;
  final spreadMs = BarrioMotion.stagger.inMilliseconds - windowMs;
  final stepMs = count > 1
      ? math.min(
          BarrioMotion.staggerStep.inMilliseconds.toDouble(),
          spreadMs / (count - 1),
        )
      : 0.0;

  final startMs =
      delay.inMilliseconds + (slot * stepMs).clamp(0.0, spreadMs);
  var begin = (startMs / totalMs).clamp(0.0, 1.0);
  final end = ((startMs + windowMs) / totalMs).clamp(0.0, 1.0);
  // A cascade that would run past the parent controller collapses to a
  // still-valid interval rather than asserting on begin > end.
  if (begin >= end) begin = math.max(0.0, end - 0.001);
  if (begin >= end) return const Interval(0, 1, curve: BarrioMotion.curve);
  return Interval(begin, end, curve: BarrioMotion.curve);
}

/// One item of a ticker-driven staggered entrance: a fade plus a short slide
/// over the slice of [parent] given by [interval].
///
/// Owning the [CurvedAnimation] (rather than rebuilding one per build, and
/// rather than one [AnimationController] per item) means the whole cascade
/// costs a single ticker and nothing leaks a listener onto the parent.
///
/// Reduce-motion is the caller's job and is one line: hold the parent
/// controller at 1.0 and every item is present and settled on the first
/// frame, with no timers pending.
class BarrioStaggerReveal extends StatefulWidget {
  /// The controller the whole cascade runs on.
  final Animation<double> parent;

  /// This item's slice of [parent], from [barrioStaggerInterval].
  final Interval interval;

  /// Where the item slides from, as a fraction of its own height.
  final Offset slideFrom;

  final Widget child;

  const BarrioStaggerReveal({
    super.key,
    required this.parent,
    required this.interval,
    this.slideFrom = const Offset(0, 0.12),
    required this.child,
  });

  @override
  State<BarrioStaggerReveal> createState() => _BarrioStaggerRevealState();
}

class _BarrioStaggerRevealState extends State<BarrioStaggerReveal> {
  late CurvedAnimation _curved;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _curved = CurvedAnimation(parent: widget.parent, curve: widget.interval);
    _slide = Tween<Offset>(begin: widget.slideFrom, end: Offset.zero)
        .animate(_curved);
  }

  /// [Interval] does not implement `==`, so a fresh instance from an
  /// otherwise identical rebuild would otherwise re-attach every time.
  static bool _sameInterval(Interval a, Interval b) =>
      a.begin == b.begin && a.end == b.end && a.curve == b.curve;

  @override
  void didUpdateWidget(covariant BarrioStaggerReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parent == widget.parent &&
        oldWidget.slideFrom == widget.slideFrom &&
        _sameInterval(oldWidget.interval, widget.interval)) {
      return;
    }
    _curved.dispose();
    _attach();
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
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

/// The legible ink for text or icons painted directly on top of [accent].
///
/// White on dark accents, [BarrioColors.onAccentDark] on bright ones. The
/// branch was copy-pasted at seven call sites and dropped entirely at an
/// eighth (the QUICK CHECK badge), which reads as near-black on near-black
/// the moment its accent darkens. One helper now.
Color barrioOnAccent(Color accent) {
  return ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
      ? Colors.white
      : BarrioColors.onAccentDark;
}

/// Decode width, in device pixels, for an [Image.asset] that renders at
/// [logicalWidth] logical pixels wide (premium performance audit A1).
///
/// The training corpus is authored at 1400x900, so a full-resolution decode
/// costs about 5 MB of raster cache per picture and a long deck thrashes
/// Flutter's 100 MB image cache. Passing this as `cacheWidth` decodes at the
/// size actually painted instead. Returns null when the width is not usable
/// yet (zero or unbounded), which leaves the decode at source resolution
/// exactly as before, and clamps to 4096 so a freak constraint can never ask
/// for an absurd bitmap.
int? barrioCacheWidth(BuildContext context, double logicalWidth) {
  if (!logicalWidth.isFinite || logicalWidth <= 0) return null;
  final pixels = logicalWidth * MediaQuery.devicePixelRatioOf(context);
  if (!pixels.isFinite || pixels < 1) return null;
  return pixels.round().clamp(1, 4096);
}

// ---------------------------------------------------------------------------
// Premium ambient background — used by all Barrio destination screens
// ---------------------------------------------------------------------------

/// Wraps a screen body in a warm cream background with a soft, low-alpha
/// accent bloom. Use this on every Barrio destination screen so the
/// premium light feel is consistent.
///
/// The bloom is atmospheric only — no interaction.
///
/// The photo-backed destination screens compose this as one layer of a
/// larger stack (photo, veil, blooms, vignette, content). They pass
/// [child] as null and rely on the caller for sizing, so this widget MUST
/// be given bounded constraints in that mode — put it in a
/// [Positioned.fill].
class BarrioPremiumBackground extends StatelessWidget {
  /// The screen body painted above the blooms. Null when this widget is
  /// used purely as a bloom layer inside a caller's own [Stack].
  final Widget? child;

  /// The accent color for the top-corner bloom. Use one of the
  /// [BarrioColors.accent*] constants per destination.
  final Color accentColor;

  /// Where to position the primary bloom. Defaults to top-right.
  final AlignmentGeometry bloomAlignment;

  /// Peak alpha of the accent bloom. The default is the calm wash used by
  /// the plain destination scaffold; the photo-backed screens run a little
  /// stronger (0.16) so the accent still reads through the cream veil.
  final double accentOpacity;

  const BarrioPremiumBackground({
    super.key,
    this.child,
    this.accentColor = BarrioColors.tealWarm,
    this.bloomAlignment = const Alignment(0.75, -0.9),
    this.accentOpacity = 0.10,
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
                    accentColor.withValues(alpha: accentOpacity),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        // Complementary navy bloom — opposite corner, subtle depth.
        // The one definition: five destination screens used to copy this
        // gradient verbatim.
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.85, 0.95),
                  radius: 0.75,
                  colors: [
                    BarrioColors.navyBloom,
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        if (child != null) child!,
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
                        // The house neutral lift. This file's own doc
                        // comment forbids colored glow; the icon circle
                        // used to ship one anyway.
                        boxShadow: barrioSoftShadow(y: 4, blur: 14, opacity: 0.10),
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
        borderRadius: BorderRadius.circular(BarrioRadii.chip),
        border: Border.all(color: BarrioColors.hairline),
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
