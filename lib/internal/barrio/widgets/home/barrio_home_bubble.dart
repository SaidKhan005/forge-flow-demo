// Barrio home bubbles: premium, restrained, brand-aligned (2026-07-27,
// operator request: "I like the aesthetics, I just don't like the neon
// lighting on all the bubbles: it makes it feel cheap and AI. I want
// them to feel premium and elegant").
//
// This replaces the parked orbit hub's glowing recipe (a dual
// blue/orange glow halo breathing on a 6s pulse, two rotating dual-color
// arcs, and an orange-bordered blue-to-orange glass wash: the Forge &
// Flow logo palette, which clashed with the Barrio brand on the light
// theme) with a calm treatment tuned to the Barrio Legado app-icon
// palette (warm cream page, deep navy text, teal accents):
//
//   * [BarrioHomeCenterBubble] is a frosted near-white glass disc lifted
//     by ONE soft, neutral navy drop shadow, ringed by a single thin
//     teal hairline, carrying the crisp logo + 'Dashboard' Playfair
//     label. No colored glow, no pulse, no rotating arcs.
//   * [BarrioHomeOrbitBubble] is the same frosted disc, with each
//     destination's accent expressed ONLY as a muted hairline ring plus
//     a whisper-soft tint (never a saturated neon fill). It keeps the
//     coming-soon treatment (0.30 opacity + gold 'Coming Soon' tag with
//     the FittedBox scale-down fix) and the B18 dimmed treatment
//     (exactly 0.38 opacity, non-interactive).
//
// There is no looping or ambient motion left on these bubbles: the
// premium look is quiet and static. Press feedback stays a gentle scale
// (no neon flare). The home screen's [TickerMode] gate remains upstream
// but now wraps a still subtree, which is harmless.
//
// GPU diet (2026-08-05, premium+performance Wave 2). Both discs used to
// sit inside a [BackdropFilter] gaussian blur. Two reasons that was pure
// cost with no picture:
//   1. The fill painted straight over it is [BarrioColors.glassFill] at
//      ~95% opacity, so at most ~5% of the blurred backdrop survived.
//   2. What it was blurring is `_BarrioHomeBackdrop`: a 3-stop vertical
//      cream-to-mint gradient plus one 8%-alpha teal radial. Blurring a
//      smooth gradient returns the same smooth gradient, so even that
//      ~5% was visually identical to no blur at all.
// With 25 `showOnHomeHub` destinations plus the centre bubble, that was
// ~26 saveLayer + gaussian passes every frame for a no-op. The glass
// read is carried entirely by the near-opaque fill, the hairline ring
// and the top specular gradient, all of which are unchanged.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destinations.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

// ---------------------------------------------------------------------------
// Center / primary bubble: frosted glass Dashboard
// ---------------------------------------------------------------------------

/// The Forge & Flow center bubble.
///
/// B18 dimming semantics match the hub: when [dimmed] is true the whole
/// bubble renders at exactly 0.38 opacity and is fully non-interactive.
class BarrioHomeCenterBubble extends StatefulWidget {
  final BarrioDestination destination;
  final double diameter;
  final bool dimmed;
  final VoidCallback onTap;

  const BarrioHomeCenterBubble({
    super.key,
    required this.destination,
    required this.diameter,
    required this.dimmed,
    required this.onTap,
  });

  @override
  State<BarrioHomeCenterBubble> createState() => _BarrioHomeCenterBubbleState();
}

class _BarrioHomeCenterBubbleState extends State<BarrioHomeCenterBubble> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final diameter = widget.diameter;
    Widget bubble = _bubbleBody(diameter);
    if (widget.dimmed) {
      bubble = Opacity(opacity: 0.38, child: bubble);
    }
    // Press: gentle scale to 0.92 with spring-back (no neon flare).
    bubble = AnimatedScale(
      scale: _pressed ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: bubble,
    );
    Widget target = RepaintBoundary(
      child: SizedBox(width: diameter, height: diameter, child: bubble),
    );
    if (!widget.dimmed) {
      target = GestureDetector(
        onTapDown: (_) {
          HapticFeedback.lightImpact();
          setState(() => _pressed = true);
        },
        onTapUp: (_) {
          // Primary bubble gets a more satisfying medium impact.
          HapticFeedback.mediumImpact();
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: target,
      );
    }
    // Accessibility (rec #12): one merged node per bubble, button
    // role while interactive ('Dashboard' merges in as the label).
    return MergeSemantics(
      child: Semantics(
        button: !widget.dimmed,
        enabled: !widget.dimmed,
        child: target,
      ),
    );
  }

  Widget _bubbleBody(double diameter) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // 1: the neutral drop shadow, outside the ClipRRect so it lifts
        //    the disc freely against the cream page.
        _lift(diameter),
        // 2: the frosted glass disc + thin teal hairline ring.
        _glassDisc(diameter),
      ],
    );
  }

  /// The premium lift: a single soft, neutral navy shadow from the
  /// shared [barrioSoftShadow] token. Drawn on an otherwise-transparent
  /// circle so only the shadow shows around the disc.
  Widget _lift(double diameter) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: barrioSoftShadow(y: 8, blur: 24, opacity: 0.10),
      ),
    );
  }

  Widget _glassDisc(double diameter) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(diameter / 2),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BarrioColors.glassFill,
          border: Border.fromBorderSide(
            BorderSide(
              // A single thin teal hairline: the Barrio brand accent,
              // restrained (was a 67%-alpha orange F&F-logo border).
              color: BarrioColors.tealDeep.withValues(alpha: 0.35),
              width: 1.0,
            ),
          ),
        ),
        child: Stack(
          children: [
            // Top specular: glass catching overhead light. Neutral
            // white at low alpha, a premium sheen, not a colored glow.
            // With the backdrop blur gone this gradient plus the
            // hairline ring is what sells the glass.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.6),
                  radius: 0.9,
                  colors: [
                    Colors.white.withValues(alpha: 0.45),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            // Accessibility clamp (rec #12, documented): the glass
            // disc is a fixed-diameter circle, so its label scales
            // up to 1.35x and no further. The full label is always
            // in the bubble's merged semantics and on the opened
            // screen's app bar, so no content is lost at any scale.
            Center(
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.35,
                child: _discContent(diameter),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _discContent(double diameter) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        barrioHomeIconWidgetFor(
          context,
          widget.destination.id,
          diameter * 0.30,
          barrioHomeAccentFor(widget.destination.id),
          false,
        ),
        SizedBox(height: diameter * 0.05),
        Text(
          'Dashboard',
          textAlign: TextAlign.center,
          style: GoogleFonts.playfairDisplay(
            fontSize: max(diameter * 0.12, 11),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: BarrioColors.textPrimary,
            height: 1.2,
            shadows: const [
              Shadow(color: Color(0x14000000), blurRadius: 8),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Orbit / secondary bubble: frosted glass with a muted per-dest accent
// ---------------------------------------------------------------------------

/// A secondary destination bubble.
///
/// Coming-soon destinations render at 0.30 opacity with the gold
/// 'Coming Soon' tag and KEEP their tap-through; B18 [dimmed]
/// destinations render at exactly 0.38 opacity and are fully
/// non-interactive.
class BarrioHomeOrbitBubble extends StatefulWidget {
  final BarrioDestination destination;
  final double diameter;
  final bool dimmed;
  final VoidCallback onTap;

  const BarrioHomeOrbitBubble({
    super.key,
    required this.destination,
    required this.diameter,
    required this.dimmed,
    required this.onTap,
  });

  @override
  State<BarrioHomeOrbitBubble> createState() => _BarrioHomeOrbitBubbleState();
}

class _BarrioHomeOrbitBubbleState extends State<BarrioHomeOrbitBubble> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final diameter = widget.diameter;
    Widget bubble = _bubbleBody(context);
    if (widget.destination.comingSoon) {
      bubble = Opacity(opacity: 0.30, child: bubble);
    } else if (widget.dimmed) {
      bubble = Opacity(opacity: 0.38, child: bubble);
    }
    // Press: gentle scale to 0.92 with spring-back (no neon flare).
    bubble = AnimatedScale(
      scale: _pressed ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: bubble,
    );
    Widget target = RepaintBoundary(
      child: SizedBox(width: diameter, height: diameter, child: bubble),
    );
    // Dimmed bubbles (role not assigned) are fully non-interactive;
    // coming-soon bubbles still navigate to their placeholder screen.
    if (!widget.dimmed) {
      target = GestureDetector(
        onTapDown: (_) {
          HapticFeedback.lightImpact();
          setState(() => _pressed = true);
        },
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: target,
      );
    }
    // Accessibility (rec #12): one merged node per bubble; the label
    // (and 'Coming Soon' tag when present) merges from the disc texts.
    return MergeSemantics(
      child: Semantics(
        button: !widget.dimmed,
        enabled: !widget.dimmed,
        child: target,
      ),
    );
  }

  Widget _bubbleBody(BuildContext context) {
    final accent = barrioHomeAccentFor(widget.destination.id);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        _lift(),
        _glassDisc(context, accent),
      ],
    );
  }

  /// The premium lift: a single soft, neutral navy shadow, sized a touch
  /// tighter for the smaller orbit discs. Dimmed bubbles get no shadow:
  /// they recede rather than lift.
  Widget _lift() {
    return Container(
      width: widget.diameter,
      height: widget.diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.dimmed
            ? null
            : barrioSoftShadow(y: 6, blur: 18, opacity: 0.10),
      ),
    );
  }

  Widget _glassDisc(BuildContext context, Color accent) {
    final diameter = widget.diameter;
    final isDimmed = widget.dimmed;
    return ClipRRect(
      borderRadius: BorderRadius.circular(diameter / 2),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Frosted glass base (light theme): near-white for active
          // bubbles, a faint navy grey for dimmed ones.
          color: isDimmed ? const Color(0x0F16243B) : BarrioColors.glassFill,
          border: Border.all(
            // A single muted accent hairline (was a 55%-alpha accent
            // ring): the destination's identity, restrained.
            color: isDimmed
                ? const Color(0x1416243B)
                : accent.withValues(alpha: 0.38),
            width: 1.0,
          ),
        ),
        child: Stack(
          children: [
            // Whisper-soft accent tint, weighted to the bottom: a hint
            // of the destination's identity, never a saturated fill
            // (was a 42%-alpha neon accent wash).
            if (!isDimmed)
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(0.15, 0.65),
                    radius: 1.0,
                    colors: [
                      accent.withValues(alpha: 0.14),
                      accent.withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            // Top specular: overhead light on the glass surface.
            // Neutral white sheen, not a colored glow. With the backdrop
            // blur gone this gradient plus the hairline ring is what
            // sells the glass.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.6),
                  radius: 0.85,
                  colors: [
                    Colors.white.withValues(alpha: isDimmed ? 0.06 : 0.4),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            // Content: handbook uses a Stack so its leaf art sits
            // behind the label (hub-identical special case).
            // Accessibility clamp (rec #12, documented): the glass
            // disc is a fixed-diameter circle, so the in-circle
            // label scales up to 1.35x and no further (it already
            // wraps to 2 lines). The full label is always in the
            // bubble's merged semantics and on the opened screen's
            // app bar, so no content is lost at any scale.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.35,
              child: widget.destination.id == 'company_handbook'
                  ? _handbookContent(context, accent)
                  : _centeredContent(context, accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _handbookContent(BuildContext context, Color accent) {
    return Stack(
      children: [
        // Leaf image: decorative, behind text, fills the bubble.
        Positioned.fill(
          child: Align(
            alignment: const Alignment(0.0, -0.3),
            child: barrioHomeIconWidgetFor(
              context,
              widget.destination.id,
              widget.diameter * 0.30,
              accent,
              widget.dimmed,
            ),
          ),
        ),
        // Label: below the leaf, centered horizontally.
        Align(
          alignment: const Alignment(0.0, 0.45),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _label(),
          ),
        ),
      ],
    );
  }

  Widget _centeredContent(BuildContext context, Color accent) {
    final diameter = widget.diameter;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            barrioHomeIconWidgetFor(
              context,
              widget.destination.id,
              diameter * 0.30,
              accent,
              widget.dimmed,
            ),
            SizedBox(height: diameter * 0.05),
            _label(),
            if (widget.destination.comingSoon) ...[
              SizedBox(height: diameter * 0.03),
              // Hub fix kept: scale down instead of wrapping so the tag
              // stays a single line at any bubble diameter.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Coming Soon',
                  maxLines: 1,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: max(diameter * 0.080, 11),
                    color: BarrioColors.gold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label() {
    final isDimmed = widget.dimmed;
    return Text(
      widget.destination.label,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.ibmPlexSans(
        fontSize: max(widget.diameter * 0.100, 11),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: isDimmed
            ? BarrioColors.textMuted.withValues(alpha: 0.35)
            : BarrioColors.textPrimary,
        height: 1.2,
        shadows: isDimmed
            ? null
            : const [Shadow(color: Color(0x14000000), blurRadius: 6)],
      ),
    );
  }
}
