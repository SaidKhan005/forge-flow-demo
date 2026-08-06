// Tap-to-define term links (operator-approved rec #9, 2026-07-23).
//
// Pure-Dart detection of known TERM titles (the Latin ingredients and
// Latin dishes glossaries) inside OTHER manuals' card bodies. Matches
// are exact whole-word, case-insensitive, and diacritic-folded via
// [BarrioTrainingSearch.fold] (length-preserving, so fold-space
// offsets index the original text directly).
//
// Scope (binding):
//   * Hosts are the culinary manuals only ([kHostManualIds]):
//     the menu deck, coffee, tequila, and food safety. The handbook
//     and labor manuals never link, and a TERM manual never links
//     inside itself or its sibling glossaries.
//   * Styling only: the body TEXT is never altered (verbatim law).
//     Consumers render the matched substring with a quiet
//     underline-dot; the string itself is untouched.
//
// Over-linking guards:
//   * Terms shorter than 4 letters are never registered
//     (letter count over the folded term, spaces excluded).
//   * First-occurrence-per-card linking: the caller threads one
//     `alreadyLinked` set through every text chunk of a card in
//     reading order, so a term that appears many times in one card
//     links only its first occurrence.
//   * [kSkipTerms] holds empirically excluded generic collisions.
//     2026-07-23 dump over all four hosts: 18 distinct terms match,
//     all in the menu deck, every occurrence culinary usage
//     (MOLE the sauce, TINGA the dish, TORTILLA the flatbread), so
//     the list is EMPTY beyond the automatic guards above.
//   * Longest-match-first at a position: 'SALSA INGLESA' wins over
//     'SALSA' where they overlap.

import '../content/company_handbook_content.dart';
import '../content/training/training_docs.dart';
import '../search/barrio_training_search.dart';

/// Where a TERM's own definition card lives, plus the card itself
/// (title, verbatim body, images) for the definition sheet.
class BarrioTermCard {
  /// Registry id of the TERM glossary that owns the definition.
  final String docId;

  /// Content-card coordinates of the definition card (quiz-stable per
  /// the #1483 coordinate contract).
  final int chapterIndex;
  final int unitInChapter;

  /// The definition card: title, verbatim body, images.
  final HandbookUnit unit;

  const BarrioTermCard({
    required this.docId,
    required this.chapterIndex,
    required this.unitInChapter,
    required this.unit,
  });
}

/// One linked occurrence inside a text chunk: [start, end) offsets
/// index the chunk string itself.
class BarrioTermMatch {
  final int start;
  final int end;

  /// The folded registry term, for first-occurrence bookkeeping.
  final String foldedTerm;

  final BarrioTermCard card;

  const BarrioTermMatch({
    required this.start,
    required this.end,
    required this.foldedTerm,
    required this.card,
  });
}

/// Registry + matcher for tap-to-define term links.
class BarrioTermLinks {
  BarrioTermLinks._();

  /// The culinary manuals that host term links (doc ids). The menu
  /// deck id covers both the routed MENU doc and the parked concept
  /// deck (they share 'training_menu_concept').
  static const Set<String> kHostManualIds = <String>{
    'training_menu_concept',
    'training_coffee',
    'training_tequila',
    'training_food_safety',
  };

  /// The TERM glossaries whose card titles form the term registry.
  static const Set<String> kSourceManualIds = <String>{
    'training_latin_ingredients',
    'training_latin_dishes',
  };

  /// Empirically excluded generic-English collisions (folded form).
  /// 2026-07-23 dump: no exclusions needed (see library comment).
  static const Set<String> kSkipTerms = <String>{};

  /// Minimum letters (folded, spaces excluded) for a registered term.
  static const int kMinTermLetters = 4;

  /// Lazily built folded-term registry, longest term first.
  static Map<String, BarrioTermCard>? _cachedRegistry;
  static List<String>? _cachedTermsByLength;
  static Map<int, List<String>>? _cachedFirstUnitBuckets;

  /// Folded term -> definition card. Built once per process.
  static Map<String, BarrioTermCard> registry() {
    final cached = _cachedRegistry;
    if (cached != null) return cached;
    final built = <String, BarrioTermCard>{};
    for (final docId in kSourceManualIds) {
      final doc = kBarrioTrainingDocs[docId];
      if (doc == null) continue;
      for (var c = 0; c < doc.chapters.length; c++) {
        final units = doc.chapters[c].units;
        for (var u = 0; u < units.length; u++) {
          // Continuation cards define no term. Only the first card of a
          // run carries the verbatim term heading; cards 2..N are titled
          // for what they teach (tool/barrio_training_card_titles.json),
          // so registering them would invent terms that no glossary
          // defines. Run metadata is the honest signal here: it holds
          // whatever the title says.
          if (units[u].runIndex > 1) continue;
          final card = BarrioTermCard(
            docId: docId,
            chapterIndex: c,
            unitInChapter: u,
            unit: units[u],
          );
          for (final term in _termsOfTitle(units[u].title)) {
            // First registration wins: a duplicate title never steals
            // the first card that defined the term.
            built.putIfAbsent(term, () => card);
          }
        }
      }
    }
    _cachedRegistry = built;
    return built;
  }

  /// Registry terms sorted longest first (longest-match priority).
  static List<String> _termsByLength() {
    final cached = _cachedTermsByLength;
    if (cached != null) return cached;
    final terms = registry().keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    _cachedTermsByLength = terms;
    return terms;
  }

  /// Registry terms bucketed by their first code unit, longest first
  /// inside each bucket (perf audit A4).
  ///
  /// The old matcher walked all ~113 registry terms and ran a full
  /// `indexOf` sweep of the chunk for each one, so a reading card cost
  /// thousands of whole-string scans on every rebuild. With this index
  /// the matcher instead walks the chunk once and, at each word start,
  /// only tries the handful of terms that could begin there.
  static Map<int, List<String>> _firstUnitBuckets() {
    final cached = _cachedFirstUnitBuckets;
    if (cached != null) return cached;
    final buckets = <int, List<String>>{};
    for (final term in _termsByLength()) {
      (buckets[term.codeUnitAt(0)] ??= <String>[]).add(term);
    }
    _cachedFirstUnitBuckets = buckets;
    return buckets;
  }

  /// Folded, guard-filtered term variants of one TERM card title.
  /// A parenthetical is a qualifier, not part of the term, and a '/'
  /// separates alternate names ('MAIZE/EL MAIZ') that both point at
  /// the same card. Continuation cards never reach here: [registry]
  /// skips them on runIndex.
  static List<String> _termsOfTitle(String title) {
    var base = title;
    final paren = base.indexOf('(');
    if (paren >= 0) base = base.substring(0, paren);
    final variants = <String>[];
    for (final part in base.split('/')) {
      final folded = BarrioTrainingSearch.fold(part.trim());
      if (folded.isEmpty) continue;
      if (_letterCount(folded) < kMinTermLetters) continue;
      if (kSkipTerms.contains(folded)) continue;
      variants.add(folded);
    }
    return variants;
  }

  static int _letterCount(String folded) {
    var count = 0;
    for (final u in folded.codeUnits) {
      if (_isWordChar(u)) count++;
    }
    return count;
  }

  /// Whether the folded code unit belongs to a word ([a-z0-9]).
  static bool _isWordChar(int u) =>
      (u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39);

  /// Finds the term links to render inside one text chunk of a card.
  ///
  /// [alreadyLinked] carries the folded terms linked earlier in the
  /// SAME card (the caller threads one set through the card's chunks
  /// in reading order): first-occurrence-per-card. Accepted matches
  /// are added to it. [blockedRanges] are [start, end) ranges that
  /// must not be styled (search-highlight spans win over popover
  /// styling); a blocked or overlapped occurrence is dropped WITHOUT
  /// consuming the term, so a later clean occurrence may still link.
  static List<BarrioTermMatch> matchesIn(
    String text, {
    required Set<String> alreadyLinked,
    List<List<int>> blockedRanges = const [],
  }) {
    final reg = registry();
    if (reg.isEmpty) return const <BarrioTermMatch>[];
    final folded = BarrioTrainingSearch.fold(text);
    final firstAt = _firstWholeWordPositions(folded, alreadyLinked);
    if (firstAt.isEmpty) return const <BarrioTermMatch>[];
    // Longest term first, exactly the order the old per-term sweep built
    // its candidate list in, so the stable sort below still breaks a
    // same-start tie in favour of the longer term.
    final candidates = <BarrioTermMatch>[];
    for (final term in _termsByLength()) {
      final idx = firstAt[term];
      if (idx == null) continue;
      candidates.add(BarrioTermMatch(
        start: idx,
        end: idx + term.length,
        foldedTerm: term,
        card: reg[term]!,
      ));
    }
    if (candidates.isEmpty) return const <BarrioTermMatch>[];
    // Earliest first; at the same start the longer term wins (the
    // longest-first candidate order makes the sort stable for that).
    candidates.sort((a, b) => a.start.compareTo(b.start));
    final accepted = <BarrioTermMatch>[];
    for (final match in candidates) {
      if (accepted.isNotEmpty && match.start < accepted.last.end) continue;
      if (_intersectsAny(match, blockedRanges)) continue;
      accepted.add(match);
      alreadyLinked.add(match.foldedTerm);
    }
    return accepted;
  }

  /// First whole-word occurrence of every not-yet-linked registry term
  /// inside [folded], keyed by the folded term (perf audit A4).
  ///
  /// One left-to-right sweep of the chunk replaces one full `indexOf`
  /// sweep per registry term. The result is identical by construction:
  /// a position qualifies exactly when the old [_firstWholeWord] would
  /// have accepted it (nothing word-like immediately before, nothing
  /// word-like immediately after), and only the FIRST such position is
  /// kept per term.
  static Map<String, int> _firstWholeWordPositions(
    String folded,
    Set<String> alreadyLinked,
  ) {
    final buckets = _firstUnitBuckets();
    final found = <String, int>{};
    final length = folded.length;
    for (var i = 0; i < length; i++) {
      if (i > 0 && _isWordChar(folded.codeUnitAt(i - 1))) continue;
      final bucket = buckets[folded.codeUnitAt(i)];
      if (bucket == null) continue;
      for (final term in bucket) {
        if (found.containsKey(term)) continue;
        if (alreadyLinked.contains(term)) continue;
        if (!_endsWholeWordAt(folded, term, i)) continue;
        found[term] = i;
      }
    }
    return found;
  }

  /// Whether [term] sits at [start] in [folded] with nothing word-like
  /// immediately after it. The caller has already established that
  /// nothing word-like sits immediately before [start].
  static bool _endsWholeWordAt(String folded, String term, int start) {
    if (!folded.startsWith(term, start)) return false;
    final after = start + term.length;
    return after >= folded.length || !_isWordChar(folded.codeUnitAt(after));
  }

  static bool _intersectsAny(BarrioTermMatch match, List<List<int>> ranges) {
    for (final range in ranges) {
      if (match.start < range[1] && match.end > range[0]) return true;
    }
    return false;
  }
}
