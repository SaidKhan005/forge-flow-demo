// A-Z jump index for the glossary manuals (2026-07-23 operator-approved
// rec #6).
//
// A bottom sheet opened from the training reader's header index icon on
// the three TERM manuals only. It lists every card title alphabetically
// under letter headers computed at runtime from the titles themselves.
// Presentation-only: the verbatim content (including chapter titles
// like "8 to C") is never renamed or touched. Cards split into
// "(cont.)" continuations are listed once under the base title, jumping
// to the first card of the run.
//
// Letter-rail decision (operator dislikes jam-packed UI): no edge rail.
// Twenty-plus rail letters at 390pt width would land under 16px per tap
// target; clearly separated letter headers in one smooth scroll list
// stay calm and legible instead.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/training/barrio_training_doc.dart';
import '../search/barrio_training_search.dart';
import 'barrio_destination_scaffold.dart';

/// Strips a trailing continuation marker off a split card's title.
final RegExp _kContSuffix = RegExp(r'\s*\(cont\.\)\s*$');

/// One tappable index entry: the base card title and the flat-deck
/// page of the first card carrying it.
class TrainingIndexEntry {
  final String title;
  final int page;

  const TrainingIndexEntry({required this.title, required this.page});
}

/// One letter section of the index ('#' collects titles that do not
/// start with a letter, e.g. 86'D and 911).
class TrainingIndexGroup {
  final String letter;
  final List<TrainingIndexEntry> entries;

  const TrainingIndexGroup({required this.letter, required this.entries});
}

/// Builds the alphabetical index for [doc] at runtime.
///
/// Walks the flat deck in reading order, folds "(cont.)" continuation
/// cards into their base title (first card of the run wins), sorts the
/// unique titles case- and diacritic-insensitively, and groups them by
/// first letter. Digits and other non-letters group under '#', which
/// sorts first, matching the glossaries' own "8 to C" reading order.
List<TrainingIndexGroup> buildTrainingIndexGroups(BarrioTrainingDoc doc) {
  // Insertion order keeps the FIRST card of every title run.
  final byFoldedTitle = <String, TrainingIndexEntry>{};
  var page = 0;
  for (final chapter in doc.chapters) {
    for (final unit in chapter.units) {
      final base = unit.title.replaceFirst(_kContSuffix, '').trim();
      if (base.isNotEmpty) {
        byFoldedTitle.putIfAbsent(
          BarrioTrainingSearch.fold(base),
          () => TrainingIndexEntry(title: base, page: page),
        );
      }
      page++;
    }
  }
  final sortedKeys = byFoldedTitle.keys.toList()..sort();
  // Folded keys sort digits before letters, so group insertion order is
  // already '#' first, then A to Z.
  final grouped = <String, List<TrainingIndexEntry>>{};
  for (final key in sortedKeys) {
    grouped.putIfAbsent(_letterFor(key), () => []).add(byFoldedTitle[key]!);
  }
  return <TrainingIndexGroup>[
    for (final e in grouped.entries)
      TrainingIndexGroup(letter: e.key, entries: e.value),
  ];
}

/// Header letter for a folded (lowercase) sort key.
String _letterFor(String foldedKey) {
  final u = foldedKey.codeUnitAt(0);
  if (u >= 0x61 && u <= 0x7A) return String.fromCharCode(u - 0x20);
  return '#';
}

/// The A-Z index bottom sheet for one glossary manual.
class TrainingDocIndexSheet extends StatelessWidget {
  final BarrioTrainingDoc doc;
  final Color accent;

  /// Called with the flat-deck page of the tapped entry. The caller
  /// closes the sheet and jumps the deck in place.
  final ValueChanged<int> onEntryTap;

  const TrainingDocIndexSheet({
    super.key,
    required this.doc,
    required this.accent,
    required this.onEntryTap,
  });

  @override
  Widget build(BuildContext context) {
    final groups = buildTrainingIndexGroups(doc);
    final termCount =
        groups.fold<int>(0, (sum, g) => sum + g.entries.length);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Container(
        decoration: const BoxDecoration(
          color: BarrioColors.shellDeep,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0x24FFFFFF))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _SheetHeader(termCount: termCount, accent: accent),
            Expanded(child: _buildList(groups)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<TrainingIndexGroup> groups) {
    // One flat builder list (headers + entries) so 92-term glossaries
    // scroll smoothly with lazy row builds.
    final rows = <Widget>[
      for (final group in groups) ...[
        _LetterHeader(letter: group.letter, accent: accent),
        for (final entry in group.entries)
          _EntryRow(entry: entry, onTap: () => onEntryTap(entry.page)),
      ],
    ];
    return ListView.builder(
      key: const ValueKey<String>('training_doc_index_list'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
    );
  }
}

/// Small rounded drag handle at the top of the sheet.
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
          color: Colors.white.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Sheet title plus the honest term count (a fact from the list).
class _SheetHeader extends StatelessWidget {
  final int termCount;
  final Color accent;

  const _SheetHeader({required this.termCount, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            'Jump to a term',
            style: GoogleFonts.playfairDisplay(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: BarrioColors.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            '$termCount terms',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              letterSpacing: 0.5,
              color: accent.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Clearly separated letter header: accent letter plus a thin rule.
class _LetterHeader extends StatelessWidget {
  final String letter;
  final Color accent;

  const _LetterHeader({required this.letter, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 0, 6),
      child: Row(
        children: [
          Text(
            letter,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: accent.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable term row.
class _EntryRow extends StatelessWidget {
  final TrainingIndexEntry entry;
  final VoidCallback onTap;

  const _EntryRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            color: BarrioColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
