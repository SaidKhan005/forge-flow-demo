// Barrio home revision (2026-07-11, operator decision): one-scroll
// round-bubble layout with restored premium effects.
//
// The operator kept the Editorial Shelf's single-vertical-scroll
// organization but replaced the rectangular hero + topic cards with the
// ORIGINAL round glass bubbles from the parked orbit hub
// (`../barrio_bubble_hub.dart`, which stays byte-identical on disk).
// The recipes here mirror that hub verbatim:
//
//   * [BarrioHomeCenterBubble] mirrors `_buildCenterNode`: dual
//     blue/orange glow halo breathing on a 6s reverse-repeat pulse, the
//     rotating [_CenterArcPainter] arcs (elapsed-time repaint), the
//     frosted glass disc (blur 14, orange border, blue-to-orange wash,
//     top specular), and the logo icon + 'Dashboard' Playfair label.
//   * [BarrioHomeOrbitBubble] mirrors `_buildOrbitNode`: accent glow
//     halo, glass circle, radial accent gradient, icon + label INSIDE
//     the circle, the coming-soon treatment (0.30 opacity + gold
//     'Coming Soon' tag with the FittedBox scale-down fix), and the B18
//     dimmed treatment (exactly 0.38 opacity, non-interactive).
//
// This operator decision explicitly overrides the redesign plan's "no
// looping/ambient animation" rule. `MediaQuery.disableAnimations`
// freezes the looping glow pulse and arc rotation at their resting
// frame.

import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destinations.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

/// Forge & Flow logo brand colors (mirror the hub's `_logoBlue` /
/// `_logoOrange`).
const Color _logoBlue = kBarrioHomeForgeAccent;
const Color _logoOrange = Color(0xFFFF6B35);

// ---------------------------------------------------------------------------
// Center / primary bubble: frosted glass Dashboard
// ---------------------------------------------------------------------------

/// The Forge & Flow center bubble, lifted from the hub's primary node.
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

class _BarrioHomeCenterBubbleState extends State<BarrioHomeCenterBubble>
    with TickerProviderStateMixin {
  // Stopwatch for arc rotation math: monotonically increasing, no wraps
  // (hub-identical approach).
  final _stopwatch = Stopwatch();

  // Glow pulse: 6s reverse-repeat means velocity 0 at both ends.
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6000),
  );
  late final Animation<double> _pulse = Tween<double>(begin: 0.0, end: 3.0)
      .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

  // Frame-rate ticker so the elapsed-time arc rotation repaints.
  late final AnimationController _arcTicker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  bool _pressed = false;
  bool _motionDecided = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionDecided) return;
    _motionDecided = true;
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (!_reduceMotion) {
      // Accessibility: with disableAnimations the loops never start, so
      // the glow and arcs hold their resting frame.
      _stopwatch.start();
      _pulseCtrl.repeat(reverse: true);
      _arcTicker.repeat();
    }
  }

  @override
  void dispose() {
    _stopwatch.stop();
    _pulseCtrl.dispose();
    _arcTicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diameter = widget.diameter;
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseCtrl, _arcTicker]),
      builder: (context, _) {
        Widget bubble = _bubbleBody(diameter);
        if (widget.dimmed) {
          bubble = Opacity(opacity: 0.38, child: bubble);
        }
        // Press: scale to 0.92 with spring-back (hub-identical).
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
      },
    );
  }

  Widget _bubbleBody(double diameter) {
    final time =
        _reduceMotion ? 0.0 : _stopwatch.elapsedMilliseconds.toDouble();
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // 1: glow halo, outside the ClipRRect so it spreads freely.
        _glowHalo(diameter),
        // 2: rotating arcs, outside the ClipRRect so they aren't blurred
        //    away. One arc orange, one arc blue: the logo palette.
        SizedBox(
          width: diameter + 8,
          height: diameter + 8,
          child: CustomPaint(
            painter: _CenterArcPainter(
              radius: diameter / 2 + 4,
              time: time,
              color1: _logoOrange,
              color2: _logoBlue,
              isPressed: _pressed,
            ),
          ),
        ),
        // 3: glass disc.
        _glassDisc(diameter),
      ],
    );
  }

  /// Dual-color halo: blue shadow left, orange shadow right, breathing
  /// with the center pulse and flaring on press (hub-identical values).
  Widget _glowHalo(double diameter) {
    final glowBlur = (28.0 + _pulse.value * 4) * (_pressed ? 1.5 : 1.0);
    final glowSpread = _pulse.value * 2;
    final glowAlpha = _pressed ? 0.80 : 0.55;
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _logoBlue.withValues(alpha: glowAlpha),
            blurRadius: glowBlur,
            spreadRadius: glowSpread,
            offset: const Offset(-4, 0),
          ),
          BoxShadow(
            color: _logoOrange.withValues(alpha: glowAlpha * 0.85),
            blurRadius: glowBlur,
            spreadRadius: glowSpread,
            offset: const Offset(4, 0),
          ),
          BoxShadow(
            color: _logoBlue.withValues(alpha: 0.18),
            blurRadius: glowBlur * 2,
            spreadRadius: glowSpread + 8,
          ),
        ],
      ),
    );
  }

  Widget _glassDisc(double diameter) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(diameter / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            border: Border.fromBorderSide(
              BorderSide(
                // Orange at 67%: visible against the blue fill.
                color: Color(0xAAFF6B35),
                width: 1.0,
              ),
            ),
          ),
          child: Stack(
            children: [
              // Dark glass base.
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x38000000),
                ),
              ),
              // Blue to orange diagonal fill: light wash, not opaque.
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: const Alignment(-0.8, -0.8),
                    end: const Alignment(0.8, 0.8),
                    colors: [
                      _logoBlue.withValues(alpha: 0.28),
                      _logoOrange.withValues(alpha: 0.22),
                    ],
                  ),
                ),
              ),
              // Top specular: glass catching overhead light.
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.65),
                    radius: 0.55,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
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
              Shadow(color: Color(0x60000000), blurRadius: 8),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Orbit / secondary bubble: 3D glassmorphism with per-dest accent color
// ---------------------------------------------------------------------------

/// A secondary destination bubble, lifted from the hub's orbit node.
///
/// Coming-soon destinations render at 0.30 opacity with the gold
/// 'Coming Soon' tag and KEEP their tap-through; B18 [dimmed]
/// destinations render at exactly 0.38 opacity and are fully
/// non-interactive (hub-identical semantics).
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
    // Press: scale to 0.92 with spring-back (hub-identical).
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
        _glowHalo(accent),
        _glassDisc(context, accent),
      ],
    );
  }

  /// Accent halo, outside the ClipRRect so it isn't clipped away; glow
  /// intensifies on press (hub-identical values).
  Widget _glowHalo(Color accent) {
    final innerGlowAlpha = _pressed ? 0.72 : 0.48;
    final glowBlurMult = _pressed ? 1.5 : 1.0;
    return Container(
      width: widget.diameter,
      height: widget.diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.dimmed
            ? null
            : [
                BoxShadow(
                  color: accent.withValues(alpha: innerGlowAlpha),
                  blurRadius: 22 * glowBlurMult,
                  spreadRadius: -2,
                ),
                BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 44 * glowBlurMult,
                  spreadRadius: 4,
                ),
              ],
      ),
    );
  }

  Widget _glassDisc(BuildContext context, Color accent) {
    final diameter = widget.diameter;
    final isDimmed = widget.dimmed;
    return ClipRRect(
      borderRadius: BorderRadius.circular(diameter / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isDimmed
                  ? const Color(0x14FFFFFF)
                  : accent.withValues(alpha: 0.55),
              width: 1.0,
            ),
          ),
          child: Stack(
            children: [
              // Dark glass base.
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDimmed
                      ? const Color(0x20000000)
                      : const Color(0x30000000),
                ),
              ),
              // Accent fill: weighted to bottom, low alpha = tint.
              if (!isDimmed)
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(0.15, 0.65),
                      radius: 1.0,
                      colors: [
                        accent.withValues(alpha: 0.42),
                        accent.withValues(alpha: 0.10),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              // Top specular: overhead light on the glass surface.
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.65),
                    radius: 0.52,
                    colors: [
                      Colors.white.withValues(alpha: isDimmed ? 0.05 : 0.16),
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
            : const [Shadow(color: Color(0x50000000), blurRadius: 6)],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

/// Two symmetric 120 degree arcs rotating slowly around the center
/// bubble. color1 (orange) and color2 (blue) alternate, mirroring the
/// F&F logo palette. Drawn outside the glass ClipRRect so they sit at
/// the correct depth (verbatim from the hub's `_CenterArcPainter`).
class _CenterArcPainter extends CustomPainter {
  final double radius; // bubble radius + 4px margin
  final double time;
  final Color color1; // first arc color  (orange)
  final Color color2; // second arc color (blue)
  final bool isPressed;

  _CenterArcPainter({
    required this.radius,
    required this.time,
    required this.color1,
    required this.color2,
    required this.isPressed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final rotation = (time / 20000.0) * 2 * pi; // one revolution / 20 s
    final rect = Rect.fromCircle(center: center, radius: radius);
    const sweep = pi * 2 / 3; // 120 degrees

    final crispAlpha = isPressed ? 0.90 : 0.65;

    // Arc 1: color1 (orange). Arc 2: color2 (blue). 180 degrees apart.
    for (var idx = 0; idx < 2; idx++) {
      final color = idx == 0 ? color1 : color2;
      final start = rotation + idx * pi - sweep / 2;

      // Glow pass
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.18),
      );

      // Crisp pass
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: crispAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_CenterArcPainter old) =>
      old.time != time || old.isPressed != isPressed;
}
