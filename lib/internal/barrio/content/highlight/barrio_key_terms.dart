// Key-term color emphasis pilot (operator research pilot, 2026-07-28).
//
// Research-backed, author-CURATED emphasis: a small, hand-picked set of
// clearly-important, unambiguous domain concepts get a color+weight cue so
// the text-heavy reading manuals become more scannable. This is a PILOT
// gated to ONE manual, "The Three Pillars of Hospitality"
// (doc id `training_three_pillars`), so the operator can approve the look
// before any rollout. Every OTHER doc returns an empty term list, so only
// Three Pillars shows highlighting.
//
// Verbatim law (binding): the body TEXT is NEVER altered. This file only
// supplies which curated phrases to STYLE; the matcher returns
// [start, end) offsets into the original string and the card renders the
// exact original substring (case and characters unchanged) with added
// weight+color. No word is ever changed, added, or removed.
//
// Sparse by design ("if everything is bold, nothing is"):
//   * ~1 highlight per 2 sentences, capped HARD at [kBarrioKeyTermCardCap]
//     spans per card.
//   * Only the FIRST occurrence of each term per card is emphasized; later
//     repeats stay plain.
//   * Curated toward multi-word phrases and distinctive nouns; short common
//     words are deliberately excluded so nothing false-matches.
//
// Composition (lowest precedence): the caller passes the ranges already
// claimed by search highlights, tap-to-define term links, numeric fact
// pops, and quiz answer evidence as blockedRanges; any key-term range that
// overlaps one is dropped whole, so the existing span always wins.

import '../../search/barrio_training_search.dart';

/// Hard per-card cap on emphasized key-term spans. Density guard: at most
/// this many curated terms are colored on any single reading card.
const int kBarrioKeyTermCardCap = 6;

/// Curated key terms for "The Three Pillars of Hospitality" only.
///
/// Every entry is a genuine domain concept that appears VERBATIM (as a
/// whole word) in the manual's body prose. Multi-word phrases and
/// distinctive nouns are preferred; the named pillars (food, service,
/// atmosphere) are included as the manual's core concepts. Matching is
/// case-insensitive and whole-word, so ordering here is irrelevant (the
/// matcher sorts by position, longest-first at a tie).
const List<String> _kThreePillarsKeyTerms = <String>[
  'hospitality',
  'three pillars',
  'guest experience',
  'guest satisfaction',
  'guest perception',
  'atmosphere',
  'ambiance',
  'lighting',
  'cleanliness',
  'service',
  'communication',
  'attentiveness',
  'food',
  'food quality',
  'presentation',
  'reputation',
  'standards',
];

/// The curated key terms to emphasize inside [unitId]'s body.
///
/// PILOT GATE: only units of the Three Pillars manual (ids starting with
/// `training_three_pillars_`) return terms; every other doc returns an
/// empty list, so no other manual shows key-term highlighting. Mirrors the
/// [barrioAnswerEvidenceForUnit] lookup shape: a pure, UI-free lookup the
/// reading card calls with a rendering unit's id.
List<String> barrioKeyTermsForUnit(String unitId) {
  if (unitId.startsWith('training_three_pillars_')) {
    return _kThreePillarsKeyTerms;
  }
  return const <String>[];
}

/// One emphasized key-term occurrence inside a text chunk: [start, end)
/// offsets index the chunk string itself (styling only, verbatim law).
class BarrioKeyTermMatch {
  final int start;
  final int end;

  /// The folded term, for first-occurrence-per-card bookkeeping.
  final String foldedTerm;

  const BarrioKeyTermMatch({
    required this.start,
    required this.end,
    required this.foldedTerm,
  });
}

/// Pure-Dart, render-time whole-word matcher for the curated key terms.
///
/// Case-insensitive and diacritic-folded via [BarrioTrainingSearch.fold]
/// (length-preserving, so fold-space offsets index the original text
/// directly). Whole-word only: 'service' never matches inside
/// 'serviceable', 'food' never matches inside 'foodborne'.
class BarrioKeyTermHighlight {
  BarrioKeyTermHighlight._();

  /// Finds the key-term spans to emphasize inside one text chunk of a card.
  ///
  /// [alreadyUsed] carries the folded terms emphasized earlier in the SAME
  /// card (the caller threads one set through the card's chunks in reading
  /// order): first-occurrence-per-card, and its size is the running span
  /// count that enforces [maxPerCard]. Accepted matches are added to it.
  ///
  /// [blockedRanges] are [start, end) ranges already claimed by
  /// higher-precedence styling (search highlights, term links, numeric
  /// pops, answer evidence); an overlapping key-term occurrence is dropped
  /// whole. Returned matches are sorted and mutually non-overlapping.
  static List<BarrioKeyTermMatch> matchesIn(
    String text,
    List<String> terms, {
    required Set<String> alreadyUsed,
    int maxPerCard = kBarrioKeyTermCardCap,
    List<List<int>> blockedRanges = const [],
  }) {
    if (terms.isEmpty || text.isEmpty) return const <BarrioKeyTermMatch>[];
    if (alreadyUsed.length >= maxPerCard) return const <BarrioKeyTermMatch>[];
    final candidates = _firstOccurrenceCandidates(text, terms, alreadyUsed)
      // Earliest first; at the same start the longer term wins ('food
      // quality' beats 'food'), so a shorter substring never steals the spot.
      ..sort(_byStartLongestFirst);
    if (candidates.isEmpty) return const <BarrioKeyTermMatch>[];
    final accepted = <BarrioKeyTermMatch>[];
    for (final match in candidates) {
      if (alreadyUsed.length >= maxPerCard) break; // card cap reached
      // No overlap among accepted key-term spans in this chunk, and a
      // higher-precedence span wins: drop the overlapping key-term whole.
      if (accepted.isNotEmpty && match.start < accepted.last.end) continue;
      if (_intersectsAny(match, blockedRanges)) continue;
      accepted.add(match);
      alreadyUsed.add(match.foldedTerm);
    }
    return accepted;
  }

  /// The first whole-word occurrence of each not-yet-used term inside [text]
  /// (fold-space offsets index the original). One candidate per distinct
  /// term: [alreadyUsed] skips terms emphasized earlier on the card and an
  /// in-chunk seen-set dedupes repeated curated entries.
  static List<BarrioKeyTermMatch> _firstOccurrenceCandidates(
    String text,
    List<String> terms,
    Set<String> alreadyUsed,
  ) {
    final folded = BarrioTrainingSearch.fold(text);
    final seenInChunk = <String>{};
    final candidates = <BarrioKeyTermMatch>[];
    for (final rawTerm in terms) {
      final term = BarrioTrainingSearch.fold(rawTerm.trim());
      if (term.isEmpty) continue;
      if (alreadyUsed.contains(term)) continue;
      if (!seenInChunk.add(term)) continue;
      final idx = _firstWholeWord(folded, term);
      if (idx < 0) continue;
      candidates.add(BarrioKeyTermMatch(
        start: idx,
        end: idx + term.length,
        foldedTerm: term,
      ));
    }
    return candidates;
  }

  /// Sort key: earliest start first, longer term first at a tie.
  static int _byStartLongestFirst(BarrioKeyTermMatch a, BarrioKeyTermMatch b) =>
      a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end);

  /// First whole-word occurrence of [term] in [folded], or -1. Boundaries
  /// are checked at the term's outer edges only, so a multi-word term keeps
  /// its internal spaces.
  static int _firstWholeWord(String folded, String term) {
    var from = 0;
    while (true) {
      final idx = folded.indexOf(term, from);
      if (idx < 0) return -1;
      final beforeOk = idx == 0 || !_isWordChar(folded.codeUnitAt(idx - 1));
      final after = idx + term.length;
      final afterOk =
          after >= folded.length || !_isWordChar(folded.codeUnitAt(after));
      if (beforeOk && afterOk) return idx;
      from = idx + 1;
    }
  }

  /// Whether the folded code unit belongs to a word ([a-z0-9]).
  static bool _isWordChar(int u) =>
      (u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39);

  static bool _intersectsAny(
      BarrioKeyTermMatch match, List<List<int>> ranges) {
    for (final range in ranges) {
      if (match.start < range[1] && match.end > range[0]) return true;
    }
    return false;
  }
}
