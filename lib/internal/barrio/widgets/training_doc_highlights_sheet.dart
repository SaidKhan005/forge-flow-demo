// "Your highlights": the per-manual review sheet (Kindle-style
// highlights, Slice D, 2026-08-06).
//
// One glass bottom sheet listing every mark the reader has made in THIS
// manual, grouped by section in reading order, opened from the reader's
// header. It is the answer to "what did I mark in here", which is the
// only reason making marks is worth anything.
//
// WHAT A ROW SAYS, and why each part is there:
//   * a colour chip, so a reader who marks by colour can scan for one,
//   * up to three lines of the words they marked, verbatim,
//   * their note underneath when they wrote one, in their own words,
//   * 'SECTION n · CARD m', the honest position of the card it lives on.
//
// Tapping a row jumps the deck to that card. The page it emits is in the
// PRE-QUIZ content flatten, the same coordinate space the A-Z index
// sheet emits, so the reader converts it with
// [TrainingDeck.deckPageForContentPage] exactly as it does for the index
// (the #1483 quiz-stability contract: a quick-check card between two
// content cards must never move a stored jump target).
//
// ORPHANS ARE LISTED, NOT HIDDEN. A mark whose card is gone, or whose
// words no longer appear on the card it names, cannot be jumped to and
// is never painted. It is still the reader's own note-to-self, so it is
// listed last under "From an earlier version of this manual" with its
// words and its note, and its row offers no jump. Which marks those are
// is decided by [BarrioHighlightPlan.resolve], the SAME rule the card
// paints by, so the sheet and the page can never disagree about what
// resolved.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/barrio_body_chunks.dart';
import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../services/barrio_highlight_anchors.dart';
import '../services/barrio_highlights_service.dart';
import 'barrio_destination_scaffold.dart';

/// Heading of the last group: the marks this build can no longer place
/// on any card of the manual.
const String kBarrioEarlierVersionGroupTitle =
    'From an earlier version of this manual';

/// One highlight as the review sheet lists it, with where it sits.
///
/// [contentPage], [sectionNumber] and [cardNumber] are null together and
/// only for a mark this build cannot place ([isFromEarlierVersion]).
@immutable
class TrainingHighlightEntry {
  /// The mark itself: its words, its colour, its note.
  final BarrioHighlight highlight;

  /// Page of the card in the PRE-QUIZ content flatten (A-Z index sheet
  /// coordinates), or null when the mark cannot be placed.
  final int? contentPage;

  /// 1-based section number as the reader counts them.
  final int? sectionNumber;

  /// 1-based position of the card inside its section.
  final int? cardNumber;

  const TrainingHighlightEntry({
    required this.highlight,
    this.contentPage,
    this.sectionNumber,
    this.cardNumber,
  });

  /// A mark from before the manual's content was regenerated: no card of
  /// this manual carries its words any more, so there is nowhere to jump.
  bool get isFromEarlierVersion => contentPage == null;

  /// 'SECTION 2 · CARD 4', or null when there is no card to point at.
  String? get positionLabel => isFromEarlierVersion
      ? null
      : 'SECTION $sectionNumber · CARD $cardNumber';
}

/// One section's marks, or the trailing group of unplaceable ones.
@immutable
class TrainingHighlightGroup {
  /// The section title, verbatim, or [kBarrioEarlierVersionGroupTitle].
  final String title;

  /// True only for the trailing unplaceable group.
  final bool isFromEarlierVersion;

  /// The marks under this heading, in reading order (and, inside one
  /// card, in the order they were made).
  final List<TrainingHighlightEntry> entries;

  const TrainingHighlightGroup({
    required this.title,
    required this.entries,
    this.isFromEarlierVersion = false,
  });
}

/// Groups [highlights] by the section of [doc] they sit in, in reading
/// order, with everything unplaceable collected into a final group.
///
/// [highlights] arrives in stored order (oldest first) and that order is
/// preserved inside each card, so two marks on the same passage list the
/// way they were made. Only sections carrying at least one mark appear:
/// an empty heading claims a section has marks when it does not.
///
/// A unit id repeated by the manual is listed once, at the FIRST card
/// that carries it, which is where a reader looking for it will land.
List<TrainingHighlightGroup> buildTrainingHighlightGroups({
  required BarrioTrainingDoc doc,
  required List<BarrioHighlight> highlights,
}) {
  if (highlights.isEmpty) return const <TrainingHighlightGroup>[];
  final byUnit = <String, List<BarrioHighlight>>{};
  for (final highlight in highlights) {
    (byUnit[highlight.unitId] ??= <BarrioHighlight>[]).add(highlight);
  }

  final groups = <TrainingHighlightGroup>[];
  final listed = <String>{};
  final seenUnits = <String>{};
  var contentPage = 0;
  for (var c = 0; c < doc.chapters.length; c++) {
    final chapter = doc.chapters[c];
    final entries = <TrainingHighlightEntry>[];
    for (var u = 0; u < chapter.units.length; u++) {
      final unit = chapter.units[u];
      final marks = byUnit[unit.id];
      if (marks != null && seenUnits.add(unit.id)) {
        final unplaceable = _unplaceableIds(unit, marks);
        for (final mark in marks) {
          if (unplaceable.contains(mark.id)) continue;
          entries.add(TrainingHighlightEntry(
            highlight: mark,
            contentPage: contentPage,
            sectionNumber: c + 1,
            cardNumber: u + 1,
          ));
          listed.add(mark.id);
        }
      }
      contentPage++;
    }
    if (entries.isNotEmpty) {
      groups.add(TrainingHighlightGroup(
        title: chapter.title,
        entries: List<TrainingHighlightEntry>.unmodifiable(entries),
      ));
    }
  }

  // Everything the walk above could not place, in stored order. That is
  // both a mark on a card this manual no longer has and a mark whose
  // words the card no longer carries: neither can be jumped to, and
  // neither is painted, so the sheet says the same thing about both.
  final earlier = <TrainingHighlightEntry>[
    for (final highlight in highlights)
      if (!listed.contains(highlight.id))
        TrainingHighlightEntry(highlight: highlight),
  ];
  if (earlier.isNotEmpty) {
    groups.add(TrainingHighlightGroup(
      title: kBarrioEarlierVersionGroupTitle,
      isFromEarlierVersion: true,
      entries: List<TrainingHighlightEntry>.unmodifiable(earlier),
    ));
  }
  return List<TrainingHighlightGroup>.unmodifiable(groups);
}

/// Ids of [marks] whose words are no longer anywhere on [unit].
///
/// Delegates to the resolver the lesson card paints by, so "listed
/// without a jump" and "not painted" are decided once, by one rule.
Set<String> _unplaceableIds(HandbookUnit unit, List<BarrioHighlight> marks) {
  final plan = BarrioHighlightPlan.resolve(
    highlights: marks,
    chunks: chunksForBody(unit.body),
  );
  return plan.orphanIds.toSet();
}

/// One row of the flattened list: a group heading, or a mark under it.
///
/// A DATA row, not a widget, for the reason the A-Z index sheet flattens
/// the same way: building widgets eagerly and indexing them from
/// `itemBuilder` constructs every row (each with its own tap closures) on
/// every build, whether or not it is on screen.
class _SheetRow {
  /// Set on a heading; null on a mark row.
  final TrainingHighlightGroup? group;

  /// Set on a mark row; null on a heading.
  final TrainingHighlightEntry? entry;

  const _SheetRow.heading(TrainingHighlightGroup this.group) : entry = null;

  const _SheetRow.entry(TrainingHighlightEntry this.entry) : group = null;
}

List<_SheetRow> _flattenRows(List<TrainingHighlightGroup> groups) => <_SheetRow>[
      for (final group in groups) ...[
        _SheetRow.heading(group),
        for (final entry in group.entries) _SheetRow.entry(entry),
      ],
    ];

/// The reader's marks in one manual, listed in reading order.
class TrainingDocHighlightsSheet extends StatelessWidget {
  /// The manual being reviewed; its chapters supply the grouping and the
  /// section/card numbers.
  final BarrioTrainingDoc doc;

  /// The manual's accent, for the position labels and the heading rules.
  final Color accent;

  /// The reader's marks, oldest first.
  ///
  /// A listenable, not a plain list, because the manage sheet opens ON
  /// TOP of this one: a recolour, a note, or a removal has to reach the
  /// list underneath, or the sheet would keep showing a mark the reader
  /// just changed.
  final ValueListenable<List<BarrioHighlight>> highlights;

  /// Called with the tapped mark's page in the pre-quiz content flatten.
  /// The reader closes the sheet and jumps the deck in place.
  final ValueChanged<int> onEntryTap;

  /// Called with a mark's id when the reader opens its manage sheet from
  /// the trailing icon. This sheet stays open behind it.
  final ValueChanged<String> onManageTap;

  const TrainingDocHighlightsSheet({
    super.key,
    required this.doc,
    required this.accent,
    required this.highlights,
    required this.onEntryTap,
    required this.onManageTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Container(
        decoration: const BoxDecoration(
          color: BarrioColors.shellDeep,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0x1F16243B))),
        ),
        child: ValueListenableBuilder<List<BarrioHighlight>>(
          valueListenable: highlights,
          builder: (context, marks, _) {
            final groups =
                buildTrainingHighlightGroups(doc: doc, highlights: marks);
            final rows = _flattenRows(groups);
            final listedCount =
                groups.fold<int>(0, (sum, g) => sum + g.entries.length);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetHandle(),
                _SheetHeader(count: listedCount, accent: accent),
                Expanded(
                  child: rows.isEmpty
                      ? const _EmptyState()
                      : ListView.builder(
                          key: const ValueKey<String>(
                            'training_doc_highlights_list',
                          ),
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final group = row.group;
                            if (group != null) {
                              return _GroupHeading(
                                group: group,
                                accent: accent,
                              );
                            }
                            final entry = row.entry!;
                            return _HighlightRow(
                              entry: entry,
                              accent: accent,
                              onTap: entry.isFromEarlierVersion
                                  ? null
                                  : () => onEntryTap(entry.contentPage!),
                              onManageTap: () =>
                                  onManageTap(entry.highlight.id),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Small rounded drag handle, the one every Barrio sheet wears.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Sheet title plus the honest count of what is listed below it.
class _SheetHeader extends StatelessWidget {
  final int count;
  final Color accent;

  const _SheetHeader({required this.count, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Your highlights',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: BarrioColors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Both texts sit in flexible slots so a large text scale wraps
          // instead of overflowing the header row.
          Flexible(
            child: Text(
              count == 1 ? '1 highlight' : '$count highlights',
              textAlign: TextAlign.right,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                letterSpacing: 0.5,
                color: accent.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the sheet says when the reader has marked nothing (or has just
/// removed their last mark with the sheet open).
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Text(
        'You have not marked anything in this manual yet. Press and hold '
        'any words to mark them.',
        style: GoogleFonts.ibmPlexSans(
          fontSize: 13.5,
          height: 1.5,
          color: BarrioColors.textSecondary,
        ),
      ),
    );
  }
}

/// One group heading: the section title (or the earlier-version wording)
/// beside a thin rule, matching the A-Z index sheet's letter headers.
class _GroupHeading extends StatelessWidget {
  final TrainingHighlightGroup group;
  final Color accent;

  const _GroupHeading({required this.group, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 0, 8),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Flexible(
              child: Text(
                group.title.toUpperCase(),
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                  color: group.isFromEarlierVersion
                      ? BarrioColors.textMuted
                      : accent.withValues(alpha: 0.9),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(height: 1, color: const Color(0x1A16243B)),
            ),
          ],
        ),
      ),
    );
  }
}

/// One listed mark.
class _HighlightRow extends StatelessWidget {
  final TrainingHighlightEntry entry;
  final Color accent;

  /// Null on an earlier-version mark: there is no card to jump to, so the
  /// row is text, not a button, and nothing pretends otherwise.
  final VoidCallback? onTap;

  final VoidCallback onManageTap;

  const _HighlightRow({
    required this.entry,
    required this.accent,
    required this.onTap,
    required this.onManageTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlight = entry.highlight;
    final note = highlight.note.trim();
    final position = entry.positionLabel;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Nudged onto the first line of the passage rather than the top
        // of the box, so the chip reads as belonging to the words.
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _ColorChip(token: highlight.color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                highlight.plainText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13.5,
                  height: 1.45,
                  color: BarrioColors.textPrimary,
                ),
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _oneLine(note),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12.5,
                    height: 1.35,
                    fontStyle: FontStyle.italic,
                    color: BarrioColors.textMuted,
                  ),
                ),
              ],
              if (position != null) ...[
                const SizedBox(height: 8),
                Text(
                  position,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    letterSpacing: 0.8,
                    color: accent.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      decoration: BoxDecoration(
        color: BarrioColors.shellMid,
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(color: BarrioColors.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // The jump target is everything left of the manage icon. The
          // icon keeps its own semantics node, so a screen reader reads
          // the mark once and finds the manage button beside it.
          Expanded(
            child: Semantics(
              button: onTap != null,
              label: _spokenLabel(entry, note),
              child: GestureDetector(
                key: ValueKey<String>('barrio_highlight_row_${highlight.id}'),
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: ExcludeSemantics(child: content),
              ),
            ),
          ),
          _ManageButton(highlightId: highlight.id, onTap: onManageTap),
        ],
      ),
    );
  }

  /// The reader's own words first, then their note, then where it is:
  /// the same three facts the row shows, in the order it shows them.
  static String _spokenLabel(TrainingHighlightEntry entry, String note) {
    final parts = <String>[entry.highlight.plainText];
    if (note.isNotEmpty) parts.add('Note: ${_oneLine(note)}');
    parts.add(entry.isFromEarlierVersion
        ? kBarrioEarlierVersionGroupTitle
        : 'Section ${entry.sectionNumber}, card ${entry.cardNumber}');
    return parts.join('. ');
  }

  /// A note collapsed onto one line: the reader's own words, never
  /// rewritten, just unwrapped.
  static String _oneLine(String note) =>
      note.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The marker colour of one listed mark: the same wash-filled,
/// ink-ringed dot the colour picker uses, shrunk to a chip.
///
/// The wash alone is what the reader sees on the page, but a 30% wash on
/// a white row at 12px is not something anyone can tell apart from
/// another 30% wash, so the ring carries the colour. It is the same ink
/// the note glyph and the picker's tick already use, so one marker looks
/// like itself everywhere.
class _ColorChip extends StatelessWidget {
  final String token;

  const _ColorChip({required this.token});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: barrioHighlightWash(token),
        border: Border.all(
          color: barrioHighlightNoteGlyphColor(token),
          width: 1.5,
        ),
      ),
    );
  }
}

/// The quiet trailing icon that opens the manage sheet without leaving
/// the list.
class _ManageButton extends StatelessWidget {
  final String highlightId;
  final VoidCallback onTap;

  const _ManageButton({required this.highlightId, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Change or remove this highlight',
      child: GestureDetector(
        key: ValueKey<String>('barrio_highlight_manage_$highlightId'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            Icons.more_horiz_rounded,
            size: 20,
            color: BarrioColors.textMuted,
          ),
        ),
      ),
    );
  }
}
