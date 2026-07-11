// Pure-Dart full-text search over the verbatim Barrio training corpus
// (Barrio Training Media + Search V1, Wave B; plan:
// docs/phases/barrio_training_media_search_v1/
// barrio_training_media_search_v1_plan.md).
//
// No I/O and no Flutter imports: the service indexes every document in
// `kBarrioTrainingDocs` (doc title, chapter titles, unit titles, unit
// bodies) and answers substring queries that are case-insensitive AND
// Latin-diacritic-insensitive ('jalapeno' matches 'jalapeño' and the
// other way round).
//
// Offset-mapping approach (documented per the Wave B contract): the
// fold in [BarrioTrainingSearch.fold] maps every UTF-16 code unit to
// exactly one code unit (ASCII A-Z to a-z; the Latin diacritics set to
// its base letter; everything else unchanged), so a folded string has
// the same length as its original and every offset in fold space is
// valid in the original string. Match spans are therefore computed on
// the folded snippet and applied directly to the original snippet text
// with no offset translation.
//
// Cost posture: the folded corpus is built lazily ONCE and cached in a
// static (`_corpus`); a per-keystroke query only folds the short query
// string and runs `indexOf` scans over the cached folded strings. No
// per-keystroke re-folding of the ~110k-word corpus ever happens.

import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../content/training/training_docs.dart';

/// One bold-me range inside [BarrioSearchSnippet.text]. `start` is
/// inclusive, `end` exclusive; offsets index the snippet string itself.
class BarrioSnippetSpan {
  final int start;
  final int end;

  const BarrioSnippetSpan(this.start, this.end);
}

/// A display snippet: about [BarrioTrainingSearch.kSnippetWindow]
/// characters of the original unit body around the first match, plus
/// the query-word spans to bold. Newlines inside the window are shown
/// as spaces (a one-to-one substitution, so spans stay valid).
class BarrioSearchSnippet {
  /// Snippet text taken from the original (unfolded) unit body.
  final String text;

  /// Sorted, non-overlapping bold ranges inside [text].
  final List<BarrioSnippetSpan> matchSpans;

  /// True when the snippet starts after the beginning of the body.
  final bool cutAtStart;

  /// True when the snippet ends before the end of the body.
  final bool cutAtEnd;

  const BarrioSearchSnippet({
    required this.text,
    required this.matchSpans,
    required this.cutAtStart,
    required this.cutAtEnd,
  });
}

/// Where a chapter sits inside its document.
class BarrioSearchChapterRef {
  final int index;
  final String title;

  const BarrioSearchChapterRef(this.index, this.title);
}

/// One search hit: a single unit of a training document.
class BarrioTrainingSearchResult {
  /// Destination id (the `kBarrioTrainingDocs` key), used for routing,
  /// visibility checks, and icon/accent lookups.
  final String destinationId;

  final String docTitle;

  /// Chapter position and title, so the UI can deep-link the section.
  final BarrioSearchChapterRef chapter;

  final String unitTitle;

  final BarrioSearchSnippet snippet;

  /// Total occurrences of all query words in this unit's searchable
  /// text (titles + body). Results are ranked by this, descending.
  final int hitCount;

  const BarrioTrainingSearchResult({
    required this.destinationId,
    required this.docTitle,
    required this.chapter,
    required this.unitTitle,
    required this.snippet,
    required this.hitCount,
  });

  int get chapterIndex => chapter.index;

  String get chapterTitle => chapter.title;
}

/// One indexed unit: original strings for snippets plus the cached
/// folded strings the query scans.
class _IndexedUnit {
  final String destinationId;
  final BarrioTrainingDoc doc;
  final int chapterIndex;
  final HandbookUnit unit;

  /// Folded doc title + chapter title + unit title, newline-joined.
  final String foldedScope;

  final String foldedBody;

  const _IndexedUnit({
    required this.destinationId,
    required this.doc,
    required this.chapterIndex,
    required this.unit,
    required this.foldedScope,
    required this.foldedBody,
  });
}

class _ScoredUnit {
  final _IndexedUnit entry;
  final int corpusOrder;
  final int hitCount;

  const _ScoredUnit(this.entry, this.corpusOrder, this.hitCount);
}

/// Latin diacritics fold table: each accented code unit maps to its
/// lowercase ASCII base letter. Covers a-z accents plus their uppercase
/// forms per the Wave B contract.
const Map<int, int> _kDiacriticFold = <int, int>{
  // a: á à â ä ã å / Á À Â Ä Ã Å
  0xE1: 0x61, 0xE0: 0x61, 0xE2: 0x61, 0xE4: 0x61, 0xE3: 0x61, 0xE5: 0x61,
  0xC1: 0x61, 0xC0: 0x61, 0xC2: 0x61, 0xC4: 0x61, 0xC3: 0x61, 0xC5: 0x61,
  // e: é è ê ë / É È Ê Ë
  0xE9: 0x65, 0xE8: 0x65, 0xEA: 0x65, 0xEB: 0x65,
  0xC9: 0x65, 0xC8: 0x65, 0xCA: 0x65, 0xCB: 0x65,
  // i: í ì î ï / Í Ì Î Ï
  0xED: 0x69, 0xEC: 0x69, 0xEE: 0x69, 0xEF: 0x69,
  0xCD: 0x69, 0xCC: 0x69, 0xCE: 0x69, 0xCF: 0x69,
  // o: ó ò ô ö õ / Ó Ò Ô Ö Õ
  0xF3: 0x6F, 0xF2: 0x6F, 0xF4: 0x6F, 0xF6: 0x6F, 0xF5: 0x6F,
  0xD3: 0x6F, 0xD2: 0x6F, 0xD4: 0x6F, 0xD6: 0x6F, 0xD5: 0x6F,
  // u: ú ù û ü / Ú Ù Û Ü
  0xFA: 0x75, 0xF9: 0x75, 0xFB: 0x75, 0xFC: 0x75,
  0xDA: 0x75, 0xD9: 0x75, 0xDB: 0x75, 0xDC: 0x75,
  // n: ñ / Ñ
  0xF1: 0x6E, 0xD1: 0x6E,
  // c: ç / Ç
  0xE7: 0x63, 0xC7: 0x63,
};

/// Full-text search over the 18 verbatim training manuals.
class BarrioTrainingSearch {
  BarrioTrainingSearch._();

  /// Queries shorter than this after trimming return no results.
  static const int kMinQueryLength = 2;

  /// Target snippet width in characters (word-boundary snapping only
  /// ever shrinks the window, so snippets never exceed this).
  static const int kSnippetWindow = 90;

  /// Lazily built, cached folded corpus. Built exactly once per
  /// process; queries only scan these strings.
  static List<_IndexedUnit>? _cachedCorpus;

  /// Folds [input] to lowercase ASCII for the Latin diacritics set.
  /// One code unit in, one code unit out: the result has the same
  /// length as [input], which is what keeps fold-space offsets valid
  /// on the original string (see the library comment).
  static String fold(String input) {
    final units = input.codeUnits;
    final out = List<int>.filled(units.length, 0);
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0x41 && u <= 0x5A) {
        out[i] = u + 0x20; // ASCII A-Z -> a-z
      } else {
        out[i] = _kDiacriticFold[u] ?? u;
      }
    }
    return String.fromCharCodes(out);
  }

  /// Runs [query] over the corpus.
  ///
  /// Multi-word queries AND: every word must match (as a folded
  /// substring) within the same unit's searchable text (doc title,
  /// chapter title, unit title, body). Results are ranked by total hit
  /// count, ties broken by corpus order. When [isDestinationAllowed]
  /// is provided, units of disallowed destinations are skipped
  /// entirely (B18: a result the user cannot open must not render).
  static List<BarrioTrainingSearchResult> search(
    String query, {
    bool Function(String destinationId)? isDestinationAllowed,
  }) {
    final trimmed = query.trim();
    if (trimmed.length < kMinQueryLength) {
      return const <BarrioTrainingSearchResult>[];
    }
    final words = fold(trimmed)
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const <BarrioTrainingSearchResult>[];

    final corpus = _corpus();
    final scored = <_ScoredUnit>[];
    for (var order = 0; order < corpus.length; order++) {
      final entry = corpus[order];
      if (isDestinationAllowed != null &&
          !isDestinationAllowed(entry.destinationId)) {
        continue;
      }
      final hits = _hitCount(entry, words);
      if (hits > 0) scored.add(_ScoredUnit(entry, order, hits));
    }
    scored.sort((a, b) {
      final byHits = b.hitCount.compareTo(a.hitCount);
      if (byHits != 0) return byHits;
      return a.corpusOrder.compareTo(b.corpusOrder);
    });
    return <BarrioTrainingSearchResult>[
      for (final s in scored) _toResult(s.entry, s.hitCount, words),
    ];
  }

  /// Total occurrences of all [words] in the unit's searchable text,
  /// or 0 when any word is absent (AND semantics).
  static int _hitCount(_IndexedUnit entry, List<String> words) {
    var total = 0;
    for (final word in words) {
      final hits = _countOccurrences(entry.foldedScope, word) +
          _countOccurrences(entry.foldedBody, word);
      if (hits == 0) return 0;
      total += hits;
    }
    return total;
  }

  /// Non-overlapping occurrences of [needle] in [haystack].
  static int _countOccurrences(String haystack, String needle) {
    var count = 0;
    var from = 0;
    while (true) {
      final idx = haystack.indexOf(needle, from);
      if (idx < 0) return count;
      count++;
      from = idx + needle.length;
    }
  }

  static BarrioTrainingSearchResult _toResult(
    _IndexedUnit entry,
    int hitCount,
    List<String> words,
  ) {
    return BarrioTrainingSearchResult(
      destinationId: entry.destinationId,
      docTitle: entry.doc.title,
      chapter: BarrioSearchChapterRef(
        entry.chapterIndex,
        entry.doc.chapters[entry.chapterIndex].title,
      ),
      unitTitle: entry.unit.title,
      snippet: _buildSnippet(entry, words),
      hitCount: hitCount,
    );
  }

  /// Builds the snippet around the earliest body match of any query
  /// word. When the match lives only in the doc/chapter/unit titles,
  /// the snippet shows the start of the body with no bold spans.
  static BarrioSearchSnippet _buildSnippet(
    _IndexedUnit entry,
    List<String> words,
  ) {
    final folded = entry.foldedBody;
    var matchStart = -1;
    var matchLength = 0;
    for (final word in words) {
      final idx = folded.indexOf(word);
      if (idx >= 0 && (matchStart < 0 || idx < matchStart)) {
        matchStart = idx;
        matchLength = word.length;
      }
    }
    if (matchStart < 0) {
      matchStart = 0;
      matchLength = 0;
    }
    return _window(entry, matchStart, matchLength, words);
  }

  /// Cuts the ~[kSnippetWindow]-char window around the first match,
  /// snaps its edges to word boundaries (never past the match itself),
  /// and collects the bold spans inside the window.
  static BarrioSearchSnippet _window(
    _IndexedUnit entry,
    int matchStart,
    int matchLength,
    List<String> words,
  ) {
    final folded = entry.foldedBody;
    final length = folded.length;
    final matchEnd = matchStart + matchLength;

    var start = matchStart - ((kSnippetWindow - matchLength) ~/ 2);
    if (start < 0) start = 0;
    var end = start + kSnippetWindow;
    if (end > length) {
      end = length;
      start = end - kSnippetWindow;
      if (start < 0) start = 0;
    }
    start = _snapStartForward(folded, start, matchStart);
    end = _snapEndBackward(folded, end, matchEnd);

    final spans = _spansInWindow(folded, words, start, end);
    final text = entry.unit.body
        .substring(start, end)
        .replaceAll('\n', ' '); // one-to-one, keeps span offsets valid
    return BarrioSearchSnippet(
      text: text,
      matchSpans: spans,
      cutAtStart: start > 0,
      cutAtEnd: end < length,
    );
  }

  static bool _isBreak(int codeUnit) {
    return codeUnit == 0x20 || codeUnit == 0x0A || codeUnit == 0x09;
  }

  /// Moves [start] forward past a broken leading word, but never past
  /// [matchStart] (a match inside a long token keeps the raw cut).
  static int _snapStartForward(String folded, int start, int matchStart) {
    if (start <= 0 || _isBreak(folded.codeUnitAt(start - 1))) return start;
    var i = start;
    while (i < matchStart && !_isBreak(folded.codeUnitAt(i))) {
      i++;
    }
    return i < matchStart ? i + 1 : start;
  }

  /// Moves [end] back to the last word boundary, but never before
  /// [matchEnd] (the first match always stays inside the snippet).
  static int _snapEndBackward(String folded, int end, int matchEnd) {
    if (end >= folded.length || _isBreak(folded.codeUnitAt(end))) return end;
    var i = end;
    while (i > matchEnd && !_isBreak(folded.codeUnitAt(i - 1))) {
      i--;
    }
    return i > matchEnd ? i - 1 : end;
  }

  /// All query-word occurrences inside [start, end), as sorted merged
  /// snippet-relative spans.
  static List<BarrioSnippetSpan> _spansInWindow(
    String folded,
    List<String> words,
    int start,
    int end,
  ) {
    final raw = <BarrioSnippetSpan>[];
    for (final word in words) {
      var from = start;
      while (true) {
        final idx = folded.indexOf(word, from);
        if (idx < 0 || idx + word.length > end) break;
        raw.add(BarrioSnippetSpan(idx - start, idx - start + word.length));
        from = idx + word.length;
      }
    }
    raw.sort((a, b) => a.start.compareTo(b.start));
    return _mergeSpans(raw);
  }

  /// Merges overlapping or touching spans so the UI never double-bolds.
  static List<BarrioSnippetSpan> _mergeSpans(List<BarrioSnippetSpan> sorted) {
    final merged = <BarrioSnippetSpan>[];
    for (final span in sorted) {
      if (merged.isEmpty || span.start > merged.last.end) {
        merged.add(span);
      } else if (span.end > merged.last.end) {
        merged[merged.length - 1] =
            BarrioSnippetSpan(merged.last.start, span.end);
      }
    }
    return merged;
  }

  /// The cached folded corpus, built on first use. Iteration order of
  /// `kBarrioTrainingDocs` (a const literal map, so insertion-ordered)
  /// defines corpus order: registry order, then chapter, then unit.
  static List<_IndexedUnit> _corpus() {
    final cached = _cachedCorpus;
    if (cached != null) return cached;
    final built = <_IndexedUnit>[];
    kBarrioTrainingDocs.forEach((destinationId, doc) {
      for (var c = 0; c < doc.chapters.length; c++) {
        final chapter = doc.chapters[c];
        for (final unit in chapter.units) {
          built.add(
            _IndexedUnit(
              destinationId: destinationId,
              doc: doc,
              chapterIndex: c,
              unit: unit,
              foldedScope:
                  fold('${doc.title}\n${chapter.title}\n${unit.title}'),
              foldedBody: fold(unit.body),
            ),
          );
        }
      }
    });
    _cachedCorpus = built;
    return built;
  }
}
