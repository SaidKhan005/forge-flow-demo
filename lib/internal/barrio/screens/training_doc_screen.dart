import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/handbook_chapter_rail.dart';
import '../widgets/handbook_lesson_card.dart';
import '../widgets/learning_carousel.dart';

/// Generic verbatim training-document surface (2026-07-11 training-drop
/// slice). One screen renders any [BarrioTrainingDoc] with the same
/// chapter rail + learning carousel + lesson card composition the
/// Company Handbook surface uses, so all training bubbles share one
/// look. Content is word-for-word source text (explainer cards only),
/// so the hero shows honest section position instead of a mastery
/// percentage.
class TrainingDocScreen extends StatefulWidget {
  final BarrioTrainingDoc doc;
  final Color accent;
  final BarrioPreviewRole previewRole;

  const TrainingDocScreen({
    super.key,
    required this.doc,
    this.accent = BarrioColors.tealWarm,
    this.previewRole = BarrioPreviewRole.admin,
  });

  @override
  State<TrainingDocScreen> createState() => _TrainingDocScreenState();
}

class _TrainingDocScreenState extends State<TrainingDocScreen>
    with TickerProviderStateMixin {
  int _activeChapter = 0;
  final Set<String> _viewedChapterIds = {};

  late final AnimationController _heroController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final Animation<double> _heroFade =
      CurvedAnimation(parent: _heroController, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    if (widget.doc.chapters.isNotEmpty) {
      _viewedChapterIds.add(widget.doc.chapters.first.id);
    }
  }

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.doc.chapters;
    final chapter = chapters[_activeChapter];
    final accent = widget.accent;

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: widget.doc.title,
        accentColor: accent,
      ),
      body: BarrioPremiumBackground(
        accentColor: accent,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeTransition(
                opacity: _heroFade,
                child: _TrainingHero(
                  chapter: chapter,
                  accent: accent,
                  sectionIndex: _activeChapter,
                  sectionCount: chapters.length,
                ),
              ),
              const SizedBox(height: 12),
              HandbookChapterRail(
                chapters: chapters,
                activeIndex: _activeChapter,
                completedChapterIds: _viewedChapterIds,
                activeAccent: accent,
                onChapterTap: (i) {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _activeChapter = i;
                    _viewedChapterIds.add(chapters[i].id);
                  });
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LearningCarousel(
                  key: ValueKey(chapter.id),
                  cardCount: chapter.units.length,
                  accent: accent,
                  // Verbatim docs are explainer-only; every card counts as
                  // read once the chapter is open.
                  completedIndices: {
                    for (var i = 0; i < chapter.units.length; i++) i,
                  },
                  cardBuilder: (context, index) {
                    return HandbookLessonCard(
                      key: ValueKey(chapter.units[index].id),
                      unit: chapter.units[index],
                      isCarouselMode: true,
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
}

class _TrainingHero extends StatelessWidget {
  final HandbookChapter chapter;
  final Color accent;
  final int sectionIndex;
  final int sectionCount;

  const _TrainingHero({
    required this.chapter,
    required this.accent,
    required this.sectionIndex,
    required this.sectionCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SECTION ${sectionIndex + 1} OF $sectionCount',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              color: accent.withValues(alpha: 0.65),
            ),
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
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (sectionIndex + 1) / sectionCount,
              minHeight: 3,
              backgroundColor: BarrioColors.shellSurface,
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
        ],
      ),
    );
  }
}
