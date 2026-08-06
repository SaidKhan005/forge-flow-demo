import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/interview_playbook_content.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_celebration_overlay.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_streak_tracker.dart';
import '../widgets/learning_carousel.dart';
import '../widgets/learning_surface_card.dart';

/// The Interview Playbook learning surface for supervisors and managers.
///
/// Premium photo-backed scaffold with emerald green accent bloom.
class InterviewPlaybookScreen extends StatefulWidget {
  final BarrioPreviewRole previewRole;

  const InterviewPlaybookScreen({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  @override
  State<InterviewPlaybookScreen> createState() =>
      _InterviewPlaybookScreenState();
}

class _InterviewPlaybookScreenState extends State<InterviewPlaybookScreen>
    with TickerProviderStateMixin {
  int _activeSection = 0;
  final Set<String> _completedUnits = {};
  Set<int> _prevCompletedSections = {};

  static const _accent = BarrioColors.accentPlaybook; // emerald green

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
    final section = playbookSections[_activeSection];
    final progress = _sectionProgress(section);
    final overallProgress = _overallProgress();

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'Interview Playbook',
        accentColor: _accent,
      ),
      body: _PlaybookPremiumBackground(
        accent: _accent,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeTransition(
                opacity: _heroFade,
                child: _PlaybookHero(
                  section: section,
                  accent: _accent,
                  progress: progress,
                  overallProgress: overallProgress,
                ),
              ),
              const SizedBox(height: 12),
              LearningSectionRail(
                titles: playbookSections.map((s) => s.title).toList(),
                iconCodePoints:
                    playbookSections.map((s) => s.iconCodePoint).toList(),
                activeIndex: _activeSection,
                activeAccent: _accent,
                completedIndices: _completedSectionIndices(),
                onTap: (i) {
                  HapticFeedback.lightImpact();
                  setState(() => _activeSection = i);
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LearningCarousel(
                  key: ValueKey(section.id),
                  cardCount: section.units.length,
                  accent: _accent,
                  cardBuilder: (context, index) {
                    return _buildCard(section.units[index], context);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(PlaybookUnit unit, BuildContext cardContext) {
    final (defaultBadge, color) = switch (unit.type) {
      PlaybookUnitType.guide    => ('GUIDE',    BarrioColors.tealWarm),
      PlaybookUnitType.scenario => ('SCENARIO', _accent),
      PlaybookUnitType.checkpoint => ('CHECK',  BarrioColors.warning),
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
        _checkSectionCompletion();
      },
      onRequestAdvance: () {
        final carouselState = cardContext
            .findAncestorStateOfType<LearningCarouselState>();
        carouselState?.requestAdvance();
      },
    );
  }

  void _checkSectionCompletion() {
    final currentCompleted = _completedSectionIndices();
    final newlyCompleted = currentCompleted.difference(_prevCompletedSections);
    if (newlyCompleted.isNotEmpty) {
      final secIndex = newlyCompleted.first;
      HapticFeedback.heavyImpact();
      BarrioCelebrationOverlay.showModuleComplete(
        context,
        title: playbookSections[secIndex].title,
        accentColor: _accent,
      );
    }
    _prevCompletedSections = currentCompleted;
  }

  double _sectionProgress(PlaybookSection section) {
    final interactive = section.units
        .where((u) => u.type != PlaybookUnitType.guide)
        .toList();
    if (interactive.isEmpty) return 0.0;
    final completed =
        interactive.where((u) => _completedUnits.contains(u.id)).length;
    return completed / interactive.length;
  }

  double _overallProgress() {
    int total = 0;
    int done = 0;
    for (final sec in playbookSections) {
      final interactive =
          sec.units.where((u) => u.type != PlaybookUnitType.guide);
      total += interactive.length;
      done += interactive.where((u) => _completedUnits.contains(u.id)).length;
    }
    return total == 0 ? 0.0 : done / total;
  }

  Set<int> _completedSectionIndices() {
    final result = <int>{};
    for (var i = 0; i < playbookSections.length; i++) {
      final interactive = playbookSections[i]
          .units
          .where((u) => u.type != PlaybookUnitType.guide)
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


class _PlaybookHero extends StatelessWidget {
  final PlaybookSection section;
  final Color accent;
  final double progress;
  final double overallProgress;

  const _PlaybookHero({
    required this.section,
    required this.accent,
    required this.progress,
    required this.overallProgress,
  });

  @override
  Widget build(BuildContext context) {
    final interactive = section.units.where((u) => u.type != PlaybookUnitType.guide);
    final remaining = interactive.length -
        (interactive.length * progress).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overall mastery row
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
            ],
          ),
          const SizedBox(height: 8),
          Text(
            section.title,
            style: GoogleFonts.playfairDisplay(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: BarrioColors.textPrimary,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            section.subtitle,
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
                : 'Section complete',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              color: remaining > 0
                  ? BarrioColors.textMuted
                  : BarrioColors.success,
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

class _PlaybookPremiumBackground extends StatelessWidget {
  final Color accent;
  final Widget child;

  const _PlaybookPremiumBackground({
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-bleed photo. Decoded at screen width (perf audit
        // A1), not the source resolution.
        Positioned.fill(
          child: Image.asset(
            'assets/internal/barrio/interview_bg.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(0.0, -0.2),
            cacheWidth:
                barrioCacheWidth(context, MediaQuery.sizeOf(context).width),
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

        // Layers 3 + 4: the shared emerald accent bloom (top-right) and
        // complementary navy bloom, from BarrioPremiumBackground.
        Positioned.fill(
          child: BarrioPremiumBackground(
            accentColor: accent,
            accentOpacity: 0.16,
            bloomAlignment: const Alignment(0.85, -0.8),
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
