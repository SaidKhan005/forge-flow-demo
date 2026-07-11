import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_destination_scaffold.dart';
import '../barrio_surface_flags.dart';
import '../routes/barrio_destination_visibility_resolver.dart';
import '../routes/barrio_destinations.dart';
import '../routes/barrio_preview_role.dart';

// Per-bubble orbital personality — radius spread, orbit speed, sway amplitude.
class _OrbitPersonality {
  final double radiusFactor;
  final double speedFactor;
  final double swayAmp;

  const _OrbitPersonality({
    required this.radiusFactor,
    required this.speedFactor,
    required this.swayAmp,
  });
}

// All speedFactors are exactly 1.0 so the 72° initial spacing is preserved
// indefinitely — no drift, no overlap, regardless of how long the app runs.
const _personalities = [
  _OrbitPersonality(radiusFactor: 1.04, speedFactor: 1.0, swayAmp: 0.06),
  _OrbitPersonality(radiusFactor: 0.97, speedFactor: 1.0, swayAmp: 0.05),
  _OrbitPersonality(radiusFactor: 1.06, speedFactor: 1.0, swayAmp: 0.06),
  _OrbitPersonality(radiusFactor: 0.96, speedFactor: 1.0, swayAmp: 0.05),
  _OrbitPersonality(radiusFactor: 1.03, speedFactor: 1.0, swayAmp: 0.06),
];

// Forge & Flow logo brand colors — used for the orbit ring and Dashboard bubble.
const _logoBlue = Color(0xFF2E6EE0); // slightly brighter royal blue
const _logoOrange = Color(0xFFFF6B35);

/// Per-destination accent colors — jewel tones, not neon.
/// Deep, saturated hues read as premium on a dark photo background.
const _destinationAccents = {
  'company_handbook': Color(0xFFD4584C), // warm brick red — matches building
  'interview_playbook': Color(0xFF1EA870), // forest green — more vivid
  'jim_taylor_labor_model': Color(
    0xFF3A6ED0,
  ), // royal blue — matches book cover
  'preston_lee_model': Color(0xFFCC8A3A), // warm amber — matches photo tones
  'supervisor_content': Color(0xFF6080A8),
  'forge_and_flow': Color(0xFF2E6EE0), // royal blue — brighter
  // Verbatim training bubbles (2026-07-11 training-drop slice) — mirror
  // kBarrioTrainingAccents in content/training/training_docs.dart.
  'training_strong_foundation': Color(0xFFCC8A3A), // warm amber
  'training_table_manicuring': Color(0xFF5FB8A6), // seafoam
  'training_three_pillars': Color(0xFFB06AC9), // plum
  'training_suggestive_selling': Color(0xFF2ECC71), // emerald
  'training_tequila': Color(0xFFDFAA40), // gold
  'training_coffee': Color(0xFF9A6B4F), // roasted brown
  'training_latin_dishes': Color(0xFFD4584C), // brick red
  'training_latin_ingredients': Color(0xFF7FA84C), // herb green
  'training_labour_cost': Color(0xFF3A6ED0), // royal blue
  'training_menu_concept': Color(0xFF40CFCF), // warm teal
  // Corpus-complete training bubbles (2026-07-11 slice)
  'training_bold_by_design': Color(0xFF5A7BD8), // steel blue
  'training_food_safety': Color(0xFF52B788), // fresh green
  'training_cheers_responsibility': Color(0xFFDFAA40), // gold
  'training_mastering_metrics': Color(0xFF3A6ED0), // royal blue
  'training_general_words': Color(0xFF40CFCF), // warm teal
};

Color _accentFor(String id) => _destinationAccents[id] ?? BarrioColors.tealWarm;

/// Fixed pixel diameters — all secondary/tertiary bubbles are equal size.
double _diameterFor(BarrioDestination dest) {
  if (dest.prominence == BarrioProminence.primary) return 150.0;
  return 120.0;
}

/// Orbit-ring geometry for the home hub (training-drop slice).
///
/// The classic catalog of up to 5 orbit bubbles keeps the original fixed
/// circle at 44% of the hub's short side with per-bubble radius
/// personality. Larger catalogs size bubbles from the available ring
/// circumference and stretch the ring into an ellipse that uses the full
/// hub box, so every bubble keeps a readable label and clear separation
/// from its neighbors and the center bubble.
class _OrbitGeometry {
  final double axisX;
  final double axisY;
  final double orbitBubbleDiameter;
  final bool dense;

  const _OrbitGeometry({
    required this.axisX,
    required this.axisY,
    required this.orbitBubbleDiameter,
    required this.dense,
  });

  factory _OrbitGeometry.forCatalog(Size hubSize, int orbitCount) {
    final baseOrbitRadius = min(hubSize.width, hubSize.height) * 0.44;
    if (orbitCount <= 5) {
      return _OrbitGeometry(
        axisX: baseOrbitRadius,
        axisY: baseOrbitRadius,
        orbitBubbleDiameter: 120.0,
        dense: false,
      );
    }
    var diameter = 120.0;
    var axisX = baseOrbitRadius;
    var axisY = baseOrbitRadius;
    for (var pass = 0; pass < 3; pass++) {
      axisX = hubSize.width / 2 - diameter / 2 - 4;
      axisY = hubSize.height / 2 - diameter / 2 - 12;
      // Ramanujan ellipse perimeter approximation.
      final perimeter = pi *
          (3 * (axisX + axisY) -
              sqrt((3 * axisX + axisY) * (axisX + 3 * axisY)));
      diameter = (perimeter / orbitCount - 8).clamp(60.0, 120.0);
    }
    return _OrbitGeometry(
      // Never let the ring collapse into the center bubble.
      axisX: max(axisX, 75.0 + diameter / 2 + 6),
      axisY: max(axisY, 75.0 + diameter / 2 + 6),
      orbitBubbleDiameter: diameter,
      dense: true,
    );
  }

  /// Horizontal orbit radius for one bubble. Dense catalogs pin the
  /// per-bubble radius personality to the shared ellipse so computed
  /// spacing holds; the classic circle keeps the original spread.
  double rx(double personalityFactor, double breathe) =>
      dense ? axisX + breathe : axisX * personalityFactor + breathe;

  /// Vertical orbit radius for one bubble.
  double ry(double personalityFactor, double breathe) =>
      dense ? axisY + breathe : axisY * personalityFactor + breathe;

  /// Bubble diameter: fixed classic sizes, or the computed dense size.
  double diameterFor(BarrioDestination dest) =>
      dense ? orbitBubbleDiameter : _diameterFor(dest);
}

/// Returns the correct icon/image widget for a destination bubble.
///
/// Image.asset calls include an errorBuilder so that test environments (which
/// don't load real asset bytes) fall back to an icon rather than throwing.
Widget _iconWidgetFor(
  BuildContext context,
  String id,
  double size,
  Color accent,
  bool isDimmed,
) {
  final color = isDimmed
      ? BarrioColors.textMuted.withValues(alpha: 0.4)
      : accent;
  final dpr = MediaQuery.devicePixelRatioOf(context);

  int? cacheDimension(double logicalSize) {
    final px = (logicalSize * dpr).round();
    return px > 0 ? px : null;
  }

  switch (id) {
    case 'forge_and_flow':
      return Image.asset(
        'assets/images/forge_flow_new_icon.png',
        width: size,
        height: size,
        cacheWidth: cacheDimension(size),
        cacheHeight: cacheDimension(size),
        color: isDimmed ? color : null,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.show_chart_rounded, size: size, color: color),
      );
    case 'company_handbook':
      return Image.asset(
        'assets/internal/barrio/handbook_icon.png',
        width: size * 2.4,
        height: size * 2.4,
        cacheWidth: cacheDimension(size * 2.4),
        cacheHeight: cacheDimension(size * 2.4),
        color: isDimmed ? color : null,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.menu_book_rounded, size: size, color: color),
      );
    case 'jim_taylor_labor_model':
      return Icon(Icons.show_chart_rounded, size: size, color: color);
    case 'interview_playbook':
      return Icon(Icons.assignment_outlined, size: size, color: color);
    case 'preston_lee_model':
      return Icon(Icons.lightbulb_outline, size: size, color: color);
    // Verbatim training bubbles (2026-07-11 training-drop slice)
    case 'training_strong_foundation':
      return Icon(Icons.foundation, size: size, color: color);
    case 'training_table_manicuring':
      return Icon(Icons.table_restaurant_outlined, size: size, color: color);
    case 'training_three_pillars':
      return Icon(Icons.account_balance_outlined, size: size, color: color);
    case 'training_suggestive_selling':
      return Icon(Icons.trending_up_rounded, size: size, color: color);
    case 'training_tequila':
      return Icon(Icons.local_bar_rounded, size: size, color: color);
    case 'training_coffee':
      return Icon(Icons.local_cafe_rounded, size: size, color: color);
    case 'training_latin_dishes':
      return Icon(Icons.restaurant_rounded, size: size, color: color);
    case 'training_latin_ingredients':
      return Icon(Icons.eco_rounded, size: size, color: color);
    case 'training_labour_cost':
      return Icon(Icons.insights_rounded, size: size, color: color);
    case 'training_menu_concept':
      return Icon(Icons.restaurant_menu_rounded, size: size, color: color);
    // Corpus-complete training bubbles (2026-07-11 slice)
    case 'training_bold_by_design':
      return Icon(Icons.auto_stories_rounded, size: size, color: color);
    case 'training_food_safety':
      return Icon(Icons.health_and_safety_rounded, size: size, color: color);
    case 'training_cheers_responsibility':
      return Icon(Icons.wine_bar_rounded, size: size, color: color);
    case 'training_mastering_metrics':
      return Icon(Icons.query_stats_rounded, size: size, color: color);
    case 'training_general_words':
      return Icon(Icons.translate_rounded, size: size, color: color);
    default:
      return Icon(Icons.circle_outlined, size: size, color: color);
  }
}

/// Animated destination bubble hub for the Barrio Legado home screen.
///
/// Animation layers:
///   - `_orbitController`: shared 20s repeat, frame-rate ticker for rebuilds.
///   - `_centerController`: 6s reverse-repeat for the Dashboard glow pulse.
///   - `_entranceController`: 1400ms one-shot; staggered bloom on first appearance.
///   - `_floatControllers[i]`: per-orbit-bubble 4–7s reverse-repeat float drift.
class BarrioBubbleHub extends StatefulWidget {
  final List<BarrioDestination> destinations;
  final ValueChanged<BarrioDestination> onDestinationTap;
  final BarrioPreviewRole previewRole;

  /// B18: production hook for the live permission system.
  /// When non-null, the resolver overrides the legacy
  /// `previewRole.isIntendedFor(dest)` decision per destination.
  /// Production wires `PermissionContextBarrioVisibilityResolver`
  /// (over `PermissionContext`); dev / preview leaves this null
  /// so the chip-driven preview-role still works.
  final BarrioDestinationVisibilityResolver? visibilityResolver;

  const BarrioBubbleHub({
    super.key,
    required this.destinations,
    required this.onDestinationTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
  });

  @override
  State<BarrioBubbleHub> createState() => _BarrioBubbleHubState();
}

class _BarrioBubbleHubState extends State<BarrioBubbleHub>
    with TickerProviderStateMixin {
  // Stopwatch for orbit/breathe/arc math — monotonically increasing, no wraps.
  final _stopwatch = Stopwatch();

  // Shared orbit controller — used only as a frame-rate ticker for rebuilds.
  late final AnimationController _orbitController;

  // Center bubble glow pulse — reverse: true means velocity=0 at both ends.
  late final AnimationController _centerController;
  late final Animation<double> _centerPulse;

  // Entrance animation — fires once on initState, never repeats.
  late final AnimationController _entranceController;

  // Per-orbit-bubble float drift.
  late final List<AnimationController> _floatControllers;
  late final List<Animation<Offset>> _floatAnimations;

  // How many orbit bubbles there are (set in initState).
  late final int _orbitCount;

  // Idle breathing — starts after 4s of no interaction, center bubble only.
  late final AnimationController _idleController;
  late final Animation<double> _idlePulse;
  Timer? _idleTimer;

  // Tracks which bubble ids are currently pressed for tap feedback.
  final _pressedIds = <String>{};

  // Shimmer arc — dedicated controller so shimmer speed is independent of orbit time.
  late final AnimationController _shimmerController;
  late final Animation<double> _shimmerAngle;
  late final Listenable _animationTick;

  @override
  void initState() {
    super.initState();
    _stopwatch.start();

    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    // BSP.1: the orbit ticker only drives positional bubble motion; leave it
    // idle while orbit is disabled. `_shimmerController` still repeats inside
    // `_animationTick`, so shimmer/center-arc rebuilds continue every frame.
    if (kBarrioBubbleOrbitEnabled) {
      _orbitController.repeat();
    }

    _centerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6000),
    );
    _centerPulse = Tween<double>(begin: 0.0, end: 3.0).animate(
      CurvedAnimation(parent: _centerController, curve: Curves.easeInOut),
    );
    _centerController.repeat(reverse: true);

    // Entrance animation — fires once, never repeats.
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..forward();

    // Shimmer arc — 21 s per revolution (~0.3 rad/sec), decoupled from orbit.
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 21000),
    )..repeat();
    _shimmerAngle = Tween<double>(
      begin: 0.0,
      end: 2 * pi,
    ).animate(_shimmerController);

    // Idle breathing — 3s slow pulse, starts after 4s of no interaction.
    _idleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _idlePulse = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _idleController, curve: Curves.easeInOut),
    );
    _startIdleCountdown();

    // Build float controllers once we know the orbit bubble count.
    final visible = widget.destinations.where((d) => d.showOnHomeHub).toList();
    _orbitCount = visible
        .where((d) => d.prominence != BarrioProminence.primary)
        .length;

    final rng = Random(7); // deterministic seed for consistent drift directions
    _floatControllers = List.generate(_orbitCount, (i) {
      // Duration varies 4000–7000ms, never repeating the same cycle length.
      final ms = 4000 + (i * 600 % 3000);
      // Stagger via initial phase — no Future.delayed, no pending timers in tests.
      final initialPhase = _orbitCount > 1 ? i / (_orbitCount - 1) : 0.0;
      final ctrl = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: ms),
        value: initialPhase,
      );
      // BSP.1: float controllers exist only for positional drift; keep them
      // created (and disposed) as usual but idle while orbit is disabled.
      if (kBarrioBubbleOrbitEnabled) {
        ctrl.repeat(reverse: true);
      }
      return ctrl;
    });

    _floatAnimations = List.generate(_orbitCount, (i) {
      // Gentle drift — kept small so bubbles can't pull close enough to overlap.
      final rx = (rng.nextDouble() * 0.032) - 0.016; // −0.016 .. +0.016
      return Tween<Offset>(begin: Offset.zero, end: Offset(rx, -0.022)).animate(
        CurvedAnimation(parent: _floatControllers[i], curve: Curves.easeInOut),
      );
    });

    _animationTick = Listenable.merge([
      _orbitController,
      _centerController,
      _entranceController,
      _shimmerController,
      _idleController,
      ..._floatControllers,
    ]);
  }

  /// Cancels any pending idle timer, resets the idle controller to rest,
  /// then schedules a new countdown. Call on every user interaction.
  void _startIdleCountdown() {
    _idleTimer?.cancel();
    _idleController.stop();
    _idleController.value = 0.0;
    _idleTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _idleController.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _stopwatch.stop();
    _idleTimer?.cancel();
    _orbitController.dispose();
    _centerController.dispose();
    _entranceController.dispose();
    _shimmerController.dispose();
    _idleController.dispose();
    for (final c in _floatControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hubSize = Size(constraints.maxWidth, constraints.maxHeight);
        return AnimatedBuilder(
          animation: _animationTick,
          builder: (context, _) {
            return RepaintBoundary(
              child: Stack(
                clipBehavior: Clip.none,
                children: _buildBubbles(
                  hubSize,
                  _stopwatch.elapsedMilliseconds.toDouble(),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<Widget> _buildBubbles(Size hubSize, double time) {
    final visible = widget.destinations.where((d) => d.showOnHomeHub).toList();
    final center = Offset(hubSize.width / 2, hubSize.height / 2);

    final primary = visible
        .where((d) => d.prominence == BarrioProminence.primary)
        .toList();
    final secondary = visible
        .where((d) => d.prominence != BarrioProminence.primary)
        .toList();

    final widgets = <Widget>[];

    final geometry = _OrbitGeometry.forCatalog(hubSize, secondary.length);

    // Orbit ring track — drawn first so it sits behind all bubbles.
    if (secondary.isNotEmpty) {
      widgets.add(
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _OrbitRingPainter(
                center: center,
                orbitRadius: geometry.axisX,
                orbitRadiusY: geometry.axisY,
                shimmerAngle: _shimmerAngle.value,
              ),
            ),
          ),
        ),
      );
    }

    // Center / primary bubble — fixed size, pulse applied only to glow.
    for (final dest in primary) {
      final diameter = _diameterFor(dest);
      final radius = diameter / 2;
      final centerEntrance = CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.22, curve: Curves.elasticOut),
      ).value;
      widgets.add(
        _buildBubbleAt(
          dest,
          center,
          radius,
          hubSize,
          isPrimary: true,
          entranceScale: centerEntrance,
        ),
      );
    }

    // Orbit bubbles — orbit position + per-bubble float offset.
    // Base radius sized so 5 evenly-spaced 120px bubbles have ~170px chord gap.
    for (var i = 0; i < secondary.length; i++) {
      final dest = secondary[i];
      final p = _personalities[i % _personalities.length];

      // Evenly distribute around the full circle (72° apart for 5 bubbles),
      // starting at top (-π/2). This guarantees consistent separation.
      final baseAngle = (i / secondary.length) * 2 * pi - pi / 2;

      // Continuous time — all bubbles orbit at identical speed (speedFactor=1.0
      // for every personality), permanently preserving the 72° spacing.
      // BSP.1: while orbit is disabled, bubbles pin to their base angles
      // (no rotation, no sway) for stable tap targets.
      final orbitAngle = kBarrioBubbleOrbitEnabled
          ? baseAngle +
                (time / 28000.0) * 2 * pi +
                sin((time / 28000.0) * 2 * pi + i * 1.7) * p.swayAmp
          : baseAngle;
      // Breathe: ±5 px so radius variation can't cause overlap.
      // BSP.1: no radius wobble while orbit is disabled.
      final breathe = kBarrioBubbleOrbitEnabled
          ? sin((time / 8000.0) * 2 * pi + i * 1.1) * 5.0
          : 0.0;
      final orbitRx = geometry.rx(p.radiusFactor, breathe);
      final orbitRy = geometry.ry(p.radiusFactor, breathe);

      // Apply per-bubble float offset.
      // BSP.1: no float drift while orbit is disabled.
      final floatOffset =
          kBarrioBubbleOrbitEnabled && i < _floatControllers.length
          ? _floatAnimations[i].value
          : Offset.zero;

      final pos = Offset(
        center.dx + cos(orbitAngle) * orbitRx + floatOffset.dx * hubSize.width,
        center.dy + sin(orbitAngle) * orbitRy + floatOffset.dy * hubSize.height,
      );

      // Staggered entrance: each orbit bubble starts a beat after the
      // previous. The step shrinks with the catalog size so the last
      // interval always stays inside the [0, 1] animation window.
      final entranceStep = min(0.12, 0.65 / secondary.length);
      final entranceStart = (i + 1) * entranceStep;
      final orbitEntrance = CurvedAnimation(
        parent: _entranceController,
        curve: Interval(
          entranceStart,
          entranceStart + 0.35,
          curve: Curves.elasticOut,
        ),
      ).value;

      final radius = geometry.diameterFor(dest) / 2;
      widgets.add(
        _buildBubbleAt(
          dest,
          pos,
          radius,
          hubSize,
          entranceScale: orbitEntrance,
        ),
      );
    }

    return widgets;
  }

  Widget _buildBubbleAt(
    BarrioDestination dest,
    Offset position,
    double radius,
    Size hubSize, {
    bool isPrimary = false,
    double entranceScale = 1.0,
  }) {
    final diameter = radius * 2;
    final left = position.dx - radius;
    final top = position.dy - radius;

    // B18: prefer the production visibility resolver when wired,
    // otherwise fall back to the preview-role tier so dev / preview
    // shells still respect the chip selection.
    final resolver = widget.visibilityResolver;
    final isIntended = resolver != null
        ? resolver.isVisible(dest)
        : widget.previewRole.isIntendedFor(dest);
    final isDimmed = !isIntended && !dest.comingSoon;
    final isPressed = _pressedIds.contains(dest.id);

    Widget bubble = isPrimary
        ? _buildCenterNode(dest, diameter, isPressed)
        : _buildOrbitNode(dest, diameter, isDimmed, isPressed);

    if (dest.comingSoon) {
      bubble = Opacity(opacity: 0.30, child: bubble);
    } else if (isDimmed) {
      bubble = Opacity(opacity: 0.38, child: bubble);
    }

    // Press: scale to 0.92 with spring-back.
    bubble = AnimatedScale(
      scale: isPressed ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: bubble,
    );

    // Entrance: scale from 0 → 1 with elastic overshoot on first load.
    bubble = Transform.scale(scale: entranceScale, child: bubble);

    // Idle breathing scale — only on center bubble, only when not pressed.
    if (isPrimary) {
      final idleScale = isPressed ? 1.0 : 1.0 + _idlePulse.value * 0.025;
      bubble = Transform.scale(scale: idleScale, child: bubble);
    }

    // Dimmed bubbles (role not assigned) are fully non-interactive.
    // Coming Soon bubbles still navigate (placeholder screen) and respond to touch.
    Widget touchTarget = RepaintBoundary(
      child: SizedBox(width: diameter, height: diameter, child: bubble),
    );
    if (!isDimmed) {
      touchTarget = GestureDetector(
        onTapDown: (_) {
          HapticFeedback.lightImpact();
          _startIdleCountdown();
          setState(() => _pressedIds.add(dest.id));
        },
        onTapUp: (_) {
          // Primary bubble gets a more satisfying medium impact on navigate.
          if (isPrimary) {
            HapticFeedback.mediumImpact();
          }
          setState(() => _pressedIds.remove(dest.id));
          widget.onDestinationTap(dest);
        },
        onTapCancel: () {
          _startIdleCountdown();
          setState(() => _pressedIds.remove(dest.id));
        },
        child: touchTarget,
      );
    }

    return Positioned(left: left, top: top, child: touchTarget);
  }

  // ---------------------------------------------------------------------------
  // Center / primary — frosted glass Dashboard
  // ---------------------------------------------------------------------------

  Widget _buildCenterNode(
    BarrioDestination dest,
    double diameter,
    bool isPressed,
  ) {
    final r = diameter / 2;
    final accent = _accentFor(dest.id);
    final time = _stopwatch.elapsedMilliseconds.toDouble();

    // Glow breathes with center pulse; flares on press.
    final glowBlur = (28.0 + _centerPulse.value * 4) * (isPressed ? 1.5 : 1.0);
    final glowSpread = _centerPulse.value * 2;
    final glowAlpha = isPressed ? 0.80 : 0.55;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // 1 — Glow halo — outside ClipRRect so it spreads freely
        //     Dual-color: blue shadow left, orange shadow right
        Container(
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
        ),

        // 2 — Rotating arc — outside ClipRRect so it isn't blurred away
        //     One arc blue, one arc orange — mirrors the logo palette
        SizedBox(
          width: diameter + 8,
          height: diameter + 8,
          child: CustomPaint(
            painter: _CenterArcPainter(
              radius: r + 4,
              time: time,
              color1: _logoOrange,
              color2: _logoBlue,
              isPressed: isPressed,
            ),
          ),
        ),

        // 3 — Glass disc
        ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              width: diameter,
              height: diameter,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(
                    color: Color(
                      0xAAFF6B35,
                    ), // orange at 67% — visible against blue fill
                    width: 1.0,
                  ),
                ),
              ),
              child: Stack(
                children: [
                  // Dark glass base
                  Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0x38000000),
                    ),
                  ),
                  // Blue → orange diagonal gradient fill — light wash, not opaque
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
                  // Top specular — glass catching overhead light
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
                  // Content
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _iconWidgetFor(
                          context,
                          dest.id,
                          diameter * 0.30,
                          accent,
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
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Orbit / secondary — 3D glassmorphism bubble with per-dest accent color
  // ---------------------------------------------------------------------------

  Widget _buildOrbitNode(
    BarrioDestination dest,
    double diameter,
    bool isDimmed,
    bool isPressed,
  ) {
    final r = diameter / 2;
    final accent = _accentFor(dest.id);

    // Glow intensifies on press.
    final innerGlowAlpha = isPressed ? 0.72 : 0.48;
    final glowBlurMult = isPressed ? 1.5 : 1.0;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Glow halo — outside ClipRRect so it isn't clipped away
        Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: isDimmed
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
        ),
        // Glass disc
        ClipRRect(
          borderRadius: BorderRadius.circular(r),
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
                  // Dark glass base
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDimmed
                          ? const Color(0x20000000)
                          : const Color(0x30000000),
                    ),
                  ),
                  // Accent fill — weighted to bottom, low alpha = tint not paint
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
                  // Top specular — overhead light on glass surface
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(0.0, -0.65),
                        radius: 0.52,
                        colors: [
                          Colors.white.withValues(
                            alpha: isDimmed ? 0.05 : 0.16,
                          ),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  // Content — handbook uses Stack so leaf is behind text
                  if (dest.id == 'company_handbook')
                    Stack(
                      children: [
                        // Leaf image — decorative, behind text, fills bubble
                        Positioned.fill(
                          child: Align(
                            alignment: const Alignment(0.0, -0.3),
                            child: _iconWidgetFor(
                              context,
                              dest.id,
                              diameter * 0.30,
                              accent,
                              isDimmed,
                            ),
                          ),
                        ),
                        // Label — below the leaf, centered horizontally
                        Align(
                          alignment: const Alignment(0.0, 0.45),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              dest.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: max(diameter * 0.100, 11),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                                color: isDimmed
                                    ? BarrioColors.textMuted.withValues(
                                        alpha: 0.35,
                                      )
                                    : BarrioColors.textPrimary,
                                height: 1.2,
                                shadows: isDimmed
                                    ? null
                                    : const [
                                        Shadow(
                                          color: Color(0x50000000),
                                          blurRadius: 6,
                                        ),
                                      ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _iconWidgetFor(
                              context,
                              dest.id,
                              diameter * 0.30,
                              accent,
                              isDimmed,
                            ),
                            SizedBox(height: diameter * 0.05),
                            Text(
                              dest.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: max(diameter * 0.100, 11),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                                color: isDimmed
                                    ? BarrioColors.textMuted.withValues(
                                        alpha: 0.35,
                                      )
                                    : BarrioColors.textPrimary,
                                height: 1.2,
                                shadows: isDimmed
                                    ? null
                                    : const [
                                        Shadow(
                                          color: Color(0x50000000),
                                          blurRadius: 6,
                                        ),
                                      ],
                              ),
                            ),
                            if (dest.comingSoon) ...[
                              SizedBox(height: diameter * 0.03),
                              // Corpus-complete slice (2026-07-11): at dense
                              // catalog diameters this tag used to wrap to two
                              // lines and overflow the bubble by ~4px. Scale
                              // down instead of wrapping; single line always
                              // fits any diameter >= the 60px clamp floor.
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
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

/// Faint circular orbit track with a traveling shimmer arc.
/// Drawn behind all bubbles to reinforce the orbital system metaphor.
class _OrbitRingPainter extends CustomPainter {
  final Offset center;
  final double orbitRadius;
  final double shimmerAngle;

  /// Vertical semi-axis. Defaults to [orbitRadius] (a circle); the dense
  /// training-catalog layout passes a taller axis so the ring is an ellipse
  /// that uses the full hub box.
  final double orbitRadiusY;

  _OrbitRingPainter({
    required this.center,
    required this.orbitRadius,
    required this.shimmerAngle,
    double? orbitRadiusY,
  }) : orbitRadiusY = orbitRadiusY ?? orbitRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final ringRect = Rect.fromCenter(
      center: center,
      width: orbitRadius * 2,
      height: orbitRadiusY * 2,
    );

    // Subtle blue → orange → blue sweep gradient ring
    canvas.drawOval(
      ringRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = SweepGradient(
          center: FractionalOffset(
            center.dx / size.width,
            center.dy / size.height,
          ),
          colors: [
            _logoBlue.withValues(alpha: 0.35),
            _logoOrange.withValues(alpha: 0.35),
            _logoBlue.withValues(alpha: 0.35),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(ringRect),
    );

    // Traveling shimmer — split into blue (leading) and orange (trailing).
    final arcAngle = shimmerAngle;

    // Soft glow pass behind both arcs
    canvas.drawArc(
      ringRect,
      arcAngle - pi / 6,
      pi / 3,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x28FFFFFF),
    );

    // Orange leading arc
    canvas.drawArc(
      ringRect,
      arcAngle - pi / 6,
      pi / 6,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = _logoOrange.withValues(alpha: 0.90),
    );

    // Blue trailing arc
    canvas.drawArc(
      ringRect,
      arcAngle,
      pi / 6,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = _logoBlue.withValues(alpha: 0.90),
    );
  }

  @override
  bool shouldRepaint(_OrbitRingPainter old) =>
      old.shimmerAngle != shimmerAngle ||
      old.orbitRadius != orbitRadius ||
      old.orbitRadiusY != orbitRadiusY;
}

/// Two symmetric 120° arcs rotating slowly around the center/primary bubble.
/// color1 (orange) and color2 (blue) alternate — mirrors the F&F logo palette.
/// Drawn outside the glass ClipRRect so they sit at the correct depth.
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
    const sweep = pi * 2 / 3; // 120°

    final crispAlpha = isPressed ? 0.90 : 0.65;

    // Arc 1 — color1 (orange), Arc 2 — color2 (blue), 180° apart.
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
