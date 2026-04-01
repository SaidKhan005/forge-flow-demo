import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_destination_scaffold.dart';

/// Reusable celebration system for Barrio learning screens.
///
/// Three tiers of celebration, each triggered at a different granularity:
/// - **Correct answer:** Subtle sparkle burst on the card (inline)
/// - **Module/section complete:** Slide-up banner overlay
/// - **Full mastery:** Premium radial bloom overlay (future)
class BarrioCelebrationOverlay {
  BarrioCelebrationOverlay._();

  /// Shows a module/section/chapter completion banner.
  /// Slides up from bottom, holds for 2.5s, then slides away.
  static void showModuleComplete(
    BuildContext context, {
    required String title,
    required Color accentColor,
  }) {
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _ModuleCompleteBanner(
        title: title,
        accentColor: accentColor,
        onDismiss: () => entry.remove(),
      ),
    );

    overlay.insert(entry);
  }
}

class _ModuleCompleteBanner extends StatefulWidget {
  final String title;
  final Color accentColor;
  final VoidCallback onDismiss;

  const _ModuleCompleteBanner({
    required this.title,
    required this.accentColor,
    required this.onDismiss,
  });

  @override
  State<_ModuleCompleteBanner> createState() => _ModuleCompleteBannerState();
}

class _ModuleCompleteBannerState extends State<_ModuleCompleteBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3500),
  )..forward();

  late final Animation<double> _slideIn = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0.0, 0.15, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _slideOut = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0.85, 1.0, curve: Curves.easeInCubic),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0.0, 0.10, curve: Curves.easeOut),
  );
  late final Animation<double> _fadeOut = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
  );

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final slideProgress = _slideIn.value - (1.0 - _slideOut.value);
        final opacity = _fade.value * _fadeOut.value;

        return Positioned(
          left: 20,
          right: 20,
          bottom: 40 + (slideProgress * 60).clamp(0.0, 60.0),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        decoration: BoxDecoration(
          color: BarrioColors.shellMid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: widget.accentColor.withValues(alpha: 0.45),
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.25),
              blurRadius: 30,
              spreadRadius: -4,
            ),
            const BoxShadow(
              color: Color(0x66000000),
              blurRadius: 20,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accentColor.withValues(alpha: 0.15),
                border: Border.all(
                  color: widget.accentColor.withValues(alpha: 0.40),
                ),
              ),
              child: Icon(
                Icons.check_rounded,
                size: 20,
                color: widget.accentColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'COMPLETE',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: widget.accentColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.title,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: BarrioColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline sparkle burst widget for correct answer celebrations.
///
/// Renders a brief burst of accent-colored particles that fade and spread
/// outward from the center. Duration: ~600ms.
class CorrectAnswerSparkle extends StatefulWidget {
  final Color accentColor;
  final VoidCallback? onComplete;

  const CorrectAnswerSparkle({
    super.key,
    required this.accentColor,
    this.onComplete,
  });

  @override
  State<CorrectAnswerSparkle> createState() => _CorrectAnswerSparkleState();
}

class _CorrectAnswerSparkleState extends State<CorrectAnswerSparkle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..forward();

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onComplete?.call();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return CustomPaint(
          size: const Size(60, 60),
          painter: _SparklePainter(
            progress: _ctrl.value,
            color: widget.accentColor,
          ),
        );
      },
    );
  }
}

class _SparklePainter extends CustomPainter {
  final double progress;
  final Color color;

  // Gold and near-white for color variety
  static const _gold = Color(0xFFDFAA40);
  static const _white = Color(0xFFF0F6F8);

  static final _rng = Random(42);
  static final _particles = List.generate(14, (i) {
    final angle = (i / 14) * 2 * pi + _rng.nextDouble() * 0.4;
    final speed = 0.5 + _rng.nextDouble() * 0.5;
    final sizeMult = 0.7 + _rng.nextDouble() * 0.6;
    // 0 = circle, 1 = diamond, 2 = 4-point star
    final shape = i % 3;
    // 0 = accent, 1 = gold, 2 = white
    final colorVariant = i % 3;
    return (
      angle: angle,
      speed: speed,
      sizeMult: sizeMult,
      shape: shape,
      colorVariant: colorVariant,
    );
  });

  _SparklePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (final p in _particles) {
      // Stagger launch: faster particles start slightly earlier
      final staggeredProgress =
          ((progress - (1.0 - p.speed) * 0.15) / (1.0 - (1.0 - p.speed) * 0.15))
              .clamp(0.0, 1.0);
      if (staggeredProgress <= 0) continue;

      final opacity = (1.0 - staggeredProgress).clamp(0.0, 1.0);
      final particleColor = switch (p.colorVariant) {
        1 => _gold,
        2 => _white,
        _ => color,
      };

      final paint = Paint()
        ..color = particleColor.withValues(alpha: opacity * 0.85)
        ..style = PaintingStyle.fill;

      final dist = maxRadius * staggeredProgress * p.speed;
      final dx = center.dx + cos(p.angle) * dist;
      final dy = center.dy + sin(p.angle) * dist;
      final dotSize = 2.5 * p.sizeMult * (1.0 - staggeredProgress * 0.5);

      switch (p.shape) {
        case 1: // Diamond
          canvas.save();
          canvas.translate(dx, dy);
          canvas.rotate(pi / 4);
          canvas.drawRect(
            Rect.fromCenter(center: Offset.zero, width: dotSize * 1.6, height: dotSize * 1.6),
            paint,
          );
          canvas.restore();
        case 2: // 4-point star
          final outer = dotSize * 1.4;
          final inner = dotSize * 0.5;
          final path = Path();
          for (var j = 0; j < 8; j++) {
            final r = j.isEven ? outer : inner;
            final a = (j / 8) * 2 * pi - pi / 2;
            final pt = Offset(dx + cos(a) * r, dy + sin(a) * r);
            if (j == 0) {
              path.moveTo(pt.dx, pt.dy);
            } else {
              path.lineTo(pt.dx, pt.dy);
            }
          }
          path.close();
          canvas.drawPath(path, paint);
        default: // Circle
          canvas.drawCircle(Offset(dx, dy), dotSize, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.progress != progress;
}
