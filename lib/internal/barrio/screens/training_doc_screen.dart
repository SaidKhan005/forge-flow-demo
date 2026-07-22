import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../search/barrio_training_search.dart';
import '../routes/barrio_preview_role.dart';
import '../services/barrio_reading_progress_service.dart';
import '../services/barrio_reading_time.dart';
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

  /// Section to open first (Wave B training search deep link). Clamped
  /// to the valid chapter range. Null (the default) means "no explicit
  /// deep link": the screen restores the locally saved reading position
  /// instead ("the app remembers you", 2026-07-22). Any non-null value,
  /// including 0, is an explicit deep link and always wins over resume.
  final int? initialChapterIndex;

  /// Card to open first within [initialChapterIndex] (search deep link,
  /// 2026-07-11 operator request). Clamped to the section's card range.
  /// Null follows the same resume rule as [initialChapterIndex].
  final int? initialUnitInChapter;

  /// The search query whose words get highlighted inside card bodies
  /// (case- and diacritic-insensitive). Null = no highlighting.
  final String? highlightQuery;

  const TrainingDocScreen({
    super.key,
    required this.doc,
    this.accent = BarrioColors.tealWarm,
    this.previewRole = BarrioPreviewRole.admin,
    this.initialChapterIndex,
    this.initialUnitInChapter,
    this.highlightQuery,
  });

  @override
  State<TrainingDocScreen> createState() => _TrainingDocScreenState();
}

class _TrainingDocScreenState extends State<TrainingDocScreen>
    with TickerProviderStateMixin {
  int _activeChapter = 0;

  /// Cards read on THIS device, persisted across sessions ("the app
  /// remembers you", 2026-07-22). A card counts as read when it settles
  /// on screen: a fact, not a mastery claim (Metric Honesty).
  final Set<String> _readUnitIds = {};

  /// True once the user moved the deck themselves (swipe or rail tap).
  /// The async position restore then stands down: the user's own
  /// position is fresher truth than the saved one.
  bool _pageTouched = false;

  // Continuous swiping (2026-07-11 operator request): the carousel
  // holds EVERY unit of EVERY section as one flat deck, so swiping past
  // a section's last card lands on the next section. The hero and rail
  // follow the visible card's section. A rail tap jumps by re-mounting
  // the carousel at the target section's first card (bumping _epoch),
  // which is why swipe-driven section changes must NOT touch _epoch.
  static final RegExp _whitespace = RegExp(r'\s+');

  late final List<HandbookUnit> _flatUnits;
  late final List<int> _chapterStarts;
  late final List<String> _highlightTerms;
  int _epoch = 0;
  int _initialPage = 0;

  late final AnimationController _heroController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final Animation<double> _heroFade =
      CurvedAnimation(parent: _heroController, curve: Curves.easeOutCubic);

  /// True when the caller supplied an explicit deep link (search or the
  /// home Continue Reading card). Deep links always win over resume.
  bool get _hasDeepLink =>
      widget.initialChapterIndex != null || widget.initialUnitInChapter != null;

  @override
  void initState() {
    super.initState();
    final chapters = widget.doc.chapters;
    _flatUnits = [for (final c in chapters) ...c.units];
    _chapterStarts = [];
    var start = 0;
    for (final c in chapters) {
      _chapterStarts.add(start);
      start += c.units.length;
    }
    if (chapters.isNotEmpty && _hasDeepLink) {
      _applyPosition(
        widget.initialChapterIndex ?? 0,
        widget.initialUnitInChapter ?? 0,
      );
    }
    _loadPersistedState();
    final query = widget.highlightQuery?.trim();
    _highlightTerms = query == null || query.isEmpty
        ? const []
        : BarrioTrainingSearch.fold(query)
            .split(_whitespace)
            .where((w) => w.isNotEmpty)
            .toList();
  }

  /// Clamps and applies a (chapter, unit-in-chapter) position to
  /// [_activeChapter] and [_initialPage].
  void _applyPosition(int chapterIndex, int unitInChapter) {
    final chapters = widget.doc.chapters;
    if (chapters.isEmpty) return;
    _activeChapter = chapterIndex.clamp(0, chapters.length - 1);
    final unitCount = chapters[_activeChapter].units.length;
    final unit = unitCount == 0 ? 0 : unitInChapter.clamp(0, unitCount - 1);
    _initialPage = _chapterStarts[_activeChapter] + unit;
  }

  /// Loads the saved read marks (always) and, when the caller supplied
  /// no deep link, the saved reading position. Non-blocking: the
  /// carousel mounts immediately (first-ever open keeps section 0 card
  /// 0, deep links keep their target) and re-mounts at the saved card
  /// when the restore lands, unless the user already moved the deck.
  /// A platform without a working preferences store simply never
  /// resolves or returns empty: the screen behaves exactly as before
  /// this slice.
  Future<void> _loadPersistedState() async {
    final docId = widget.doc.id;
    final position = _hasDeepLink
        ? null
        : await BarrioReadingProgressService.getPosition(docId);
    final readIds = await BarrioReadingProgressService.getReadUnitIds(docId);
    if (!mounted) return;
    setState(() {
      _readUnitIds.addAll(readIds);
      if (position != null && !_pageTouched) {
        final pageBefore = _initialPage;
        _applyPosition(position.chapterIndex, position.unitInChapter);
        // Re-mount the carousel only when the restored card differs
        // from where the deck already sits (card 0 on first open).
        if (_initialPage != pageBefore) _epoch++;
      }
    });
    // Record the landing card as read + current position, unless the
    // user already swiped somewhere else (their card was recorded by
    // _onCardPageChanged and is the fresher truth).
    if (_flatUnits.isNotEmpty && !_pageTouched) {
      _recordCardOnScreen(_initialPage);
    }
  }

  /// Records that the card at flat-deck [page] settled on screen:
  /// remembers it as the reading position and marks it read.
  void _recordCardOnScreen(int page) {
    if (page < 0 || page >= _flatUnits.length) return;
    final chapter = _chapterOf(page);
    final unit = _flatUnits[page];
    if (!_readUnitIds.contains(unit.id)) {
      setState(() => _readUnitIds.add(unit.id));
      BarrioReadingProgressService.markCardRead(widget.doc.id, unit.id);
    }
    BarrioReadingProgressService.savePosition(
      widget.doc.id,
      chapter,
      page - _chapterStarts[chapter],
    );
  }

  /// Chapters whose EVERY card has been read: only these show the rail
  /// check mark (persisted, honest; replaces the session-only "viewed"
  /// check that died with the screen).
  Set<String> _fullyReadChapterIds() {
    return {
      for (final chapter in widget.doc.chapters)
        if (chapter.units.isNotEmpty &&
            chapter.units.every((u) => _readUnitIds.contains(u.id)))
          chapter.id,
    };
  }

  /// Section that owns the card at flat-deck [page].
  int _chapterOf(int page) {
    var chapter = 0;
    for (var i = 0; i < _chapterStarts.length; i++) {
      if (_chapterStarts[i] > page) break;
      chapter = i;
    }
    return chapter;
  }

  void _onCardPageChanged(int page) {
    _pageTouched = true;
    _recordCardOnScreen(page);
    final chapter = _chapterOf(page);
    if (chapter == _activeChapter) return;
    setState(() => _activeChapter = chapter);
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
      body: _TrainingDocBackground(
        docId: widget.doc.id,
        accent: accent,
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
                completedChapterIds: _fullyReadChapterIds(),
                activeAccent: accent,
                chapterMinutes: [
                  for (var i = 0; i < chapters.length; i++)
                    BarrioReadingTime.chapterMinutes(widget.doc, i),
                ],
                onChapterTap: (i) {
                  HapticFeedback.lightImpact();
                  _pageTouched = true;
                  setState(() {
                    _activeChapter = i;
                    // Jump the flat deck to the section's first card.
                    _epoch++;
                    _initialPage = _chapterStarts[i];
                  });
                  // The jumped-to card settles on screen: remember it.
                  _recordCardOnScreen(_chapterStarts[i]);
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LearningCarousel(
                  key: ValueKey('${widget.doc.id}-$_epoch'),
                  cardCount: _flatUnits.length,
                  initialPage: _initialPage,
                  onPageChanged: _onCardPageChanged,
                  accent: accent,
                  // Honest footer dots: only cards actually read on
                  // this device count (persisted read marks), not
                  // "every card" as before.
                  completedIndices: {
                    for (var i = 0; i < _flatUnits.length; i++)
                      if (_readUnitIds.contains(_flatUnits[i].id)) i,
                  },
                  cardBuilder: (context, index) {
                    return HandbookLessonCard(
                      key: ValueKey(_flatUnits[index].id),
                      unit: _flatUnits[index],
                      isCarouselMode: true,
                      highlightTerms: _highlightTerms,
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

/// Per-doc photo backdrop (2026-07-11 operator decision: every manual
/// gets a photo behind the dark scrim). The three rebuilt manuals get
/// their original curated photos back; every other doc uses the
/// category-matched photo from the existing set. The docs' own
/// extracted training images were reviewed and rejected as backdrops:
/// they are posters, diagrams, and product shots, not photography.
const Map<String, String> _kDocBackdrops = <String, String>{
  // Originals restored
  'company_handbook': 'assets/internal/barrio/handbook_bg.jpg',
  'interview_playbook': 'assets/internal/barrio/interview_bg.jpg',
  'jim_taylor_labor_model': 'assets/internal/barrio/jim_taylor_bg.jpg',
  // Service & Hospitality
  'training_strong_foundation': 'assets/internal/barrio/interview_bg.jpg',
  'training_table_manicuring': 'assets/internal/barrio/interview_bg.jpg',
  'training_three_pillars': 'assets/internal/barrio/interview_bg.jpg',
  'training_suggestive_selling': 'assets/internal/barrio/interview_bg.jpg',
  'training_general_words': 'assets/internal/barrio/interview_bg.jpg',
  // Food & Drink
  'training_tequila': 'assets/internal/barrio/home_bg.webp',
  'training_coffee': 'assets/internal/barrio/home_bg.webp',
  'training_latin_dishes': 'assets/internal/barrio/home_bg.webp',
  'training_latin_ingredients': 'assets/internal/barrio/home_bg.webp',
  'training_menu_concept': 'assets/internal/barrio/home_bg.webp',
  // A Deeper Dive
  'training_labour_cost': 'assets/internal/barrio/jim_taylor_bg.jpg',
  'training_bold_by_design': 'assets/internal/barrio/jim_taylor_bg.jpg',
  'training_mastering_metrics': 'assets/internal/barrio/jim_taylor_bg.jpg',
  // Company & Compliance
  'training_food_safety': 'assets/internal/barrio/handbook_bg.jpg',
  'training_cheers_responsibility': 'assets/internal/barrio/handbook_bg.jpg',
};

/// Full-bleed photo + heavy dark scrim + the standard accent blooms.
/// Mirrors the parked curated screens' backdrop recipe (see
/// `_HandbookPremiumBackground` in company_handbook_screen.dart) so
/// body text keeps the same legibility it had on those surfaces. Docs
/// without a mapped photo, and test environments (errorBuilder), fall
/// back to the plain premium background unchanged.
class _TrainingDocBackground extends StatelessWidget {
  final String docId;
  final Color accent;
  final Widget child;

  const _TrainingDocBackground({
    required this.docId,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final photo = _kDocBackdrops[docId];
    if (photo == null) {
      return BarrioPremiumBackground(accentColor: accent, child: child);
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final cacheWidth = (width * dpr).round();
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Image.asset(
            photo,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth > 0 ? cacheWidth : null,
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),
        // Dark scrim for text legibility: heavy at top (AppBar/hero) and
        // bottom, lighter in the center (curated-screen stops).
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
        BarrioPremiumBackground(accentColor: accent, child: child),
      ],
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
