import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../content/barrio_body_chunks.dart';
import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../search/barrio_training_search.dart';
import '../routes/barrio_preview_role.dart';
import '../routes/barrio_route_map.dart';
import '../services/barrio_bookmarks_service.dart';
import '../services/barrio_flashcard_deck.dart';
import '../services/barrio_highlight_anchors.dart';
import '../services/barrio_highlights_service.dart';
import '../services/barrio_reading_progress_service.dart';
import '../services/barrio_reading_time.dart';
import '../services/barrio_term_links.dart';
import '../services/barrio_training_deck.dart';
import '../services/barrio_web_search.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_quiz_checkpoint_card.dart';
import '../widgets/barrio_streak_tracker.dart';
import '../widgets/barrio_term_definition_sheet.dart';
import '../widgets/handbook_chapter_rail.dart';
import '../widgets/handbook_lesson_card.dart';
import '../widgets/learning_carousel.dart';
import '../widgets/training_doc_index_sheet.dart';
import '../widgets/training_doc_search_sheet.dart';
import 'barrio_flashcard_review_screen.dart';

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
  /// The section the visible card belongs to.
  ///
  /// Held in a [ValueNotifier], not plain state (perf audit A2): a card
  /// settling used to `setState` the whole screen, which re-ran
  /// [LearningCarousel]'s `cardBuilder` for every live page and with it
  /// the entire text-styling pipeline. Only the hero and the chapter
  /// rail depend on this value, so only they listen.
  final ValueNotifier<int> _activeChapter = ValueNotifier<int>(0);

  /// Cards read on THIS device, persisted across sessions ("the app
  /// remembers you", 2026-07-22). A card counts as read when it settles
  /// on screen: a fact, not a mastery claim (Metric Honesty).
  ///
  /// Same [ValueNotifier] reason as [_activeChapter]: only the rail's
  /// check marks depend on it. Each write publishes a NEW set, so
  /// listeners see a real value change; never mutate the current value
  /// in place. Writes go through [_markUnitsRead].
  final ValueNotifier<Set<String>> _readUnitIds =
      ValueNotifier<Set<String>>(const <String>{});

  /// Every content unit id of this manual, mapped to the chapters that
  /// contain it. Built once so read marks can be counted instead of
  /// re-walked. A list, not a single index, because two chapters sharing
  /// a unit id must both complete when that id is read: exactly what the
  /// old per-chapter `units.every(read)` walk did.
  late final Map<String, List<int>> _chaptersOfUnitId;

  /// Content cards of each chapter still unread, and of the whole doc.
  /// Counting down as marks land replaces the two full-document walks
  /// the old code ran on every card settle and every build (perf audit
  /// A2): finish tracking and the rail's check marks.
  late final List<int> _chapterUnread;
  late int _docUnread;

  /// Chapters whose EVERY card has been read: only these show the rail
  /// check mark (persisted, honest; replaces the session-only "viewed"
  /// check that died with the screen). Derived when [_readUnitIds]
  /// changes, never in `build`. A chapter with no units is never
  /// complete, so it never enters this set.
  Set<String> _fullyReadChapterIds = const <String>{};

  /// Write-once guard for finish tracking: the service write is already
  /// write-once, and this keeps the screen from asking again.
  bool _finishedRecorded = false;

  /// Per-chapter reading-time estimates for the rail. Fixed for the life
  /// of the screen, so it is built once instead of on every build.
  late final List<int> _chapterMinutes;

  /// Saved cards of THIS doc as 'chapter:unit' content-coordinate keys
  /// (rec #8, 2026-07-23). Loaded with the persisted state; toggles
  /// write through BarrioBookmarksService.
  final Set<String> _bookmarkKeys = {};

  /// This manual's content cards by unit id. Built once at open so
  /// turning a selection into a highlight can re-parse the right body
  /// without walking the deck.
  late final Map<String, HandbookUnit> _unitsById;

  /// Where every rendered chunk of every live card publishes what the
  /// reader has selected inside it (Kindle-style highlights, Slice B).
  /// Owned here, handed to each lesson card, dropped in dispose.
  final BarrioHighlightAnchorRegistry _anchors =
      BarrioHighlightAnchorRegistry();

  /// The reader's marked passages in THIS manual, grouped by the card
  /// they live in. Loaded with the rest of the persisted state; a new
  /// mark lands here and in storage at the same time.
  Map<String, List<BarrioHighlight>> _highlightsByUnit =
      const <String, List<BarrioHighlight>>{};

  /// The marker colour the reader used last, applied to the next mark
  /// they make. Slice B has no picker yet, so this is the stored value
  /// or the default; Slice D lets them change it.
  String _markerColor = kBarrioHighlightDefaultColor;

  /// True once the user moved the deck themselves (swipe or rail tap).
  /// The async position restore then stands down: the user's own
  /// position is fresher truth than the saved one.
  bool _pageTouched = false;

  // Continuous swiping (2026-07-11 operator request): the carousel
  // holds EVERY unit of EVERY section as one flat deck, so swiping past
  // a section's last card lands on the next section. The hero and rail
  // follow the visible card's section. A rail tap jumps in place via
  // LearningCarouselState.moveToPage (learning-screen v2, 2026-07-23):
  // no remount, so card scroll offsets survive and the entrance
  // animation runs once per screen open.
  static final RegExp _whitespace = RegExp(r'\s+');

  /// The three TERM glossaries that get the A-Z jump index (rec #6,
  /// 2026-07-23). Narrative manuals show no index icon.
  static const Set<String> _kTermManualIds = <String>{
    'training_latin_ingredients',
    'training_latin_dishes',
    'training_general_words',
  };

  /// The flat card deck: every chapter's verbatim content cards, then
  /// that chapter's quick-check quiz cards when the doc has a bank
  /// (rec #4b, 2026-07-23). Quiz cards append AFTER content within a
  /// chapter, so every pre-quiz content coordinate (search, A-Z index,
  /// resume, read marks) still resolves to the same content card.
  late final TrainingDeck _deck;
  late final List<int> _chapterStarts;

  /// This session's first pick per quiz question id. Session-only and
  /// honest: no scores, streaks, or mastery claims (Metric Honesty).
  /// Held here (not in the card) so the reveal survives paging away
  /// and back while the screen lives.
  final Map<String, int> _quizPicks = {};

  /// Folded query words highlighted inside card bodies. Seeded from the
  /// home-search deep link (if any); the in-manual search sheet
  /// replaces them when a hit is opened (rec #7, 2026-07-23).
  List<String> _highlightTerms = const [];
  final GlobalKey<LearningCarouselState> _carouselKey =
      GlobalKey<LearningCarouselState>();
  int _initialPage = 0;

  /// The plain text of the reader's current text selection (select-any-
  /// word-to-search, 2026-07-29). The reading deck is wrapped in a
  /// [SelectionArea]; its onSelectionChanged keeps this current so the
  /// selection menu's "Search the web" action can read the highlighted
  /// words. Null or empty means nothing is selected.
  String? _selectedText;

  /// Handle on the reader's [SelectionArea] so the tap-away listener can
  /// clear a lingering highlight (2026-07-31 operator report).
  final GlobalKey<SelectionAreaState> _selectionKey =
      GlobalKey<SelectionAreaState>();

  late final AnimationController _heroController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _heroFade =
      CurvedAnimation(parent: _heroController, curve: Curves.easeOutCubic);
  bool _heroMotionDecided = false;

  /// True when the caller supplied an explicit deep link (search or the
  /// home Continue Reading card). Deep links always win over resume.
  bool get _hasDeepLink =>
      widget.initialChapterIndex != null || widget.initialUnitInChapter != null;

  @override
  void initState() {
    super.initState();
    final chapters = widget.doc.chapters;
    _deck = buildTrainingDeck(widget.doc);
    _chapterStarts = _deck.chapterStarts;
    _indexUnits(chapters);
    _chapterMinutes = <int>[
      for (var i = 0; i < chapters.length; i++)
        BarrioReadingTime.chapterMinutes(widget.doc, i),
    ];
    if (chapters.isNotEmpty && _hasDeepLink) {
      _applyPosition(
        widget.initialChapterIndex ?? 0,
        widget.initialUnitInChapter ?? 0,
      );
    }
    _loadPersistedState();
    _highlightTerms = _foldQueryWords(widget.highlightQuery);
    // Honest streak (rec #10): opening a manual is the activity fact
    // the streak counts. Idempotent per day; fire and forget.
    BarrioStreakService.recordActivity();
  }

  /// Builds the unit-id index and the unread counters the rail check
  /// marks and finish tracking read (perf audit A2). One pass at open,
  /// instead of a full-document walk on every settle and every build.
  void _indexUnits(List<HandbookChapter> chapters) {
    _chaptersOfUnitId = <String, List<int>>{};
    _unitsById = <String, HandbookUnit>{};
    _chapterUnread = List<int>.filled(chapters.length, 0);
    for (var c = 0; c < chapters.length; c++) {
      final seen = <String>{};
      for (final unit in chapters[c].units) {
        _unitsById[unit.id] = unit;
        // A repeated id inside one chapter is one card's worth of
        // coverage, matching the old `units.every(read)` test.
        if (!seen.add(unit.id)) continue;
        (_chaptersOfUnitId[unit.id] ??= <int>[]).add(c);
        _chapterUnread[c]++;
      }
    }
    _docUnread = _chaptersOfUnitId.length;
  }

  /// Folds a raw query into the per-word highlight terms the lesson
  /// cards mark (case- and diacritic-insensitive; empty = none).
  static List<String> _foldQueryWords(String? query) {
    final trimmed = query?.trim();
    if (trimmed == null || trimmed.isEmpty) return const [];
    return BarrioTrainingSearch.fold(trimmed)
        .split(_whitespace)
        .where((w) => w.isNotEmpty)
        .toList();
  }

  /// Clamps and applies a (chapter, unit-in-chapter) position to
  /// [_activeChapter] and [_initialPage].
  void _applyPosition(int chapterIndex, int unitInChapter) {
    final chapters = widget.doc.chapters;
    if (chapters.isEmpty) return;
    final active = chapterIndex.clamp(0, chapters.length - 1);
    _activeChapter.value = active;
    final unitCount = chapters[active].units.length;
    final unit = unitCount == 0 ? 0 : unitInChapter.clamp(0, unitCount - 1);
    _initialPage = _chapterStarts[active] + unit;
  }

  /// Loads the saved read marks (always) and, when the caller supplied
  /// no deep link, the saved reading position. Non-blocking: the
  /// carousel mounts immediately (first-ever open keeps section 0 card
  /// 0, deep links keep their target) and moves in place to the saved
  /// card when the restore lands, unless the user already moved the
  /// deck. A platform without a working preferences store simply never
  /// resolves or returns empty: the screen behaves exactly as before
  /// this slice.
  Future<void> _loadPersistedState() async {
    final docId = widget.doc.id;
    final position = _hasDeepLink
        ? null
        : await BarrioReadingProgressService.getPosition(docId);
    final readIds = await BarrioReadingProgressService.getReadUnitIds(docId);
    final savedKeys = await BarrioBookmarksService.localKeysFor(docId);
    // Kindle-style highlights (Slice B): the reader's own marks and the
    // marker colour they last used, loaded alongside every other
    // device-local reading fact. A store that never answers simply
    // leaves the manual unmarked.
    final highlights = await BarrioHighlightsService.getForDoc(docId);
    final markerColor = await BarrioHighlightsService.getLastColor();
    if (!mounted) return;
    final restore = position != null && !_pageTouched;
    _markUnitsRead(readIds);
    setState(() {
      _bookmarkKeys.addAll(savedKeys);
      _markerColor = markerColor;
      _highlightsByUnit = _groupByUnit(highlights);
      if (restore) {
        _applyPosition(position.chapterIndex, position.unitInChapter);
      }
    });
    if (restore) {
      // Move the mounted deck in place (no remount, offsets survive).
      // If the carousel has not laid out yet it will mount at
      // _initialPage, so the move is a safe no-op either way.
      _carouselKey.currentState?.moveToPage(_initialPage);
    }
    // Record the landing card as read + current position, unless the
    // user already swiped somewhere else (their card was recorded by
    // _onCardPageChanged and is the fresher truth).
    if (_deck.entries.isNotEmpty && !_pageTouched) {
      _recordCardOnScreen(_initialPage);
    }
    // Upgrade path (spaced refresher, rec #11): a manual fully read
    // before finish tracking existed gets its finishedAt recorded on
    // the next open, from the persisted read marks just loaded.
    _maybeRecordFinished();
  }

  /// Records that the card at flat-deck [page] settled on screen:
  /// remembers it as the reading position and marks it read. Quiz
  /// cards record NOTHING: they are not content cards, so read-mark
  /// totals keep meaning content cards only and the saved position
  /// stays on the last settled content card (Metric Honesty).
  void _recordCardOnScreen(int page) {
    if (page < 0 || page >= _deck.length) return;
    final unit = _deck.entries[page].unit;
    if (unit == null) return; // Quick-check quiz card: never recorded.
    final chapter = _chapterOf(page);
    if (!_readUnitIds.value.contains(unit.id)) {
      _markUnitsRead(<String>[unit.id]);
      BarrioReadingProgressService.markCardRead(widget.doc.id, unit.id);
    }
    BarrioReadingProgressService.savePosition(
      widget.doc.id,
      chapter,
      page - _chapterStarts[chapter],
    );
    _maybeRecordFinished();
  }

  /// Records [ids] as read and republishes [_readUnitIds].
  ///
  /// Ids that are not content cards of THIS manual are ignored: they can
  /// only come from a persisted mark whose card no longer exists, and
  /// they never counted toward completion before either. Everything the
  /// rail and finish tracking need is updated here, BEFORE the notifier
  /// publishes, so a listener always reads a consistent pair.
  void _markUnitsRead(Iterable<String> ids) {
    final current = _readUnitIds.value;
    final completed = <String>{};
    Set<String>? next;
    for (final id in ids) {
      final chapters = _chaptersOfUnitId[id];
      if (chapters == null || current.contains(id)) continue;
      next ??= <String>{...current};
      if (!next.add(id)) continue;
      _docUnread--;
      for (final c in chapters) {
        if (--_chapterUnread[c] == 0) completed.add(widget.doc.chapters[c].id);
      }
    }
    if (next == null) return;
    if (completed.isNotEmpty) {
      _fullyReadChapterIds = <String>{..._fullyReadChapterIds, ...completed};
    }
    _readUnitIds.value = next;
  }

  /// Finish tracking (spaced refresher, rec #11): once the read-mark
  /// set covers EVERY content card of this manual, record finishedAt.
  /// The service write is write-once; this guard keeps the screen from
  /// asking again, and the unread counter replaces the old
  /// whole-document walk that ran on every card settle (perf audit A2).
  /// Quiz cards are not content cards and play no part in coverage.
  void _maybeRecordFinished() {
    if (_finishedRecorded) return;
    if (_chaptersOfUnitId.isEmpty || _docUnread > 0) return;
    _finishedRecorded = true;
    BarrioReadingProgressService.recordFinished(widget.doc.id);
  }

  /// Section that owns the card at flat-deck [page]. A chapter's quiz
  /// cards belong to their own chapter (they sit before the next
  /// chapter's start), so the hero and rail follow them correctly.
  int _chapterOf(int page) => _deck.chapterOf(page);

  void _onCardPageChanged(int page) {
    _pageTouched = true;
    _recordCardOnScreen(page);
    _activeChapter.value = _chapterOf(page);
  }

  /// Jumps the deck IN PLACE to flat-deck [page] (no remount: same
  /// mechanism as rail taps). onPageChanged then records the settled
  /// card exactly as it does for swipes and tap-zone turns, so jumps
  /// leave the same read marks.
  void _jumpToCard(int page) {
    if (_deck.entries.isEmpty) return;
    final target = page.clamp(0, _deck.length - 1);
    HapticFeedback.lightImpact();
    _pageTouched = true;
    _activeChapter.value = _chapterOf(target);
    _carouselKey.currentState?.moveToPage(target);
  }

  /// Opens the in-manual search sheet (rec #7). A tapped hit closes
  /// the sheet, threads the query into the cards' highlight rendering,
  /// and jumps to the matched card. Dismissing without a tap changes
  /// nothing: the deck stays where the reader left it.
  void _openSearchSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => TrainingDocSearchSheet(
        docId: widget.doc.id,
        accent: widget.accent,
        onResultTap: (result, query) {
          Navigator.of(sheetContext).pop();
          setState(() => _highlightTerms = _foldQueryWords(query));
          _jumpToCard(_chapterStarts[result.chapterIndex] + result.unitIndex);
        },
        // An asked question that this manual answers behaves exactly
        // like a tapped hit; only the highlight terms differ (the
        // sheet sends the content terms, never the glue words).
        onAnswerTap: (answer, highlightQuery) {
          Navigator.of(sheetContext).pop();
          setState(() => _highlightTerms = _foldQueryWords(highlightQuery));
          _jumpToCard(_chapterStarts[answer.chapterIndex] + answer.unitIndex);
        },
        // The manual has no answer, so the reader leaves for the web.
        // Closing the sheet first keeps the failure SnackBar visible
        // and returns them to the manual when the browser closes.
        onWebSearchRequested: (query) {
          Navigator.of(sheetContext).pop();
          _launchWebSearch(query);
        },
      ),
    );
  }

  /// Opens the "Search the web" input (2026-07-28 operator request:
  /// let a reader look something up on Google without leaving the app).
  /// A cancelled or empty query does nothing; a non-empty query opens
  /// the Google results IN-APP (Custom Tab / SFSafariViewController) so
  /// the reader stays inside the manual reader.
  Future<void> _openWebSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => _WebSearchDialog(accent: widget.accent),
    );
    if (query == null || query.trim().isEmpty) return;
    await _launchWebSearch(query);
  }

  /// Opens the Google web search for [query] in an in-app browser view.
  /// If the launch returns false or throws, shows a plain-English
  /// SnackBar instead of crashing.
  Future<void> _launchWebSearch(String query) async {
    final uri = barrioWebSearchUri(query);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the web search.')),
    );
  }

  /// Opens ChatGPT seeded with [query] in an in-app browser view (the
  /// "Ask chat" selection action, 2026-07-29). If the launch returns
  /// false or throws, shows a plain-English SnackBar instead of crashing.
  Future<void> _launchAskChat(String query) async {
    final uri = barrioAskChatUri(query);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the chat.')),
    );
  }

  /// Groups [highlights] by the card they mark, keeping stored order
  /// (oldest first) inside each card.
  static Map<String, List<BarrioHighlight>> _groupByUnit(
    List<BarrioHighlight> highlights,
  ) {
    final grouped = <String, List<BarrioHighlight>>{};
    for (final highlight in highlights) {
      (grouped[highlight.unitId] ??= <BarrioHighlight>[]).add(highlight);
    }
    return grouped;
  }

  /// Marks the reader's current selection (Kindle-style highlights,
  /// Slice B), in the marker colour they used last.
  ///
  /// The selection can span several paragraphs, bullets, or table cells,
  /// so the anchor registry reports one segment per rendered chunk it
  /// touched and they become one highlight. Nothing selected, a
  /// whitespace-only selection, or a card this manual no longer holds
  /// does nothing at all. The mark paints immediately and is written to
  /// the device store after; a store that cannot write leaves the mark
  /// on screen for this session and says nothing, exactly like every
  /// other reading fact this screen keeps.
  Future<void> _highlightSelection(SelectableRegionState region) async {
    final unitId = _anchors.selectedUnitId();
    final unit = unitId == null ? null : _unitsById[unitId];
    final segments = unit == null
        ? const <BarrioHighlightSegment>[]
        : _anchors.selectionSegments(unit.id, chunksForBody(unit.body));
    region.hideToolbar();
    _selectionKey.currentState?.selectableRegion.clearSelection();
    _selectedText = null;
    if (unit == null || segments.isEmpty) return;

    final highlight = BarrioHighlight.create(
      unitId: unit.id,
      segments: segments,
      color: _markerColor,
    );
    HapticFeedback.lightImpact();
    setState(() {
      _highlightsByUnit = <String, List<BarrioHighlight>>{
        ..._highlightsByUnit,
        unit.id: <BarrioHighlight>[
          ...?_highlightsByUnit[unit.id],
          highlight,
        ],
      };
    });
    await BarrioHighlightsService.add(widget.doc.id, highlight);
    await BarrioHighlightsService.setLastColor(highlight.color);
  }

  /// Builds the reading text selection menu (select-any-word action,
  /// 2026-07-29 operator curation: no Copy/Select all). "Highlight"
  /// marks the selection in the reader's last marker colour, "Ask chat"
  /// opens ChatGPT and "Search the web" opens Google, the latter two
  /// seeded with the highlighted words in the in-app browser through the
  /// same launch paths the surface uses elsewhere. Each action dismisses
  /// the menu first; an empty or whitespace-only selection does nothing.
  Widget _buildSelectionContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final anchors = selectableRegionState.contextMenuAnchors;
    void run(void Function(String) launch) {
      final selection = _selectedText?.trim() ?? '';
      selectableRegionState.hideToolbar();
      if (selection.isEmpty) return;
      launch(selection);
    }

    // Branded selection menu (2026-07-31 operator request): the default
    // AdaptiveTextSelectionToolbar renders a generic light-cream system
    // popup that reads as off-brand next to the premium reader. This is
    // the same two actions on the Barrio glass surface, with the manual
    // accent glyphs and IBM Plex labels, floated at the selection anchor
    // (TextSelectionToolbar owns the above/below overflow placement; the
    // toolbarBuilder swaps the container for our own).
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      toolbarBuilder: (context, child) => _BarrioSelectionSurface(child: child),
      children: <Widget>[
        // Highlight leads: marking what you just read is the reading
        // action, and the other two send the reader out of the manual.
        _BarrioSelectionAction(
          icon: Icons.border_color_rounded,
          label: 'Highlight',
          accent: widget.accent,
          onPressed: () => _highlightSelection(selectableRegionState),
        ),
        _BarrioSelectionAction(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'Ask chat',
          accent: widget.accent,
          onPressed: () => run(_launchAskChat),
        ),
        _BarrioSelectionAction(
          icon: Icons.travel_explore_rounded,
          label: 'Search the web',
          accent: widget.accent,
          onPressed: () => run(_launchWebSearch),
        ),
      ],
    );
  }

  /// The reading deck, wrapped in the text-selection plumbing.
  ///
  /// Select-any-word-to-search (2026-07-29 operator request): the whole
  /// deck is a text selection region, so a reader can long-press an
  /// unfamiliar word (for example a Spanish term like 'Amatitan') to
  /// select it and then pick "Search the web" from the selection menu.
  /// Selection is a long-press or drag gesture; every reading gesture
  /// still works because each lives on a recognizer deeper than this
  /// region: a plain tap still turns the page (the carousel edge tap
  /// zones), a clearly horizontal swipe still moves between cards, a
  /// near-vertical drag still scrolls a long card, term-link taps still
  /// open the definition popover, and an image tap still zooms.
  Widget _buildSelectableDeck(Color accent) {
    return SelectionArea(
      key: _selectionKey,
      onSelectionChanged: (content) => _selectedText = content?.plainText,
      contextMenuBuilder: _buildSelectionContextMenu,
      // Tap-away clears the highlight (2026-07-31 operator report: a
      // selection stuck around after tapping elsewhere). The carousel's
      // deeper recognizers (page turn, term links, image zoom) win the
      // gesture arena, so SelectionArea never receives the winning tap; a
      // raw pointer listener sits outside the arena and always fires.
      // Selection gestures still work: the pointer-down that begins a
      // long-press or drag clears the previous highlight, then forms the
      // new one. The floating menu and drag handles live in the app
      // overlay, not this subtree, so using them never lands here.
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if ((_selectedText ?? '').isEmpty) return;
          _selectionKey.currentState?.selectableRegion.clearSelection();
          _selectedText = null;
        },
        child: LearningCarousel(
          key: _carouselKey,
          cardCount: _deck.length,
          initialPage: _initialPage,
          onPageChanged: _onCardPageChanged,
          accent: accent,
          cardBuilder: _buildDeckCard,
        ),
      ),
    );
  }

  /// Opens the A-Z term index sheet (rec #6; TERM manuals only).
  void _openIndexSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => TrainingDocIndexSheet(
        doc: widget.doc,
        accent: widget.accent,
        onEntryTap: (page) {
          Navigator.of(sheetContext).pop();
          // The index sheet emits pages in the pre-quiz content
          // flatten; convert so entries land on the same content card
          // with quiz cards present (identity for docs without a bank).
          _jumpToCard(_deck.deckPageForContentPage(page));
        },
      ),
    );
  }

  /// Pushes the flashcard review screen scoped to THIS manual only
  /// (visual-first pass, rec #6: the glossaries' picture-first review
  /// surface gets an entry inside the manual itself, not just the home
  /// shelf pills). Deck material is only the three glossary manuals;
  /// [barrioFlashcardDeckForManual] returns null for anything else, so
  /// narrative manuals never reach here (the chip is not rendered).
  void _openFlashcards() {
    final deck = barrioFlashcardDeckForManual(
      widget.doc.id,
      title: widget.doc.title,
    );
    if (deck == null) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BarrioFlashcardReviewScreen(
          deck: deck,
          accent: widget.accent,
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_heroMotionDecided) return;
    _heroMotionDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility (rec #12): reduce motion lands the hero settled.
      _heroController.value = 1.0;
    } else {
      _heroController.forward();
    }
  }

  @override
  void dispose() {
    _heroController.dispose();
    _activeChapter.dispose();
    _readUnitIds.dispose();
    // Every chunk's selection notifier. Flutter unmounts children before
    // their ancestors, so each card's SelectionListener has already
    // detached by the time this runs.
    _anchors.dispose();
    // On the culinary manuals this screen hands `_openTermSheet` to every
    // lesson card, and the memoized body spans key on that callback and
    // close over it. Dropping them here is what keeps a popped reader (and
    // its element tree) from staying reachable through a process-lifetime
    // cache. See [barrioClearBodySpanCache].
    barrioClearBodySpanCache();
    super.dispose();
  }

  /// One deck card: a verbatim content card, or a chapter-end
  /// quick-check quiz card (rec #4b) when the slot holds a question.
  /// Content cards carry the bookmark toggle (rec #8; quiz cards are
  /// never bookmarkable) and, on the culinary host manuals only, the
  /// tap-to-define term links (rec #9).
  Widget _buildDeckCard(BuildContext context, int index) {
    final entry = _deck.entries[index];
    final question = entry.question;
    if (question != null) {
      return BarrioQuizCheckpointCard(
        key: ValueKey('quiz_${question.id}'),
        question: question,
        selectedIndex: _quizPicks[question.id],
        onOptionSelected: (option) {
          // First pick only: options lock after reveal.
          if (_quizPicks.containsKey(question.id)) return;
          setState(() => _quizPicks[question.id] = option);
        },
      );
    }
    final chapter = _chapterOf(index);
    final unitInChapter = index - _chapterStarts[chapter];
    final localKey = '$chapter:$unitInChapter';
    return HandbookLessonCard(
      key: ValueKey(entry.unit!.id),
      unit: entry.unit!,
      isCarouselMode: true,
      highlightTerms: _highlightTerms,
      bookmarked: _bookmarkKeys.contains(localKey),
      onBookmarkTap: () => _toggleBookmark(chapter, unitInChapter),
      onTermTap: BarrioTermLinks.kHostManualIds.contains(widget.doc.id)
          ? _openTermSheet
          : null,
      // Kindle-style highlights (Slice B): this card's own marks to
      // paint, and the registry every chunk reports its selection to.
      highlights: _highlightsByUnit[entry.unit!.id] ??
          const <BarrioHighlight>[],
      anchorRegistry: _anchors,
    );
  }

  /// Saves or unsaves the content card at (chapter, unitInChapter),
  /// content coordinates (quiz-stable per the #1483 deck contract).
  void _toggleBookmark(int chapter, int unitInChapter) {
    final localKey = '$chapter:$unitInChapter';
    final saved = _bookmarkKeys.contains(localKey);
    setState(() {
      if (saved) {
        _bookmarkKeys.remove(localKey);
      } else {
        _bookmarkKeys.add(localKey);
      }
    });
    if (saved) {
      BarrioBookmarksService.remove(widget.doc.id, chapter, unitInChapter);
    } else {
      BarrioBookmarksService.add(widget.doc.id, chapter, unitInChapter);
    }
  }

  /// Opens the tap-to-define definition sheet for a linked TERM
  /// (rec #9). 'Open in manual' closes the sheet and pushes the TERM
  /// glossary at the term's own card.
  void _openTermSheet(BarrioTermCard card) {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => BarrioTermDefinitionSheet(
        card: card,
        accent: widget.accent,
        onOpenInManual: () {
          Navigator.of(sheetContext).pop();
          _openTermManual(card);
        },
      ),
    );
  }

  void _openTermManual(BarrioTermCard card) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BarrioRouteMap.screenFor(
          card.docId,
          previewRole: widget.previewRole,
          initialChapterIndex: card.chapterIndex,
          initialUnitInChapter: card.unitInChapter,
        ),
      ),
    );
  }

  /// The hero, rebuilt only when the active section changes (perf audit
  /// A2): it listens to [_activeChapter] instead of riding the screen's
  /// own build, so a card settling never touches the carousel subtree.
  Widget _buildHero(List<HandbookChapter> chapters, Color accent) {
    return ValueListenableBuilder<int>(
      valueListenable: _activeChapter,
      builder: (context, activeChapter, _) => _TrainingHero(
        chapter: chapters[activeChapter],
        accent: accent,
        sectionIndex: activeChapter,
        sectionCount: chapters.length,
        // Structure pass: the doc-level depth-framing badge word
        // (e.g. 'DEEPER DIVE') rides the hero eyebrow so the reader
        // sees the manual's framing in its header. Null for every
        // manual without one.
        depthBadge: widget.doc.depthBadge,
        // Glossary manuals only: the flashcard chip rides the hero's
        // eyebrow row (no new persistent chrome).
        onFlashcardsTap: kBarrioFlashcardManualIds.contains(widget.doc.id)
            ? _openFlashcards
            : null,
      ),
    );
  }

  /// The chapter rail, rebuilt only when the active section or the read
  /// marks change (perf audit A2). Both are notifiers, so neither a
  /// swipe nor a new read mark rebuilds the deck below.
  Widget _buildChapterRail(List<HandbookChapter> chapters, Color accent) {
    return ValueListenableBuilder<int>(
      valueListenable: _activeChapter,
      builder: (context, activeChapter, _) =>
          ValueListenableBuilder<Set<String>>(
        valueListenable: _readUnitIds,
        builder: (context, _, __) => HandbookChapterRail(
          chapters: chapters,
          activeIndex: activeChapter,
          completedChapterIds: _fullyReadChapterIds,
          activeAccent: accent,
          chapterMinutes: _chapterMinutes,
          onChapterTap: _onChapterTap,
        ),
      ),
    );
  }

  void _onChapterTap(int index) {
    HapticFeedback.lightImpact();
    _pageTouched = true;
    _activeChapter.value = index;
    // Move the deck in place to the section's first card (no remount:
    // scroll offsets and the entrance animation survive). onPageChanged
    // records the settled card exactly as it does for swipes.
    _carouselKey.currentState?.moveToPage(_chapterStarts[index]);
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.doc.chapters;
    final accent = widget.accent;

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: widget.doc.title,
        accentColor: accent,
        // Chrome diet holds: two quiet icons in the existing bar, no
        // new persistent chrome. The A-Z index shows only on the three
        // TERM glossaries.
        trailing: _HeaderActions(
          onSearchTap: _openSearchSheet,
          onWebSearchTap: _openWebSearch,
          onIndexTap: _kTermManualIds.contains(widget.doc.id)
              ? _openIndexSheet
              : null,
        ),
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
                child: _buildHero(chapters, accent),
              ),
              const SizedBox(height: 8),
              _buildChapterRail(chapters, accent),
              const SizedBox(height: 8),
              Expanded(child: _buildSelectableDeck(accent)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The header's quiet navigation icons: search-this-manual and
/// search-the-web on every manual, plus the A-Z term index only when
/// [onIndexTap] is provided (TERM manuals).
class _HeaderActions extends StatelessWidget {
  final VoidCallback onSearchTap;
  final VoidCallback onWebSearchTap;
  final VoidCallback? onIndexTap;

  const _HeaderActions({
    required this.onSearchTap,
    required this.onWebSearchTap,
    this.onIndexTap,
  });

  @override
  Widget build(BuildContext context) {
    // Bigger, easier-to-hit header actions (2026-07-29 operator request):
    // the icons step up from 22 to 28 so the two search glyphs read more
    // clearly, while explicit 48x48 constraints keep a comfortable tap
    // target. The A-Z index (TERM manuals only) grows with them so all
    // three stay a matched set. Three 48px buttons still fit the bar with
    // room for the title at phone width, so nothing crowds or overflows.
    const double kIconSize = 28;
    const BoxConstraints kTapTarget =
        BoxConstraints(minWidth: 48, minHeight: 48);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Search this manual',
          onPressed: onSearchTap,
          iconSize: kIconSize,
          constraints: kTapTarget,
          icon: const Icon(
            Icons.search_rounded,
            color: BarrioColors.textSecondary,
          ),
        ),
        // Search the web (2026-07-28): a globe-with-magnifier icon,
        // distinct from the in-manual magnifier above, so the reader can
        // look something up on Google without leaving the app. Opens an
        // in-app browser view, not an external browser.
        IconButton(
          tooltip: 'Search the web',
          onPressed: onWebSearchTap,
          iconSize: kIconSize,
          constraints: kTapTarget,
          icon: const Icon(
            Icons.travel_explore_rounded,
            color: BarrioColors.textSecondary,
          ),
        ),
        if (onIndexTap != null)
          IconButton(
            tooltip: 'Jump to a term',
            onPressed: onIndexTap,
            iconSize: kIconSize,
            constraints: kTapTarget,
            icon: const Icon(
              Icons.sort_by_alpha_rounded,
              color: BarrioColors.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// Simple "Search the web" input on the light Barrio surface. One text
/// field plus Cancel and Search. Owns its own controller so the field
/// disposes cleanly. Pops the trimmed query on Search (or on keyboard
/// submit) when it is non-empty; pops null on Cancel. An empty query
/// keeps the button inert so nothing opens.
class _WebSearchDialog extends StatefulWidget {
  final Color accent;

  const _WebSearchDialog({required this.accent});

  @override
  State<_WebSearchDialog> createState() => _WebSearchDialogState();
}

class _WebSearchDialogState extends State<_WebSearchDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return Dialog(
      backgroundColor: BarrioColors.shellMid,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BarrioRadii.sheet),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row: the same globe-with-magnifier glyph the header
            // action carries, in the manual accent, beside a Playfair
            // header so the popup reads as part of the premium reader.
            Row(
              children: [
                Icon(Icons.travel_explore_rounded, size: 20, color: accent),
                const SizedBox(width: 10),
                Text(
                  'Search the web',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: BarrioColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Opens Google results inside the app.',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 12.5,
                height: 1.4,
                color: BarrioColors.textMuted,
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              style: GoogleFonts.ibmPlexSans(
                fontSize: 15,
                color: BarrioColors.textPrimary,
              ),
              cursorColor: accent,
              decoration: InputDecoration(
                hintText: 'Search the web',
                hintStyle: GoogleFonts.ibmPlexSans(
                  fontSize: 15,
                  color: BarrioColors.textMuted,
                ),
                filled: true,
                fillColor: BarrioColors.shellSurface,
                isDense: true,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: BarrioColors.textMuted,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(BarrioRadii.card),
                  borderSide: BorderSide(
                    color: BarrioColors.textMuted.withValues(alpha: 0.25),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(BarrioRadii.card),
                  borderSide: BorderSide(color: accent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: BarrioColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                _SearchActionButton(accent: accent, onTap: _submit),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The dialog's primary action: a filled teal-accent "Search" button so
/// the search action reads as the clear next step (the old plain text
/// button sat flat against the surface). A luminance-picked foreground
/// keeps the label legible on any manual accent, matching the reader's
/// flashcard chip treatment.
class _SearchActionButton extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _SearchActionButton({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onAccent = barrioOnAccent(accent);
    return Material(
      color: accent,
      // Matches the search field it sits beside: adjacent surfaces on
      // different rungs is the tell this sweep removes.
      borderRadius: BorderRadius.circular(BarrioRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_forward_rounded, size: 16, color: onAccent),
              const SizedBox(width: 5),
              Text(
                'Search',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: onAccent,
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

/// Full-bleed photo + heavy cream veil + the standard accent blooms.
/// Mirrors the parked curated screens' backdrop recipe (see
/// `_HandbookPremiumBackground` in company_handbook_screen.dart) so
/// body text keeps the same legibility it had on those surfaces. The
/// veil uses the cream shell color at high alpha, so the reader stays a
/// light surface with only a faint photo texture behind it. Docs
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Image.asset(
            photo,
            fit: BoxFit.cover,
            cacheWidth:
                barrioCacheWidth(context, MediaQuery.sizeOf(context).width),
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),
        // Cream veil for text legibility: heavy at top (AppBar/hero) and
        // bottom, lighter in the center (curated-screen stops). Uses the
        // cream shell color, so the surface reads light.
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

  /// Doc-level depth-framing badge word (e.g. 'DEEPER DIVE'). Null (the
  /// default) renders no badge. Operator-approved wording only.
  final String? depthBadge;

  /// Non-null only on the glossary manuals: renders the prominent
  /// "Review as flashcards" chip on the eyebrow row.
  final VoidCallback? onFlashcardsTap;

  const _TrainingHero({
    required this.chapter,
    required this.accent,
    required this.sectionIndex,
    required this.sectionCount,
    this.depthBadge,
    this.onFlashcardsTap,
  });

  @override
  Widget build(BuildContext context) {
    // Learning-screen v2 chrome diet: eyebrow + one-line title + thin
    // progress bar only. The 'N cards' subtitle went (the footer's
    // 'X of N' already counts cards) and the title never wraps, so the
    // card window below keeps one steady height mid-session. The
    // flashcard chip (glossaries only) shares the eyebrow row, so the
    // hero height stays steady with or without it mid-session.
    //
    // Accessibility pass (rec #12): screen readers get one merged
    // header carrying the FULL section title even when the visible
    // one-line title ellipsizes (the header rides the eyebrow so the
    // flashcards chip keeps its own tappable node), and the title's
    // text scaling is CLAMPED at 1.45x. Clamp rationale (documented
    // per the WCAG 1.4.4 "no loss of content or function" bar): the
    // one-line cap is a deliberate v2 decision keeping the card window
    // height steady mid-session; letting a 26px Playfair title scale
    // to 2.0x would ellipsize almost every section title into
    // meaninglessness, while at 1.45x the common titles still fit. The
    // full title stays available in the header semantics label and on
    // the rail tile labels, so no content is lost at any scale.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Semantics(
                  header: true,
                  label: 'Section ${sectionIndex + 1} of $sectionCount: '
                      '${chapter.title}',
                  child: ExcludeSemantics(
                    child: Text(
                      'SECTION ${sectionIndex + 1} OF $sectionCount',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.2,
                        color: accent.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (depthBadge != null) ...[
                _DepthBadge(accent: accent, label: depthBadge!),
                if (onFlashcardsTap != null) const SizedBox(width: 8),
              ],
              if (onFlashcardsTap != null)
                _FlashcardsChip(accent: accent, onTap: onFlashcardsTap!),
            ],
          ),
          // Part separator (structure pass): long manuals grouped into
          // named parts show 'PART k OF n: Name' above the section title
          // so the reader sees which part of the manual they are in.
          // Only manuals with part grouping carry these fields, so the
          // hero height stays steady within any one manual.
          if (chapter.partTitle != null) ...[
            const SizedBox(height: 5),
            _PartLabel(
              accent: accent,
              partIndex: chapter.partIndex!,
              partCount: chapter.partCount!,
              partTitle: chapter.partTitle!,
            ),
          ],
          const SizedBox(height: 6),
          // Excluded from semantics: the header label above already
          // carries the full title and position (rec #12).
          ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.45,
                  child: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: BarrioColors.textPrimary,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
          ),
        ],
      ),
    );
  }
}

/// Prominent "Review as flashcards" chip on the hero eyebrow row
/// (glossary manuals only). Bumped up from the old quiet outline pill
/// (2026-07-26 operator request "flash cards button bigger and more
/// prominent in places where it exists"): a solid accent fill with a
/// soft accent glow, dark high-contrast text, and a larger tap target,
/// so the picture-first review mode clearly invites a tap. The visible
/// word stays 'FLASHCARDS'; the full "Review as flashcards" name rides
/// the semantics label. Kept overflow-safe: the eyebrow's section
/// counter is Flexible and ellipsizes, so the wider chip never wraps or
/// overflows the hero row.
class _FlashcardsChip extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _FlashcardsChip({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Luminance-picked foreground so the label stays legible on any
    // manual accent (white on dark accents, near-black on bright ones).
    final onAccent = barrioOnAccent(accent);
    return Semantics(
      button: true,
      label: 'Review as flashcards',
      child: GestureDetector(
        key: const ValueKey<String>('training_doc_flashcards_chip'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(BarrioRadii.chip),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.35),
                blurRadius: 12,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.style_rounded,
                size: 16,
                color: onAccent,
              ),
              const SizedBox(width: 5),
              Text(
                'FLASHCARDS',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: onAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Doc-level depth-framing badge on the hero eyebrow (structure pass).
/// A quiet bordered pill carrying an operator-approved word (e.g.
/// 'DEEPER DIVE') so the reader sees the manual is optional-depth
/// material, not core training. Data only invents nothing: the word
/// comes from [BarrioTrainingDoc.depthBadge].
class _DepthBadge extends StatelessWidget {
  final Color accent;
  final String label;

  const _DepthBadge({required this.accent, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label material',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(BarrioRadii.chip),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_stories_rounded, size: 13, color: accent),
              const SizedBox(width: 5),
              Text(
                label,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Part separator line on the hero (structure pass). Long manuals
/// grouped into named parts show 'PART k OF n: Name' above the section
/// title. The 'PART k OF n' prefix is the label and the part name is the
/// value, joined by a colon (UX no-em-dash law). The full text rides one
/// screen-reader node; the visible line ellipsizes on narrow screens
/// while the label keeps the whole name.
class _PartLabel extends StatelessWidget {
  final Color accent;
  final int partIndex;
  final int partCount;
  final String partTitle;

  const _PartLabel({
    required this.accent,
    required this.partIndex,
    required this.partCount,
    required this.partTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Part $partIndex of $partCount: $partTitle',
      child: ExcludeSemantics(
        child: Text(
          'PART $partIndex OF $partCount: $partTitle',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: accent.withValues(alpha: 0.80),
          ),
        ),
      ),
    );
  }
}

/// The branded container for the reading-text selection menu (2026-07-31).
/// Replaces the system toolbar's generic light-cream card with the Barrio
/// glass surface, rounded corners and the one soft neutral lift, so the
/// popup reads as part of the premium reader (matches the web-search
/// dialog surface). [TextSelectionToolbar] hands us the arranged action
/// row as [child]; we only own the frame around it.
class _BarrioSelectionSurface extends StatelessWidget {
  final Widget child;

  const _BarrioSelectionSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BarrioColors.glassFill,
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(
          color: BarrioColors.textPrimary.withValues(alpha: 0.06),
        ),
        boxShadow: barrioSoftShadow(y: 8, blur: 22, opacity: 0.14),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// One action inside the branded selection menu: the manual accent glyph
/// beside an IBM Plex label, sized to a comfortable 44px tap target.
///
/// The horizontal padding is deliberately tight, and that is a fix, not
/// a preference. [TextSelectionToolbar] does not wrap: an action that
/// does not fit on one row is pushed behind an overflow chevron, where a
/// reader will not look for it. Two actions fit at the roomier 16px
/// padding; adding Highlight made three, and at 16px "Search the web"
/// fell off a 390dp phone entirely. At 6px horizontal with a 5px glyph
/// gap the three measure 94.8 + 91.8 + 136.9 = 323.4 of the 344 a 360dp
/// phone gives, the narrowest the reader supports.
/// `barrio_highlight_reader_test.dart` holds that at 360dp, so a fourth
/// action (Slice D's colour dots) has to solve the row rather than
/// silently hide something.
class _BarrioSelectionAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onPressed;

  const _BarrioSelectionAction({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: BarrioColors.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        minimumSize: const Size(0, 44),
        shape: const RoundedRectangleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: BarrioColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
