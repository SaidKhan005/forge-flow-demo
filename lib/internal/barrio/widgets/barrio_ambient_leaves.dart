import 'dart:math';
import 'package:flutter/material.dart';

/// Botanical falling-leaf ambient motion for the Barrio Legado home screen.
///
/// Per the Barrio Legado brand brief:
/// - 10–12 elongated botanical leaves in teal and navy tones
/// - Slow downward drift with gentle rotation
/// - Very low opacity — atmosphere, not decoration
/// - Background-only (pointer events pass through to content)
///
/// Uses per-leaf animation controllers so each leaf falls at its own pace.
/// A TweenSequence opacity envelope (fade-in 20% / hold 60% / fade-out 20%)
/// makes the top-and-bottom wrap invisible: when the controller resets from
/// 1.0→0.0 the leaf is already fully transparent.
///
/// If the animation distracts, it has failed. Keep it imperceptible.
class BarrioAmbientLeaves extends StatefulWidget {
  final Widget child;

  const BarrioAmbientLeaves({super.key, required this.child});

  @override
  State<BarrioAmbientLeaves> createState() => _BarrioAmbientLeavesState();
}

class _BarrioAmbientLeavesState extends State<BarrioAmbientLeaves>
    with TickerProviderStateMixin {
  static const int _leafCount = 12;

  late final List<_Leaf> _leaves;
  late final List<AnimationController> _leafControllers;
  late final List<Animation<double>> _posAnimations;
  late final List<Animation<double>> _opacityAnimations;
  late final Listenable _leafAnimationTick;

  // Stopwatch for horizontal sway — independent of which controllers have
  // started, so sway is never frozen during the staggered start window.
  final _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _stopwatch.start();

    final rng = Random(42); // deterministic seed for visual consistency
    _leaves = List.generate(_leafCount, (i) => _Leaf.random(rng, i));

    _leafControllers = List.generate(_leafCount, (i) {
      // Near leaves (0–5): 5000–7000 ms (faster); far leaves (6–11): 9100–12750 ms (slower).
      final isNear = i < 6;
      final ms = isNear ? 5000 + (i * 400) : 9100 + ((i - 6) * 730);
      // Stagger via initial phase — no Future.delayed, no pending timers in tests.
      final initialPhase = i / _leafCount;
      final ctrl = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: ms),
        value: initialPhase,
      );
      ctrl.repeat();
      return ctrl;
    });

    // Position: 0.0 (just above screen, -5%) → 1.0 (just below screen, +10%)
    _posAnimations = List.generate(
      _leafCount,
      (i) =>
          Tween<double>(begin: -0.05, end: 1.10).animate(_leafControllers[i]),
    );

    // Opacity envelope: fade in (top 20%) → hold (middle 60%) → fade out (bottom 20%)
    // When the controller wraps 1.0→0.0 the leaf is fully transparent, hiding the snap.
    // Near leaves hold at 0.9 (more visible); far leaves hold at 0.45 (recede).
    _opacityAnimations = List.generate(_leafCount, (i) {
      final isNear = i < 6;
      final holdOpacity = isNear ? 0.9 : 0.45;
      return TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: holdOpacity),
          weight: 20,
        ),
        TweenSequenceItem(tween: ConstantTween(holdOpacity), weight: 60),
        TweenSequenceItem(
          tween: Tween(begin: holdOpacity, end: 0.0),
          weight: 20,
        ),
      ]).animate(_leafControllers[i]);
    });
    _leafAnimationTick = Listenable.merge(_leafControllers);
  }

  @override
  void dispose() {
    _stopwatch.stop();
    for (final c in _leafControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(child: widget.child),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _leafAnimationTick,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _LeafPainter(
                      leaves: _leaves,
                      positions: _posAnimations,
                      opacities: _opacityAnimations,
                      time: _stopwatch.elapsedMilliseconds.toDouble(),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Leaf {
  final double x; // 0..1 base horizontal position
  final double size; // half-length of the leaf shape
  final double sway; // horizontal sway amplitude (fraction of screen width)
  final double swayFreq; // radians per millisecond — unique per leaf
  final double swayPhase; // starting phase offset
  final double initialRot; // starting rotation in radians
  final double rotSpeed; // rotation speed (signed, radians per second)
  final Color color; // leaf fill color (opacity baked in as base)

  const _Leaf({
    required this.x,
    required this.size,
    required this.sway,
    required this.swayFreq,
    required this.swayPhase,
    required this.initialRot,
    required this.rotSpeed,
    required this.color,
  });

  factory _Leaf.random(Random rng, int index) {
    // Three-way color cycle: gold / teal / navy — gold leaves add warmth.
    // Gold alpha is slightly higher (0.11) to compensate for the darker hue.
    final color = switch (index % 3) {
      0 => const Color(
        0xFFDFAA40,
      ).withValues(alpha: 0.13), // warm gold — richer
      1 => const Color(
        0xFF40CFCF,
      ).withValues(alpha: 0.11), // brand teal — brighter
      _ => const Color(0xFF1A2456).withValues(alpha: 0.08), // deep navy
    };

    final isNear = index < 6;
    final leafSize = isNear
        ? 12.0 +
              rng.nextDouble() *
                  10.0 // near: 12–22 px
        : 5.0 + rng.nextDouble() * 7.0; // far:  5–12 px
    return _Leaf(
      x: rng.nextDouble(),
      size: leafSize,
      sway: 0.008 + rng.nextDouble() * 0.015,
      // swayFreq: ~0.3–1.0 full cycles per 10 seconds → convert to rad/ms
      swayFreq: (0.3 + rng.nextDouble() * 0.7) * pi * 2 / 10000.0,
      swayPhase: rng.nextDouble() * pi * 2,
      initialRot: rng.nextDouble() * pi * 2,
      // Gentle rotation — sign alternates by index for natural variety
      rotSpeed:
          (index.isEven ? 1.0 : -1.0) *
          (0.08 + rng.nextDouble() * 0.22) *
          pi *
          2 /
          10000.0,
      color: color,
    );
  }
}

class _LeafPainter extends CustomPainter {
  final List<_Leaf> leaves;
  final List<Animation<double>>
  positions; // current y fraction per leaf, -0.05..1.10
  final List<Animation<double>>
  opacities; // current opacity multiplier per leaf, 0..1
  final double time; // elapsed ms for sway sin function

  _LeafPainter({
    required this.leaves,
    required this.positions,
    required this.opacities,
    required this.time,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < leaves.length; i++) {
      final leaf = leaves[i];
      final opacity = opacities[i].value;
      if (opacity <= 0.0) {
        // Skip invisible leaves and avoid draws during staggered startup.
        continue;
      }

      final cy = positions[i].value * size.height;
      final cx =
          (leaf.x + sin(time * leaf.swayFreq + leaf.swayPhase) * leaf.sway) *
          size.width;
      final rotation = leaf.initialRot + time * leaf.rotSpeed;

      // Multiply the leaf's baked-in base alpha by the opacity envelope
      final paint = Paint()
        ..color = leaf.color.withValues(alpha: leaf.color.a * opacity)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rotation);

      // Botanical elongated leaf — two cubic bezier curves
      final s = leaf.size;
      final path = Path()
        ..moveTo(0, -s)
        ..cubicTo(s * 0.6, -s * 0.5, s * 0.6, s * 0.5, 0, s)
        ..cubicTo(-s * 0.6, s * 0.5, -s * 0.6, -s * 0.5, 0, -s)
        ..close();

      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LeafPainter oldDelegate) => oldDelegate.time != time;
}
