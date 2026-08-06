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
//
// Three costs the first search used to pay on the UI thread, and how
// they are paid now (audit A3, 2026-07-31):
//   1. Building the folded corpus at all. Folding every unit body in
//      the registry (1,500+ cards, ~700 KB of text) in one go is a
//      multi-hundred-millisecond stall, and it used to land on the
//      FIRST keystroke. [warmUp] now folds it in small chunks off the
//      first frame, yielding to the event loop between chunks so no
//      single turn blocks a frame. A query that lands mid-warm
//      finishes the fold in place (see [_corpus]), so correctness
//      never depends on the warm having run at all.
//   2. Running the scan on every rebuild. That is the caller's job:
//      the home results widget memoizes on the query plus the visible
//      destination set instead of scanning inside `build`.
//   3. Materializing a snippet for every scored unit. A 2-character
//      query can score hundreds of units to render about eight, so
//      [BarrioTrainingSearchResult.snippet] is now built on FIRST
//      ACCESS (in the list item builder) rather than up front. Same
//      snippet, same spans, computed only for the rows that render.

import 'package:meta/meta.dart';

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

  /// Position of the matched unit within its chapter, so the UI can
  /// deep-link the exact card, not just the section.
  final int unitIndex;

  /// Total occurrences of all query words in this unit's searchable
  /// text (titles + body). Results are ranked by this, descending.
  final int hitCount;

  /// Built snippet, or null while a service-produced result has not
  /// had [snippet] read yet. See the deferred-snippet note on
  /// [snippet].
  BarrioSearchSnippet? _snippet;

  /// Deferred snippet inputs. Both null on a caller-built result
  /// (which supplies its snippet up front), both non-null on a
  /// service-built one.
  final _IndexedUnit? _entry;
  final List<String>? _words;

  BarrioTrainingSearchResult({
    required this.destinationId,
    required this.docTitle,
    required this.chapter,
    required this.unitTitle,
    required this.unitIndex,
    required BarrioSearchSnippet snippet,
    required this.hitCount,
  })  : _snippet = snippet,
        _entry = null,
        _words = null;

  /// Service constructor: keeps the snippet inputs instead of the
  /// snippet, so a scored unit that never renders never pays for one
  /// (audit A3.3).
  BarrioTrainingSearchResult._deferredSnippet({
    required this.destinationId,
    required this.docTitle,
    required this.chapter,
    required this.unitTitle,
    required this.unitIndex,
    required this.hitCount,
    required _IndexedUnit entry,
    required List<String> words,
  })  : _snippet = null,
        _entry = entry,
        _words = words;

  /// The display snippet, built on FIRST ACCESS and then cached on
  /// this result.
  ///
  /// [BarrioTrainingSearch.search] returns EVERY scored unit (a
  /// 2-character query can score hundreds), but a list view renders
  /// about eight of them. Building a 90-character window with span
  /// computation for all of them up front was pure waste, so the work
  /// now happens in the item builder that actually shows the row. The
  /// snippet itself is byte-for-byte what the eager path produced:
  /// same inputs, same [BarrioTrainingSearch._buildSnippet] call, only
  /// later.
  BarrioSearchSnippet get snippet =>
      _snippet ??= BarrioTrainingSearch._buildSnippet(_entry!, _words!);

  int get chapterIndex => chapter.index;

  String get chapterTitle => chapter.title;
}

/// One indexed unit: original strings for snippets plus the cached
/// folded strings the query scans.
class _IndexedUnit {
  final String destinationId;
  final BarrioTrainingDoc doc;
  final int chapterIndex;
  final int unitIndex;
  final HandbookUnit unit;

  /// Folded doc title + chapter title + unit title, newline-joined.
  final String foldedScope;

  final String foldedBody;

  const _IndexedUnit({
    required this.destinationId,
    required this.doc,
    required this.chapterIndex,
    required this.unitIndex,
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

  /// Partially folded corpus and the generator still feeding it, while
  /// [warmUp] is working through the registry in chunks. Both are
  /// cleared the moment the corpus is complete.
  static List<_IndexedUnit>? _partialCorpus;
  static Iterator<_IndexedUnit>? _pendingEntries;

  /// The warm currently running, so repeated [warmUp] calls (a second
  /// home-screen mount, a hot reload) join it instead of starting a
  /// second pass over the same generator.
  static Future<void>? _warmInFlight;

  /// Unit bodies folded per warm chunk. Sized so one chunk is a few
  /// milliseconds of work: the warm gives the frame pipeline a turn
  /// between chunks, so it costs elapsed time, never a dropped frame.
  static const int _kWarmChunkUnits = 96;

  /// Number of [search] calls this process has made. Bumped inside an
  /// `assert`, so release builds carry no counter at all.
  ///
  /// Exists for the A3.2 regression guard: the home results widget
  /// must memoize, so an unrelated rebuild of the home tree must not
  /// move this number.
  @visibleForTesting
  static int debugSearchCallCount = 0;

  /// True once the folded corpus is complete, whether it was warmed in
  /// the background or built in place by a query that arrived first.
  static bool get isCorpusWarm => _cachedCorpus != null;

  /// Folds the corpus off the critical path, in chunks, so the first
  /// keystroke never pays for it (audit A3.1).
  ///
  /// Call this once the first frame is up (the home search field does,
  /// from a post-frame callback). Cheap and idempotent: it returns
  /// immediately when the corpus is already built, and joins the
  /// running warm when one is in flight. Nothing depends on it having
  /// finished; a query that arrives mid-warm simply finishes the fold
  /// itself.
  static Future<void> warmUp() {
    if (_cachedCorpus != null) return Future<void>.value();
    return _warmInFlight ??= _warmCorpus();
  }

  static Future<void> _warmCorpus() async {
    while (_cachedCorpus == null) {
      final built = _partialCorpus ??= <_IndexedUnit>[];
      final entries = _pendingEntries ??= _corpusEntries().iterator;
      var folded = 0;
      var exhausted = false;
      while (folded < _kWarmChunkUnits) {
        if (!entries.moveNext()) {
          exhausted = true;
          break;
        }
        built.add(entries.current);
        folded++;
      }
      if (exhausted) {
        _completeCorpus(built);
        break;
      }
      // Yield the event loop between chunks. A frame due right now
      // gets serviced before the next chunk starts, which is the whole
      // point: total warm time stays short, but no single turn of it
      // is long enough to drop a frame.
      await Future<void>.delayed(Duration.zero);
    }
    _warmInFlight = null;
  }

  /// Drops the corpus so the next query (or [warmUp]) rebuilds it from
  /// scratch. Test-only, and only safe when no warm is in flight.
  @visibleForTesting
  static void debugResetCorpus() {
    _cachedCorpus = null;
    _partialCorpus = null;
    _pendingEntries = null;
    _warmInFlight = null;
  }

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
    assert(() {
      debugSearchCallCount++;
      return true;
    }());
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
    return BarrioTrainingSearchResult._deferredSnippet(
      destinationId: entry.destinationId,
      docTitle: entry.doc.title,
      chapter: BarrioSearchChapterRef(
        entry.chapterIndex,
        entry.doc.chapters[entry.chapterIndex].title,
      ),
      unitTitle: entry.unit.title,
      unitIndex: entry.unitIndex,
      entry: entry,
      words: words,
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

  /// The cached folded corpus, built on first use.
  ///
  /// A query that arrives while [warmUp] is still folding finishes the
  /// remaining units in place, so a caller can never observe a partial
  /// corpus: the warm is an optimization, never a precondition.
  static List<_IndexedUnit> _corpus() {
    final cached = _cachedCorpus;
    if (cached != null) return cached;
    final built = _partialCorpus ??= <_IndexedUnit>[];
    final entries = _pendingEntries ??= _corpusEntries().iterator;
    while (entries.moveNext()) {
      built.add(entries.current);
    }
    return _completeCorpus(built);
  }

  /// Publishes [built] as the finished corpus and retires the warm
  /// scratch state.
  static List<_IndexedUnit> _completeCorpus(List<_IndexedUnit> built) {
    _cachedCorpus = built;
    _partialCorpus = null;
    _pendingEntries = null;
    return built;
  }

  /// Every corpus entry, folded on demand, in corpus order.
  ///
  /// Iteration order of `kBarrioTrainingDocs` (a const literal map, so
  /// insertion-ordered) defines that order: registry order, then
  /// chapter, then unit. Lazy so [warmUp] can fold a chunk at a time
  /// and `_corpus` can drain whatever is left; both consume this same
  /// sequence, so a warmed corpus and an in-place one are identical.
  static Iterable<_IndexedUnit> _corpusEntries() sync* {
    for (final registryEntry in kBarrioTrainingDocs.entries) {
      final destinationId = registryEntry.key;
      final doc = registryEntry.value;
      for (var c = 0; c < doc.chapters.length; c++) {
        final chapter = doc.chapters[c];
        for (var u = 0; u < chapter.units.length; u++) {
          final unit = chapter.units[u];
          yield _IndexedUnit(
            destinationId: destinationId,
            doc: doc,
            chapterIndex: c,
            unitIndex: u,
            unit: unit,
            foldedScope: fold('${doc.title}\n${chapter.title}\n${unit.title}'),
            foldedBody: fold(unit.body),
          );
        }
      }
    }
  }
}
