import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/company_handbook_content.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_celebration_overlay.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_streak_tracker.dart';
import '../widgets/handbook_chapter_rail.dart';
import '../widgets/handbook_lesson_card.dart';
import '../widgets/learning_carousel.dart';

/// The Company Handbook learning surface for all staff.
///
/// Premium photo-backed scaffold with brick red accent bloom,
/// matching the historic Barrio building.
class CompanyHandbookScreen extends StatefulWidget {
  final BarrioPreviewRole previewRole;

  const CompanyHandbookScreen({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  @override
  State<CompanyHandbookScreen> createState() => _CompanyHandbookScreenState();
}

class _CompanyHandbookScreenState extends State<CompanyHandbookScreen>
    with TickerProviderStateMixin {
  int _activeChapter = 0;
  final Set<String> _completedUnits = {};
  Set<String> _prevCompletedChapterIds = {};

  static const _accent = BarrioColors.accentHandbook; // brick red

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

  Set<String> get _completedChapterIds {
    final result = <String>{};
    for (final chapter in handbookChapters) {
      final interactiveIds = chapter.units
          .where((u) => u.type != HandbookUnitType.explainer)
          .map((u) => u.id)
          .toSet();
      if (interactiveIds.isNotEmpty &&
          interactiveIds.every(_completedUnits.contains)) {
        result.add(chapter.id);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final chapter = handbookChapters[_activeChapter];
    final progress = _chapterProgress(chapter);
    final overallProgress = _overallProgress();

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'Company Handbook',
        accentColor: _accent,
      ),
      body: _HandbookPremiumBackground(
        accent: _accent,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeTransition(
                opacity: _heroFade,
                child: _HandbookHero(
                  chapter: chapter,
                  progress: progress,
                  accent: _accent,
                  overallProgress: overallProgress,
                ),
              ),
              const SizedBox(height: 12),
              HandbookChapterRail(
                chapters: handbookChapters,
                activeIndex: _activeChapter,
                completedChapterIds: _completedChapterIds,
                activeAccent: _accent,
                onChapterTap: (i) {
                  HapticFeedback.lightImpact();
                  setState(() => _activeChapter = i);
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LearningCarousel(
                  key: ValueKey(chapter.id),
                  cardCount: chapter.units.length,
                  accent: _accent,
                  completedIndices: chapter.units
                      .asMap()
                      .entries
                      .where((e) =>
                          e.value.type == HandbookUnitType.explainer ||
                          _completedUnits.contains(e.value.id))
                      .map((e) => e.key)
                      .toSet(),
                  cardBuilder: (context, index) {
                    return HandbookLessonCard(
                      key: ValueKey(chapter.units[index].id),
                      unit: chapter.units[index],
                      isCarouselMode: true,
                      onCompleted: () {
                        setState(() => _completedUnits
                            .add(chapter.units[index].id));
                        BarrioStreakService.recordActivity();
                        _checkChapterCompletion();
                      },
                      onRequestAdvance: () {
                        final carouselState = context
                            .findAncestorStateOfType<LearningCarouselState>();
                        carouselState?.requestAdvance();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _checkChapterCompletion() {
    final currentCompleted = _completedChapterIds;
    final newlyCompleted =
        currentCompleted.difference(_prevCompletedChapterIds);
    if (newlyCompleted.isNotEmpty) {
      final chapterId = newlyCompleted.first;
      final chapter = handbookChapters.firstWhere((c) => c.id == chapterId);
      HapticFeedback.heavyImpact();
      BarrioCelebrationOverlay.showModuleComplete(
        context,
        title: chapter.title,
        accentColor: _accent,
      );
    }
    _prevCompletedChapterIds = currentCompleted;
  }

  double _chapterProgress(HandbookChapter chapter) {
    final interactive = chapter.units
        .where((u) => u.type != HandbookUnitType.explainer)
        .toList();
    if (interactive.isEmpty) return 0.0;
    final completed =
        interactive.where((u) => _completedUnits.contains(u.id)).length;
    return completed / interactive.length;
  }

  double _overallProgress() {
    int total = 0;
    int done = 0;
    for (final ch in handbookChapters) {
      final interactive =
          ch.units.where((u) => u.type != HandbookUnitType.explainer);
      total += interactive.length;
      done += interactive.where((u) => _completedUnits.contains(u.id)).length;
    }
    return total == 0 ? 0.0 : done / total;
  }
}


class _HandbookHero extends StatelessWidget {
  final HandbookChapter chapter;
  final double progress;
  final Color accent;
  final double overallProgress;

  const _HandbookHero({
    required this.chapter,
    required this.progress,
    required this.accent,
    required this.overallProgress,
  });

  @override
  Widget build(BuildContext context) {
    final interactive = chapter.units
        .where((u) => u.type != HandbookUnitType.explainer);
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
            chapter.title,
            style: GoogleFonts.playfairDisplay(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: BarrioColors.textPrimary,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            chapter.subtitle,
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
                : 'Chapter complete',
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

/// Full-bleed building photo with gradient scrims, accent bloom, and vignette.
/// Mirrors the home screen's premium multi-layer composition.
class _HandbookPremiumBackground extends StatelessWidget {
  final Color accent;
  final Widget child;

  const _HandbookPremiumBackground({
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-bleed building photo
        Positioned.fill(
          child: Image.asset(
            'assets/internal/barrio/handbook_bg.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(0.0, -0.3), // show upper facade
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),

        // Layer 2: Dark gradient scrim for text legibility
        // Heavy at top (AppBar/hero area) and bottom, lighter in center
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

        // Layer 3: Accent bloom — warm brick red radial glow, top-right
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.8, -0.85),
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

        // Layer 5: Edge vignette — cinematic darkness at corners
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
