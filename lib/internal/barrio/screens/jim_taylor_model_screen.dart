import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/jim_taylor_model_content.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_celebration_overlay.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_streak_tracker.dart';
import '../widgets/learning_carousel.dart';
import '../widgets/learning_surface_card.dart';

/// The Jim Taylor Labor Model learning surface for managers and admins.
///
/// Premium photo-backed scaffold with teal ambient bloom.
/// More serious, metric-focused feel than the handbook or playbook.
class JimTaylorModelScreen extends StatefulWidget {
  final BarrioPreviewRole previewRole;

  const JimTaylorModelScreen({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  @override
  State<JimTaylorModelScreen> createState() => _JimTaylorModelScreenState();
}

class _JimTaylorModelScreenState extends State<JimTaylorModelScreen>
    with TickerProviderStateMixin {
  int _activeModule = 0;
  final Set<String> _completedUnits = {};
  Set<int> _prevCompletedModules = {};

  static const _accent = BarrioColors.accentJimTaylor; // deep teal

  // Hero entrance animation
  late final AnimationController _heroController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final Animation<double> _heroFade =
      CurvedAnimation(parent: _heroController, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mod = jtModules[_activeModule];
    final progress = _moduleProgress(mod);
    final overallProgress = _overallProgress();

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'Jim Taylor Labor Model',
        accentColor: _accent,
      ),
      body: _JtPremiumBackground(
        accent: _accent,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeTransition(
                opacity: _heroFade,
                child: _JtModuleHero(
                  mod: mod,
                  moduleIndex: _activeModule,
                  accent: _accent,
                  progress: progress,
                  overallProgress: overallProgress,
                ),
              ),
              const SizedBox(height: 12),
              LearningSectionRail(
                titles: jtModules.map((m) => m.title).toList(),
                iconCodePoints: jtModules.map((m) => m.iconCodePoint).toList(),
                activeIndex: _activeModule,
                activeAccent: _accent,
                completedIndices: _completedModuleIndices(),
                onTap: (i) {
                  HapticFeedback.lightImpact();
                  setState(() => _activeModule = i);
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LearningCarousel(
                  key: ValueKey(mod.id),
                  cardCount: mod.units.length,
                  accent: _accent,
                  cardBuilder: (context, index) {
                    return _buildCard(mod.units[index], context);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(JtUnit unit, BuildContext cardContext) {
    final (defaultBadge, color) = switch (unit.type) {
      JtUnitType.concept    => ('CONCEPT',  _accent),
      JtUnitType.scenario   => ('SCENARIO', const Color(0xFF2ECC71)),
      JtUnitType.checkpoint => ('CHECK',    BarrioColors.warning),
    };
    final badge = unit.badgeHint ?? defaultBadge;
    return LearningSurfaceCard(
      key: ValueKey(unit.id),
      title: unit.title,
      body: unit.body,
      badgeLabel: badge,
      badgeColor: color,
      isCarouselMode: true,
      options: unit.options
          .map((o) => LearningOption(
                label: o.label,
                isCorrect: o.isCorrect,
                feedback: o.feedback,
              ))
          .toList(),
      onCompleted: () {
        setState(() => _completedUnits.add(unit.id));
        BarrioStreakService.recordActivity();
        _checkModuleCompletion();
      },
      onRequestAdvance: () {
        final carouselState = cardContext
            .findAncestorStateOfType<LearningCarouselState>();
        carouselState?.requestAdvance();
      },
    );
  }

  void _checkModuleCompletion() {
    final currentCompleted = _completedModuleIndices();
    final newlyCompleted = currentCompleted.difference(_prevCompletedModules);
    if (newlyCompleted.isNotEmpty) {
      final modIndex = newlyCompleted.first;
      HapticFeedback.heavyImpact();
      BarrioCelebrationOverlay.showModuleComplete(
        context,
        title: jtModules[modIndex].title,
        accentColor: _accent,
      );
    }
    _prevCompletedModules = currentCompleted;
  }

  double _moduleProgress(JtModule mod) {
    final interactive = mod.units
        .where((u) => u.type != JtUnitType.concept)
        .toList();
    if (interactive.isEmpty) return 0.0;
    final completed =
        interactive.where((u) => _completedUnits.contains(u.id)).length;
    return completed / interactive.length;
  }

  double _overallProgress() {
    int total = 0;
    int done = 0;
    for (final mod in jtModules) {
      final interactive =
          mod.units.where((u) => u.type != JtUnitType.concept);
      total += interactive.length;
      done += interactive.where((u) => _completedUnits.contains(u.id)).length;
    }
    return total == 0 ? 0.0 : done / total;
  }

  Set<int> _completedModuleIndices() {
    final result = <int>{};
    for (var i = 0; i < jtModules.length; i++) {
      final interactive = jtModules[i]
          .units
          .where((u) => u.type != JtUnitType.concept)
          .map((u) => u.id)
          .toSet();
      if (interactive.isNotEmpty &&
          interactive.every(_completedUnits.contains)) {
        result.add(i);
      }
    }
    return result;
  }
}


class _JtModuleHero extends StatelessWidget {
  final JtModule mod;
  final int moduleIndex;
  final Color accent;
  final double progress;
  final double overallProgress;

  const _JtModuleHero({
    required this.mod,
    required this.moduleIndex,
    required this.accent,
    required this.progress,
    required this.overallProgress,
  });

  @override
  Widget build(BuildContext context) {
    final interactive = mod.units.where((u) => u.type != JtUnitType.concept);
    final remaining = interactive.length -
        (interactive.length * progress).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overall mastery + module label row
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${(overallProgress * 100).round()}%',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: accent,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'MASTERY',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2,
                  color: accent.withValues(alpha: 0.55),
                ),
              ),
              const Spacer(),
              Text(
                'Module ${moduleIndex + 1}',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                  color: accent.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            mod.title,
            style: GoogleFonts.playfairDisplay(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: BarrioColors.textPrimary,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            mod.subtitle,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 13,
              color: BarrioColors.textMuted,
            ),
          ),
          const SizedBox(height: 10),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: BarrioColors.shellSurface,
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            remaining > 0
                ? '$remaining lesson${remaining == 1 ? '' : 's'} to go'
                : 'Module complete',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              color: remaining > 0
                  ? BarrioColors.textMuted
                  : const Color(0xFF2ECC71),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Premium photo-backed background — same layering as home screen
// ---------------------------------------------------------------------------

/// Full-bleed book photo with gradient scrims, teal accent bloom, and vignette.
/// Mirrors the home screen's premium multi-layer composition.
class _JtPremiumBackground extends StatelessWidget {
  final Color accent;
  final Widget child;

  const _JtPremiumBackground({
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-bleed book photo
        Positioned.fill(
          child: Image.asset(
            'assets/internal/barrio/jim_taylor_bg.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(0.0, -0.2),
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),

        // Layer 2: Cream veil for text legibility (light shell color)
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.15, 0.35, 0.65, 0.85, 1.0],
                  colors: [
                    BarrioColors.shellDeep.withValues(alpha: 0.95),
                    BarrioColors.shellDeep.withValues(alpha: 0.88),
                    BarrioColors.shellDeep.withValues(alpha: 0.78),
                    BarrioColors.shellDeep.withValues(alpha: 0.82),
                    BarrioColors.shellDeep.withValues(alpha: 0.90),
                    BarrioColors.shellDeep.withValues(alpha: 0.96),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layer 3: Teal accent bloom — top-right
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.7, -0.9),
                  radius: 1.05,
                  colors: [
                    accent.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layer 4: Complementary navy bloom — opposite corner
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
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

        // Layer 5: Edge vignette
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [
                    Colors.transparent,
                    BarrioColors.shellDeep.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Content
        child,
      ],
    );
  }
}
