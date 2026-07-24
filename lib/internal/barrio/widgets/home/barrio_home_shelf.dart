// Barrio home revision (2026-07-11, operator decision): one-scroll
// round-bubble layout. Keeps the Editorial Shelf's single-vertical-
// scroll organization (Barrio Home Redesign V1, plan:
// docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md)
// but composes the parked orbit hub's round glass bubbles instead of
// the rectangular hero/topic cards (which stay on disk, hide-only).
//
// Layout (single vertical scroll, no horizontal scrolling, no tabs):
//   1. Caller-provided leading widgets (brand header, gated El Podio).
//   2. Forge & Flow as the hub's center bubble (160px, centered, with
//      the rotating arc + glow pulse + 'Dashboard' label).
//   3. Four fixed-order category sections, each rendering its
//      destinations as round hub-style bubbles, 3 per row with the last
//      partial row centered, built by filtering on
//      `BarrioDestination.category`.
//   4. 40px footer padding.
//
// Motion: a single one-time entrance (staggered fade + slide) plus the
// bubbles' own looping glow/arc effects (operator decision overriding
// the redesign plan's motion rule). `MediaQuery.disableAnimations`
// skips the entrance and freezes the bubble loops.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../content/quiz/barrio_quiz_models.dart';
import '../../content/training/barrio_training_doc.dart';
import '../../content/training/training_docs.dart';
import '../../routes/barrio_destination_visibility_resolver.dart';
import '../../routes/barrio_destinations.dart';
import '../../routes/barrio_preview_role.dart';
import '../../screens/barrio_flashcard_review_screen.dart';
import '../../screens/barrio_quiz_refresher_screen.dart';
import '../../services/barrio_bookmarks_service.dart';
import '../../services/barrio_flashcard_deck.dart';
import '../../services/barrio_reading_progress_service.dart';
import '../../services/barrio_reading_time.dart';
import '../../services/barrio_refresher_scheduler.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_bubble.dart';
import 'barrio_home_destination_visuals.dart';

/// One category section: operator-facing title + section accent +
/// category filter. Section membership is driven by the
/// `BarrioDestination.category` field, never by hardcoded id lists.
class _ShelfSection {
  final String title;
  final BarrioCategory category;
  final Color accent;

  const _ShelfSection(this.title, this.category, this.accent);
}

/// Fixed section order with the operator-facing titles and section
/// accents from the redesign plan's category model.
/// 2026-07-11 operator revision: Company & Compliance leads, and the
/// numbers section's display title is 'A Deeper Dive' (the
/// BarrioCategory.numbersAndLabor identifier is unchanged).
const List<_ShelfSection> _kShelfSections = <_ShelfSection>[
  _ShelfSection(
    'Company & Compliance',
    BarrioCategory.companyAndCompliance,
    BarrioColors.accentHandbook,
  ),
  _ShelfSection(
    'Service & Hospitality',
    BarrioCategory.serviceHospitality,
    BarrioColors.accentPlaybook,
  ),
  _ShelfSection(
    'Food & Drink',
    BarrioCategory.foodAndDrink,
    BarrioColors.gold,
  ),
  _ShelfSection(
    'A Deeper Dive',
    BarrioCategory.numbersAndLabor,
    BarrioColors.accentJimTaylor,
  ),
];

/// Center-bubble diameter (the hub's primary node was 150; the operator
/// spec allows 150-170 for the scrolling composition).
const double _kCenterBubbleDiameter = 160.0;

/// Section bubble diameter and swipe-row height (glow halos need the
/// extra vertical room so they never clip against the row bounds).
const double _kBubbleDiameter = 100.0;
const double _kSectionRowHeight = 150.0;

/// Quiet metadata zone under each bubble ("the app remembers you",
/// 2026-07-22): reading time, honest read progress when at least one
/// card has been read, and (flashcards, 2026-07-23) the quiet REVIEW
/// pill on the three glossary manuals. Sits below the 150px bubble
/// zone so the glow halos keep their full breathing room.
const double _kBubbleMetaHeight = 68.0;

/// Text-scale-aware meta-zone height (accessibility pass, rec #12):
/// the zone holds up to three text lines (about 38px of text at 1.0x),
/// so it grows by the scaled delta of that allocation. Exactly
/// [_kBubbleMetaHeight] at 1.0x; about 108 at 2.0x.
double _scaledBubbleMetaHeight(TextScaler textScaler) {
  const textAllocation = 38.0;
  return _kBubbleMetaHeight + (textScaler.scale(textAllocation) - textAllocation);
}

/// The one-scroll round-bubble home composition.
///
/// Mirrors the retired hub's contract: destinations in, taps out via
/// [onDestinationTap] (the home screen wires `BarrioRouteMap.navigateTo`),
/// with B18 visibility resolved through [visibilityResolver] when the
/// production permission runtime is present, else the [previewRole]
/// tier. Not-visible destinations render at 0.38 opacity and are
/// non-interactive, exactly like the hub (center bubble included).
class BarrioHomeShelf extends StatefulWidget {
  final List<BarrioDestination> destinations;
  final ValueChanged<BarrioDestination> onDestinationTap;
  final BarrioPreviewRole previewRole;

  /// B18: production hook for the live permission system. When
  /// non-null, the resolver overrides the legacy
  /// `previewRole.isIntendedFor(dest)` decision per destination.
  final BarrioDestinationVisibilityResolver? visibilityResolver;

  /// Widgets rendered above the center bubble (brand header, gated El
  /// Podio pill). They scroll with the shelf and are not
  /// entrance-staggered here (the header owns its own one-shot entrance).
  final List<Widget> leading;

  /// Wave B (training search): when non-null, this single sliver
  /// replaces the center bubble + category sections while a query is
  /// active. The [leading] widgets and footer padding stay, and the
  /// shelf state (entrance controller) is preserved, so clearing the
  /// override brings the sections back exactly as before with no
  /// entrance replay. Default null keeps the shelf unchanged.
  final Widget? bodyOverride;

  /// Local reading memory ("the app remembers you", 2026-07-22):
  /// drives the Continue Reading card and the honest per-manual
  /// progress rows. Null (the default) renders neither, so existing
  /// call sites and fresh installs look exactly like before.
  final BarrioReadingSnapshot? readingProgress;

  /// Tap handler for the Continue Reading card: deep-links into the
  /// manual at the remembered position. When null the card does not
  /// render (there is nowhere for it to go).
  final void Function(
    BarrioDestination destination,
    int chapterIndex,
    int unitInChapter,
  )? onContinueReading;

  /// Saved cards (rec #8, 2026-07-23), oldest first as stored. The
  /// Saved section renders ONLY when at least one entry resolves to a
  /// visible manual and a live card (no phantom empty section). A
  /// bookmark whose manual is resolver-hidden (B18) or whose
  /// coordinates no longer exist is kept in storage but not rendered.
  final List<BarrioBookmark> bookmarks;

  /// Tap handler for a Saved row: deep-links to the exact saved card.
  /// When null the section does not render.
  final void Function(
    BarrioDestination destination,
    int chapterIndex,
    int unitInChapter,
  )? onBookmarkOpen;

  /// Remove handler for a Saved row's small x.
  final void Function(BarrioBookmark bookmark)? onBookmarkRemove;

  /// Refresh-due manuals (spaced refresher, rec #11), longest overdue
  /// first as computed by [BarrioRefresherScheduler.dueDocIds] (the
  /// home screen derives this from real recorded timestamps at read
  /// time). Empty (the default) renders no card: fresh installs and
  /// up-to-date readers see nothing. A B18-hidden manual is filtered
  /// out here at render time only; its stored schedule is untouched.
  final List<String> refresherDueDocIds;

  const BarrioHomeShelf({
    super.key,
    required this.destinations,
    required this.onDestinationTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
    this.leading = const <Widget>[],
    this.bodyOverride,
    this.readingProgress,
    this.onContinueReading,
    this.bookmarks = const <BarrioBookmark>[],
    this.onBookmarkOpen,
    this.onBookmarkRemove,
    this.refresherDueDocIds = const <String>[],
  });

  @override
  State<BarrioHomeShelf> createState() => _BarrioHomeShelfState();
}

class _BarrioHomeShelfState extends State<BarrioHomeShelf>
    with SingleTickerProviderStateMixin {
  /// Saved rows shown before the honest 'and N more saved' expander.
  static const int _kSavedRowCap = 5;

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _entranceDecided = false;

  /// Whether the Saved section shows every row (expander tapped).
  bool _savedExpanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceDecided) return;
    _entranceDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility: skip the entrance entirely.
      _entrance.value = 1.0;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  bool _isDestVisible(BarrioDestination dest) {
    final resolver = widget.visibilityResolver;
    if (resolver != null) return resolver.isVisible(dest);
    return widget.previewRole.isIntendedFor(dest);
  }

  Widget _reveal(int slot, Widget child) {
    return _EntranceReveal(entrance: _entrance, slot: slot, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(slivers: _buildSlivers());
  }

  List<Widget> _buildSlivers() {
    final slivers = <Widget>[
      for (final leading in widget.leading)
        SliverToBoxAdapter(child: leading),
    ];
    final override = widget.bodyOverride;
    if (override != null) {
      // Wave B: an active search replaces the center bubble + sections.
      slivers.add(override);
    } else {
      slivers.addAll(_shelfBodySlivers());
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 40)));
    return slivers;
  }

  List<Widget> _shelfBodySlivers() {
    final visible =
        widget.destinations.where((d) => d.showOnHomeHub).toList();
    final slivers = <Widget>[
      ..._continueReadingSlivers(visible),
      ..._refresherSlivers(visible),
      ..._savedSlivers(visible),
      ..._heroSlivers(visible),
    ];
    var slot = 1;
    for (final section in _kShelfSections) {
      final dests =
          visible.where((d) => d.category == section.category).toList();
      if (dests.isEmpty) continue;
      slivers.add(
        SliverToBoxAdapter(
          child: _reveal(
            slot,
            _SectionHeader(
              section: section,
              trailing: _combinedReviewPill(section, dests),
            ),
          ),
        ),
      );
      slivers.add(_sectionBubbles(dests, slot));
      slot++;
    }
    return slivers;
  }

  /// The combined Dishes + Ingredients review pill on the Food & Drink
  /// section header. Appears ONLY when BOTH manuals pass the same B18
  /// visibility resolution as their bubbles; any hidden half hides the
  /// combined deck too.
  Widget? _combinedReviewPill(
    _ShelfSection section,
    List<BarrioDestination> sectionDests,
  ) {
    if (section.category != BarrioCategory.foodAndDrink) return null;
    for (final id in kBarrioCombinedFlashcardManualIds) {
      BarrioDestination? dest;
      for (final d in sectionDests) {
        if (d.id == id) {
          dest = d;
          break;
        }
      }
      if (dest == null || !_isDestVisible(dest)) return null;
    }
    return _ReviewPill(
      key: const Key('barrio_review_pill_combined'),
      label: 'REVIEW BOTH',
      semanticsLabel: 'Review Dishes and Ingredients flashcards together',
      accent: section.accent,
      onTap: () => _openReviewDeck(
        barrioCombinedDishesIngredientsDeck(),
        section.accent,
      ),
    );
  }

  /// Flashcard review entry (2026-07-23): pushes the review screen
  /// directly. Deliberately not routed through BarrioRouteMap; decks
  /// are review surfaces over manuals, not destinations.
  void _openReviewDeck(BarrioFlashcardDeck deck, Color accent) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BarrioFlashcardReviewScreen(
          deck: deck,
          accent: accent,
        ),
      ),
    );
  }

  /// The Continue Reading card at the top of the shelf ("the app
  /// remembers you", 2026-07-22). Renders ONLY when
  /// [_resolveContinueReading] yields a target: something has actually
  /// been read, the manual still exists on the shelf, a tap handler is
  /// wired, and the manual passes the same B18 visibility resolution
  /// as the bubbles (resolver first, preview-role fallback): a hidden
  /// manual never appears here.
  List<Widget> _continueReadingSlivers(List<BarrioDestination> visible) {
    final resolved = _resolveContinueReading(visible);
    final onTap = widget.onContinueReading;
    if (resolved == null || onTap == null) return const <Widget>[];
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          _ContinueReadingCard(
            destination: resolved.destination,
            chapterIndex: resolved.chapterIndex,
            chapterTitle: resolved.chapterTitle,
            onTap: () {
              HapticFeedback.lightImpact();
              onTap(
                resolved.destination,
                resolved.chapterIndex,
                resolved.unitInChapter,
              );
            },
          ),
        ),
      ),
    ];
  }

  /// Resolves the Continue Reading target, or null when no card should
  /// render (nothing read yet, manual gone, handler missing, or the
  /// manual is hidden for this viewer).
  _ContinueReadingTarget? _resolveContinueReading(
    List<BarrioDestination> visible,
  ) {
    final progress = widget.readingProgress;
    if (progress == null || widget.onContinueReading == null) return null;
    final docId = progress.lastDocId;
    final position = progress.lastPosition;
    if (docId == null || position == null) return null;
    // No card unless at least one card of that manual was read.
    final readIds = progress.readUnitIds[docId];
    if (readIds == null || readIds.isEmpty) return null;
    final doc = kBarrioTrainingDocs[docId];
    if (doc == null || doc.chapters.isEmpty) return null;
    final dest = _findVisibleDestination(visible, docId);
    if (dest == null) return null;
    final chapterIndex =
        position.chapterIndex.clamp(0, doc.chapters.length - 1);
    return _ContinueReadingTarget(
      destination: dest,
      chapterIndex: chapterIndex,
      chapterTitle: doc.chapters[chapterIndex].title,
      unitInChapter: position.unitInChapter,
    );
  }

  /// The shelf destination for [docId], but only when it passes the
  /// resolver-first / preview-role-fallback visibility check.
  BarrioDestination? _findVisibleDestination(
    List<BarrioDestination> visible,
    String docId,
  ) {
    for (final dest in visible) {
      if (dest.id == docId) {
        return _isDestVisible(dest) ? dest : null;
      }
    }
    return null;
  }

  /// The Quick refresher card (spaced refresher, rec #11): ONE quiet
  /// card, rendered only when at least one refresh-due manual survives
  /// the same B18 visibility resolution as the bubbles (no phantom
  /// card, no guilt copy). It shows the longest-overdue manual plus an
  /// honest 'and N more due' when others are waiting.
  List<Widget> _refresherSlivers(List<BarrioDestination> visible) {
    final entries = _resolveRefresherEntries(visible);
    if (entries.isEmpty) return const <Widget>[];
    final first = entries.first;
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          _QuickRefresherCard(
            destination: first.destination,
            detailLine: _refresherDetailLine(first),
            moreDueCount: entries.length - 1,
            onTap: () => _openRefresher(first),
          ),
        ),
      ),
    ];
  }

  /// Resolves the renderable refresh-due manuals, preserving the
  /// longest-overdue-first order computed upstream. A due manual is
  /// skipped (its stored schedule untouched) when it is off the shelf,
  /// hidden for this viewer (B18), or has no refresh material.
  List<_RefresherEntry> _resolveRefresherEntries(
    List<BarrioDestination> visible,
  ) {
    final entries = <_RefresherEntry>[];
    for (final docId in widget.refresherDueDocIds) {
      final kind = barrioRefresherKindFor(docId);
      if (kind == null) continue;
      final dest = _findVisibleDestination(visible, docId);
      if (dest == null) continue;
      if (kind == BarrioRefresherKind.quiz &&
          (kBarrioQuizBanks[docId]?.questions.isEmpty ?? true)) {
        continue;
      }
      if (kind == BarrioRefresherKind.flashcards &&
          barrioFlashcardDeckForManual(docId, title: dest.label) == null) {
        continue;
      }
      entries.add(_RefresherEntry(destination: dest, kind: kind));
    }
    return entries;
  }

  /// Honest detail line: a real question count for a quiz refresher,
  /// or the flashcard round for a glossary deck.
  String _refresherDetailLine(_RefresherEntry entry) {
    if (entry.kind == BarrioRefresherKind.quiz) {
      final count = kBarrioQuizBanks[entry.destination.id]!.questions.length;
      return count == 1 ? '1 quick question' : '$count quick questions';
    }
    return 'flashcard round';
  }

  /// Opens the refresher for [entry]: the manual's quiz cards in
  /// sequence, or its shuffled flashcard deck. Completion (and only
  /// completion) records lastRefreshedAt through the reading progress
  /// service; the home screen reloads on return, so the card updates
  /// or disappears honestly.
  void _openRefresher(_RefresherEntry entry) {
    HapticFeedback.lightImpact();
    final docId = entry.destination.id;
    final accent = barrioHomeAccentFor(docId);
    if (entry.kind == BarrioRefresherKind.quiz) {
      final bank = kBarrioQuizBanks[docId]!;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BarrioQuizRefresherScreen(
            bank: bank,
            title: entry.destination.label,
            accent: accent,
            onCompleted: () =>
                BarrioReadingProgressService.recordRefreshCompleted(docId),
          ),
        ),
      );
      return;
    }
    final deck = barrioFlashcardDeckForManual(
      docId,
      title: entry.destination.label,
    )!;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BarrioFlashcardReviewScreen(
          deck: deck,
          accent: accent,
          onDeckFinished: () =>
              BarrioReadingProgressService.recordRefreshCompleted(docId),
        ),
      ),
    );
  }

  /// The Saved section (rec #8): bookmarked cards, newest saved first.
  /// Renders ONLY when at least one bookmark resolves (manual on the
  /// shelf, visible for this viewer per the same B18 resolution as the
  /// bubbles, coordinates still live) and a tap handler is wired: no
  /// phantom empty section. Unresolvable bookmarks stay in storage and
  /// reappear if visibility or content returns.
  List<Widget> _savedSlivers(List<BarrioDestination> visible) {
    final onOpen = widget.onBookmarkOpen;
    if (onOpen == null) return const <Widget>[];
    final rows = _resolveSavedRows(visible);
    if (rows.isEmpty) return const <Widget>[];
    final capped = !_savedExpanded && rows.length > _kSavedRowCap;
    final shown = capped ? rows.sublist(0, _kSavedRowCap) : rows;
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SavedHeader(),
              for (final row in shown)
                _SavedRow(
                  row: row,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onOpen(
                      row.destination,
                      row.bookmark.chapterIndex,
                      row.bookmark.unitInChapter,
                    );
                  },
                  onRemove: widget.onBookmarkRemove == null
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          widget.onBookmarkRemove!(row.bookmark);
                        },
                ),
              if (capped)
                _SavedExpander(
                  hiddenCount: rows.length - _kSavedRowCap,
                  onTap: () => setState(() => _savedExpanded = true),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  /// Resolves the renderable Saved rows, newest saved first. A
  /// bookmark is skipped (never deleted) when its manual is off the
  /// shelf or hidden (B18) or its coordinates no longer exist.
  List<_SavedRowData> _resolveSavedRows(List<BarrioDestination> visible) {
    final rows = <_SavedRowData>[];
    for (final bookmark in widget.bookmarks.reversed) {
      final doc = kBarrioTrainingDocs[bookmark.docId];
      if (doc == null) continue;
      if (bookmark.chapterIndex >= doc.chapters.length) continue;
      final units = doc.chapters[bookmark.chapterIndex].units;
      if (bookmark.unitInChapter >= units.length) continue;
      final dest = _findVisibleDestination(visible, bookmark.docId);
      if (dest == null) continue;
      rows.add(_SavedRowData(
        bookmark: bookmark,
        destination: dest,
        cardTitle: units[bookmark.unitInChapter].title,
      ));
    }
    return rows;
  }

  List<Widget> _heroSlivers(List<BarrioDestination> visible) {
    final products =
        visible.where((d) => d.category == BarrioCategory.product).toList();
    if (products.isEmpty) return const <Widget>[];
    final hero = products.first;
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          Padding(
            // Extra top room so the rotating arcs + glow halo have space
            // to breathe below the header.
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 8),
            child: Center(
              child: BarrioHomeCenterBubble(
                destination: hero,
                diameter: _kCenterBubbleDiameter,
                dimmed: !_isDestVisible(hero) && !hero.comingSoon,
                onTap: () => widget.onDestinationTap(hero),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// One section body: a single horizontal swipe row of bubbles
  /// (2026-07-11 operator decision: sections scroll left and right).
  /// The bubble zone keeps its fixed 150px height so the glow halos
  /// never clip; a quiet metadata zone (reading time + honest read
  /// progress) sits below each bubble. Only the row scrolls
  /// horizontally, never the page.
  Widget _sectionBubbles(List<BarrioDestination> dests, int slot) {
    // Accessibility (rec #12): the meta zone grows with the effective
    // text scale so its lines never clip against the fixed row bounds.
    final metaHeight =
        _scaledBubbleMetaHeight(MediaQuery.textScalerOf(context));
    return SliverToBoxAdapter(
      child: _reveal(
        slot,
        SizedBox(
          height: _kSectionRowHeight + metaHeight,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: dests.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final dest = dests[i];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: _kSectionRowHeight,
                    child: Center(
                      child: BarrioHomeOrbitBubble(
                        destination: dest,
                        diameter: _kBubbleDiameter,
                        dimmed: !_isDestVisible(dest) && !dest.comingSoon,
                        onTap: () => widget.onDestinationTap(dest),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _kBubbleDiameter + 8,
                    height: metaHeight,
                    child: _bubbleMeta(dest),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Quiet under-bubble metadata for manuals: the reading-time estimate
  /// always, plus 'N of M cards read' + a thin progress bar ONLY once
  /// at least one card has been read (Metric Honesty: untouched manuals
  /// show no progress row at all; no phantom zeroes), plus the REVIEW
  /// flashcard pill on the three glossary manuals (2026-07-23), gated
  /// through the same B18 visibility resolution as the bubble itself.
  /// Non-manual destinations render nothing here.
  Widget _bubbleMeta(BarrioDestination dest) {
    final doc = kBarrioTrainingDocs[dest.id];
    if (doc == null) return const SizedBox.shrink();
    final readIds = widget.readingProgress?.readUnitIds[dest.id];
    var readCount = 0;
    final totalCards = _cardCountOf(doc);
    if (readIds != null && readIds.isNotEmpty) {
      for (final chapter in doc.chapters) {
        for (final unit in chapter.units) {
          if (readIds.contains(unit.id)) readCount++;
        }
      }
    }
    return _BubbleMeta(
      minutes: BarrioReadingTime.docMinutes(doc),
      readCount: readCount,
      totalCards: totalCards,
      accent: barrioHomeAccentFor(dest.id),
      review: _manualReviewPill(dest),
    );
  }

  /// The per-manual REVIEW pill, or null for every destination that is
  /// not one of the three flashcard glossaries or does not pass the
  /// resolver-first / preview-role-fallback visibility check (a hidden
  /// manual gets no review entry).
  Widget? _manualReviewPill(BarrioDestination dest) {
    if (!kBarrioFlashcardManualIds.contains(dest.id)) return null;
    if (!_isDestVisible(dest)) return null;
    final deck = barrioFlashcardDeckForManual(dest.id, title: dest.label);
    if (deck == null) return null;
    final accent = barrioHomeAccentFor(dest.id);
    return _ReviewPill(
      key: Key('barrio_review_pill_${dest.id}'),
      label: 'REVIEW',
      semanticsLabel: 'Review ${dest.label} flashcards',
      accent: accent,
      onTap: () => _openReviewDeck(deck, accent),
    );
  }

  static int _cardCountOf(BarrioTrainingDoc doc) {
    var count = 0;
    for (final chapter in doc.chapters) {
      count += chapter.units.length;
    }
    return count;
  }
}

/// Section header: accent tick + Playfair title. ~32px above, ~12px
/// below. (The topic count was removed 2026-07-11 by operator request.)
/// [trailing] is the quiet combined-deck review pill on Food & Drink
/// (2026-07-23); null renders the header exactly as before.
class _SectionHeader extends StatelessWidget {
  final _ShelfSection section;
  final Widget? trailing;

  const _SectionHeader({required this.section, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: section.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                section.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.playfairDisplay(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: BarrioColors.textPrimary,
                ),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Everything the Continue Reading card needs, resolved once.
class _ContinueReadingTarget {
  final BarrioDestination destination;
  final int chapterIndex;
  final String chapterTitle;
  final int unitInChapter;

  const _ContinueReadingTarget({
    required this.destination,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.unitInChapter,
  });
}

/// The Continue Reading card: near-opaque dark card (same legibility
/// recipe as the search result rows, which sit over the same photo),
/// accent icon chip, and the honest position line
/// ('Pick up at Section N: Title').
class _ContinueReadingCard extends StatelessWidget {
  final BarrioDestination destination;
  final int chapterIndex;
  final String chapterTitle;
  final VoidCallback onTap;

  const _ContinueReadingCard({
    required this.destination,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = barrioHomeAccentFor(destination.id);
    // Accessibility (rec #12): the card reads as ONE button (label
    // merged from its text lines), not three separate text nodes.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BarrioColors.shellMid.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.40)),
              ),
              child: Row(
                children: [
                  _iconChip(context, accent),
                  const SizedBox(width: 12),
                  Expanded(child: _texts(accent)),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: accent.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconChip(BuildContext context, Color accent) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.40)),
      ),
      child: Center(
        child: barrioHomeIconWidgetFor(
          context,
          destination.id,
          22,
          accent,
          false,
        ),
      ),
    );
  }

  Widget _texts(Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CONTINUE READING',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: accent.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          destination.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.playfairDisplay(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'Pick up at Section ${chapterIndex + 1}: $chapterTitle',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 12,
            color: BarrioColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// One resolved refresh-due manual: its shelf destination + material.
class _RefresherEntry {
  final BarrioDestination destination;
  final BarrioRefresherKind kind;

  const _RefresherEntry({required this.destination, required this.kind});
}

/// The Quick refresher card: same quiet near-opaque dark recipe as the
/// Continue Reading card. Copy pattern (operator-approved): 'Refresh
/// Food Safety' + '12 quick questions' / 'flashcard round', plus the
/// honest 'and N more due' only when more manuals are waiting.
class _QuickRefresherCard extends StatelessWidget {
  final BarrioDestination destination;
  final String detailLine;
  final int moreDueCount;
  final VoidCallback onTap;

  const _QuickRefresherCard({
    required this.destination,
    required this.detailLine,
    required this.moreDueCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = barrioHomeAccentFor(destination.id);
    // Accessibility (rec #12): the card reads as ONE button (label
    // merged from its text lines).
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: GestureDetector(
            key: const Key('barrio_refresher_card'),
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BarrioColors.shellMid.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.40)),
              ),
              child: Row(
                children: [
                  _iconChip(accent),
                  const SizedBox(width: 12),
                  Expanded(child: _texts(accent)),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: accent.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconChip(Color accent) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.40)),
      ),
      child: Icon(Icons.refresh_rounded, size: 22, color: accent),
    );
  }

  Widget _texts(Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'QUICK REFRESHER',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: accent.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'Refresh ${destination.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.playfairDisplay(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          detailLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 12,
            color: BarrioColors.textSecondary,
          ),
        ),
        if (moreDueCount > 0) ...[
          const SizedBox(height: 3),
          Text(
            moreDueCount == 1 ? 'and 1 more due' : 'and $moreDueCount more due',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11,
              color: BarrioColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// Everything one Saved row needs, resolved once.
class _SavedRowData {
  final BarrioBookmark bookmark;
  final BarrioDestination destination;
  final String cardTitle;

  const _SavedRowData({
    required this.bookmark,
    required this.destination,
    required this.cardTitle,
  });
}

/// Quiet 'Saved' section header: gold tick + small mono label.
class _SavedHeader extends StatelessWidget {
  const _SavedHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          Icon(
            Icons.bookmark_rounded,
            size: 14,
            color: BarrioColors.gold.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Text(
            'Saved',
            style: GoogleFonts.playfairDisplay(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: BarrioColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// One saved card row: manual title + card title, tap to open the
/// exact card, small x to remove. Same near-opaque dark recipe as the
/// Continue Reading card, slimmer.
class _SavedRow extends StatelessWidget {
  final _SavedRowData row;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _SavedRow({required this.row, required this.onTap, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final accent = barrioHomeAccentFor(row.destination.id);
    final b = row.bookmark;
    // Accessibility (rec #12): the row is a button whose label merges
    // the card + manual titles; the remove x stays its OWN labeled
    // node (so it is reachable separately), outside the merge.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Semantics(
        button: true,
        label: 'Saved: ${row.cardTitle}, ${row.destination.label}',
        child: GestureDetector(
          key: ValueKey<String>(
              'barrio_saved_${b.docId}_${b.chapterIndex}_${b.unitInChapter}'),
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: BarrioColors.shellMid.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                Icon(Icons.bookmark_rounded,
                    size: 14, color: accent.withValues(alpha: 0.85)),
                const SizedBox(width: 10),
                Expanded(child: ExcludeSemantics(child: _texts())),
                if (onRemove != null) _removeButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _texts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.cardTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          row.destination.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 11,
            color: BarrioColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _removeButton() {
    final b = row.bookmark;
    return Semantics(
      button: true,
      label: 'Remove from saved',
      child: GestureDetector(
        key: ValueKey<String>('barrio_saved_remove_${b.docId}_'
            '${b.chapterIndex}_${b.unitInChapter}'),
        behavior: HitTestBehavior.opaque,
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            Icons.close_rounded,
            size: 16,
            color: BarrioColors.textMuted.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

/// The honest cap expander: 'and N more saved'. Tapping reveals every
/// saved row; the count is a fact, never a teaser for an empty list.
class _SavedExpander extends StatelessWidget {
  final int hiddenCount;
  final VoidCallback onTap;

  const _SavedExpander({required this.hiddenCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
      button: true,
      child: GestureDetector(
      key: const ValueKey<String>('barrio_saved_expander'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: BarrioColors.gold.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
            Text(
              'and $hiddenCount more saved',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                color: BarrioColors.gold.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// Quiet under-bubble metadata: 'about N min' always; the read line +
/// thin bar only when [readCount] is at least 1 (no phantom zeroes);
/// the flashcard [review] pill only on the glossary manuals that pass
/// visibility (null renders nothing extra).
class _BubbleMeta extends StatelessWidget {
  final int minutes;
  final int readCount;
  final int totalCards;
  final Color accent;
  final Widget? review;

  const _BubbleMeta({
    required this.minutes,
    required this.readCount,
    required this.totalCards,
    required this.accent,
    this.review,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          BarrioReadingTime.label(minutes),
          maxLines: 1,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 9.5,
            color: BarrioColors.textMuted.withValues(alpha: 0.85),
          ),
        ),
        if (readCount >= 1 && totalCards > 0) ...[
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$readCount of $totalCards cards read',
              maxLines: 1,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 9.5,
                color: BarrioColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (readCount / totalCards).clamp(0.0, 1.0),
                minHeight: 2.5,
                backgroundColor: BarrioColors.shellSurface,
                valueColor: AlwaysStoppedAnimation(
                  accent.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ],
        if (review != null) ...[
          const SizedBox(height: 5),
          review!,
        ],
      ],
    );
  }
}

/// Quiet flashcard review pill (2026-07-23): small mono label in the
/// destination accent, used under the glossary bubbles and (as REVIEW
/// BOTH) on the Food & Drink section header.
class _ReviewPill extends StatelessWidget {
  final String label;
  final Color accent;
  final VoidCallback onTap;

  /// Screen-reader label (rec #12): plain-English action naming the
  /// deck, e.g. 'Review Latin Dishes flashcards'. Null falls back to
  /// the visible mono label.
  final String? semanticsLabel;

  const _ReviewPill({
    super.key,
    required this.label,
    required this.accent,
    required this.onTap,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel ?? label,
      child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.style_rounded, size: 11, color: accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: accent,
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// One-time staggered entrance: fade + 14px upward slide over ~280ms,
/// offset ~117ms per slot. Once the parent controller completes (or is
/// jumped to 1.0 for `disableAnimations`), lazily-built slivers render
/// fully settled with no further rebuilds.
class _EntranceReveal extends StatelessWidget {
  final Animation<double> entrance;
  final int slot;
  final Widget child;

  const _EntranceReveal({
    required this.entrance,
    required this.slot,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final start = (slot * 0.13).clamp(0.0, 0.69);
    final end = (start + 0.31).clamp(0.0, 1.0);
    final curved = CurvedAnimation(
      parent: entrance,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, inner) => Transform.translate(
          offset: Offset(0, 14 * (1 - curved.value)),
          child: inner,
        ),
        child: child,
      ),
    );
  }
}
