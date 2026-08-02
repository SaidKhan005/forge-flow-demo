// Pure-Dart extractive question answering over the verbatim Barrio
// training corpus ("ask this manual", answers slice 1; sibling of
// barrio_training_search.dart, reusing its length-preserving fold).
//
// No I/O, no network, no LLM, and no Flutter imports: a submitted
// question is normalized to content terms, every HandbookUnit in
// `kBarrioTrainingDocs` is ranked with BM25, and the top units answer
// with VERBATIM excerpts cut from their own body text.
//
// Verbatim excerpt law (absolute, test-enforced):
//   excerpt == unit.body.substring(excerptStart, excerptEnd)
// The service never paraphrases, joins, or synthesizes words. An
// excerpt is always one contiguous span of the source body: a best
// sentence, optionally extended to the sentences immediately after it.
// A weak match is labeled weak, never dressed up as an answer
// (Metric Honesty).
//
// Cost posture: the token-count index is built lazily ONCE on the
// first asked question and cached in a static, mirroring the
// folded-corpus cache in BarrioTrainingSearch. Asking is submit-gated
// by the UI (never per keystroke), so the one-time build cost lands on
// the first submitted question; every ask after that is map lookups
// over the cached counts plus one sentence pass over at most
// [BarrioTrainingAnswers.kMaxAnswers] unit bodies.
//
// Determinism: no randomness and no clock anywhere. Identical queries
// return identical answers; every tie is broken by corpus order
// (registry order, then chapter, then unit).

import 'dart:math' as math;

import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../content/training/training_docs.dart';
import 'barrio_training_search.dart';

/// How strongly an excerpt actually answers the asked question.
///
/// The service only ever constructs [answer] and [weak] values: the
/// [none] tier is represented by an empty result list from
/// [BarrioTrainingAnswers.ask] (no unit matched any content term).
/// [BarrioTrainingAnswers.overallConfidence] folds a result list back
/// into a single tier so a caller can hold one verdict.
enum BarrioAnswerConfidence {
  /// The best sentence covers every content term, or at least 60% of
  /// them with two or more matched: safe to present as an answer.
  answer,

  /// The unit matched, but no single sentence clears the answer bar.
  /// Callers show a web fallback instead of a dressed-up excerpt.
  weak,

  /// Nothing in the corpus matched any content term.
  none,
}

/// One extractive answer: a verbatim excerpt from a single unit of a
/// training document, plus everything the UI needs to deep-link it.
class BarrioTrainingAnswer {
  /// Destination id (the `kBarrioTrainingDocs` key), used for routing,
  /// visibility checks, and icon/accent lookups.
  final String destinationId;

  final String docTitle;

  /// Chapter position and title, so the UI can deep-link the section.
  final BarrioSearchChapterRef chapter;

  final String unitTitle;

  /// Position of the answering unit within its chapter, so the UI can
  /// deep-link the exact card, not just the section.
  final int unitIndex;

  /// Verbatim excerpt: always exactly
  /// `unit.body.substring(excerptStart, excerptEnd)`.
  final String excerpt;

  /// Inclusive start offset of [excerpt] in the unit body.
  final int excerptStart;

  /// Exclusive end offset of [excerpt] in the unit body.
  final int excerptEnd;

  /// The normalized content terms that matched this unit, in query
  /// order. These are the highlight terms for the reader jump (content
  /// terms only, never the raw question words).
  final List<String> matchedTerms;

  /// BM25 relevance score of the answering unit. Comparable only
  /// within a single [BarrioTrainingAnswers.ask] result list.
  final double score;

  final BarrioAnswerConfidence confidence;

  const BarrioTrainingAnswer({
    required this.destinationId,
    required this.docTitle,
    required this.chapter,
    required this.unitTitle,
    required this.unitIndex,
    required this.excerpt,
    required this.excerptStart,
    required this.excerptEnd,
    required this.matchedTerms,
    required this.score,
    required this.confidence,
  });

  int get chapterIndex => chapter.index;

  String get chapterTitle => chapter.title;
}

/// One indexed unit: identity plus the cached folded body (for
/// sentence work) and token counts (for BM25 scoring).
class _AnswerUnit {
  final String destinationId;
  final BarrioTrainingDoc doc;
  final int chapterIndex;
  final int unitIndex;
  final HandbookUnit unit;

  /// Folded unit body; length-preserving, so every offset computed on
  /// it is valid on the original body (see barrio_training_search.dart
  /// for the offset-mapping rationale).
  final String foldedBody;

  /// Token occurrence counts over the folded searchable text (doc
  /// title, chapter title, unit title, body).
  final Map<String, int> tokenCounts;

  /// Total token count of the searchable text (BM25 length norm).
  final int tokenTotal;

  const _AnswerUnit({
    required this.destinationId,
    required this.doc,
    required this.chapterIndex,
    required this.unitIndex,
    required this.unit,
    required this.foldedBody,
    required this.tokenCounts,
    required this.tokenTotal,
  });
}

/// The lazily built corpus index: units in corpus order plus the
/// average token length BM25 normalizes against.
class _AnswerIndex {
  final List<_AnswerUnit> units;
  final double avgTokens;

  const _AnswerIndex(this.units, this.avgTokens);
}

/// One sentence span in fold space (== body space), edge-trimmed of
/// whitespace. `start` inclusive, `end` exclusive. `paragraph` is the
/// 0-based blank-line-separated block index: extension only crosses
/// sentence boundaries, never paragraph boundaries.
class _Sentence {
  final int start;
  final int end;
  final int paragraph;

  const _Sentence(this.start, this.end, this.paragraph);
}

class _ScoredAnswerUnit {
  final int corpusOrder;
  final double score;

  const _ScoredAnswerUnit(this.corpusOrder, this.score);
}

/// Question words and glue words stripped from a query before
/// retrieval. What remains are the content terms that actually select
/// and grade an answer ("What is the origin of tequila?" keeps only
/// "origin" and "tequila").
const Set<String> _kStopwords = <String>{
  'a', 'about', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but',
  'by', 'can', 'could', 'did', 'do', 'does', 'explain', 'for', 'from',
  'give', 'has', 'have', 'how', 'i', 'if', 'in', 'is', 'it', 'its',
  'me', 'my', 'no', 'not', 'of', 'on', 'or', 'our', 'please', 'shall',
  'should', 'show', 'so', 'tell', 'than', 'that', 'the', 'their',
  'them', 'then', 'there', 'these', 'they', 'this', 'those', 'to',
  'was', 'we', 'were', 'what', 'when', 'where', 'which', 'who', 'why',
  'will', 'with', 'would', 'you', 'your',
};

/// Offline extractive question answering over the verbatim training
/// manuals.
class BarrioTrainingAnswers {
  BarrioTrainingAnswers._();

  /// At most this many answers per asked question.
  static const int kMaxAnswers = 3;

  /// BM25 term-frequency saturation constant.
  static const double kBm25K1 = 1.2;

  /// BM25 length-normalization constant.
  static const double kBm25B = 0.75;

  /// While an excerpt is shorter than this, it extends to the next
  /// contiguous sentence (subject to [kExcerptCap]).
  static const int kExcerptGrowTarget = 90;

  /// Extension never grows an excerpt past this many characters. A
  /// single best sentence longer than the cap stays whole: the service
  /// never cuts mid-sentence, because a truncated sentence would
  /// misrepresent the source even though it is still a substring.
  static const int kExcerptCap = 320;

  /// Lazily built, cached index. Built exactly once per process, on
  /// the first asked question.
  static _AnswerIndex? _cachedIndex;

  /// Answers [query] with up to [kMaxAnswers] verbatim excerpts,
  /// ranked by BM25 relevance (ties broken by corpus order).
  ///
  /// Queries shorter than [BarrioTrainingSearch.kMinQueryLength] after
  /// trimming, and queries with no tokens at all, return an empty list
  /// (the [BarrioAnswerConfidence.none] tier). A query made only of
  /// stopwords falls back to retrieving on all its tokens so it never
  /// throws, but its results are capped at
  /// [BarrioAnswerConfidence.weak]: glue words alone cannot honestly
  /// answer anything.
  ///
  /// When [isDestinationAllowed] is provided, units of disallowed
  /// destinations are skipped entirely (mirrors
  /// [BarrioTrainingSearch.search]: an answer the user cannot open
  /// must not render, and the in-manual sheet scopes to one manual).
  static List<BarrioTrainingAnswer> ask(
    String query, {
    bool Function(String destinationId)? isDestinationAllowed,
  }) {
    final trimmed = query.trim();
    if (trimmed.length < BarrioTrainingSearch.kMinQueryLength) {
      return const <BarrioTrainingAnswer>[];
    }
    final tokens = _tokenize(BarrioTrainingSearch.fold(trimmed));
    if (tokens.isEmpty) return const <BarrioTrainingAnswer>[];

    // Distinct content terms in first-seen query order.
    final seen = <String>{};
    final terms = <String>[];
    for (final token in tokens) {
      if (!_kStopwords.contains(token) && seen.add(token)) {
        terms.add(token);
      }
    }
    final allStopwords = terms.isEmpty;
    if (allStopwords) {
      for (final token in tokens) {
        if (seen.add(token)) terms.add(token);
      }
    }

    final index = _index();
    final units = index.units;
    final n = units.length;
    if (n == 0) return const <BarrioTrainingAnswer>[];

    // BM25 accumulation. Document frequency and length norms come from
    // the full corpus regardless of the visibility filter, so a term's
    // weight is stable and deterministic; the filter only decides which
    // scored units may be returned.
    final scores = List<double>.filled(n, 0);
    for (final term in terms) {
      final variants = _variants(term);
      var df = 0;
      for (var i = 0; i < n; i++) {
        if (_termFrequency(units[i], variants) > 0) df++;
      }
      if (df == 0) continue;
      final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
      for (var i = 0; i < n; i++) {
        final tf = _termFrequency(units[i], variants);
        if (tf == 0) continue;
        final lengthNorm = 1 -
            kBm25B +
            kBm25B * units[i].tokenTotal / index.avgTokens;
        scores[i] += idf * tf * (kBm25K1 + 1) / (tf + kBm25K1 * lengthNorm);
      }
    }

    final scored = <_ScoredAnswerUnit>[];
    for (var i = 0; i < n; i++) {
      if (scores[i] <= 0) continue;
      if (isDestinationAllowed != null &&
          !isDestinationAllowed(units[i].destinationId)) {
        continue;
      }
      scored.add(_ScoredAnswerUnit(i, scores[i]));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.corpusOrder.compareTo(b.corpusOrder);
    });

    final answers = <BarrioTrainingAnswer>[];
    for (final s in scored) {
      if (answers.length >= kMaxAnswers) break;
      final answer = _extract(
        units[s.corpusOrder],
        terms,
        s.score,
        capAtWeak: allStopwords,
      );
      if (answer != null) answers.add(answer);
    }
    return answers;
  }

  /// Folds a result list back to one tier: [BarrioAnswerConfidence.none]
  /// for an empty list, [BarrioAnswerConfidence.answer] when any entry
  /// clears the answer bar, else [BarrioAnswerConfidence.weak].
  static BarrioAnswerConfidence overallConfidence(
    List<BarrioTrainingAnswer> answers,
  ) {
    if (answers.isEmpty) return BarrioAnswerConfidence.none;
    for (final a in answers) {
      if (a.confidence == BarrioAnswerConfidence.answer) {
        return BarrioAnswerConfidence.answer;
      }
    }
    return BarrioAnswerConfidence.weak;
  }

  /// Lowercase alphanumeric runs of an already-folded string.
  static final RegExp _kTokenPattern = RegExp(r'[a-z0-9]+');

  static List<String> _tokenize(String folded) {
    return <String>[
      for (final m in _kTokenPattern.allMatches(folded)) m.group(0)!,
    ];
  }

  /// Light plural probing: a query term also matches its `term + s`
  /// form, and (for terms of 4+ characters ending in `s`) the form
  /// with the trailing `s` removed. No stemming beyond that.
  static List<String> _variants(String term) {
    final variants = <String>[term, '${term}s'];
    if (term.length >= 4 && term.endsWith('s')) {
      variants.add(term.substring(0, term.length - 1));
    }
    return variants;
  }

  /// Summed occurrences of all [variants] in the unit's searchable
  /// text (0 when the term is absent in every form).
  static int _termFrequency(_AnswerUnit unit, List<String> variants) {
    var total = 0;
    for (final v in variants) {
      total += unit.tokenCounts[v] ?? 0;
    }
    return total;
  }

  /// Builds one answer from a retrieved unit: picks the best sentence,
  /// extends it, grades confidence, and cuts the verbatim excerpt.
  /// Returns null only when the body has no sentences at all.
  static BarrioTrainingAnswer? _extract(
    _AnswerUnit entry,
    List<String> terms,
    double score, {
    required bool capAtWeak,
  }) {
    final sentences = _splitSentences(entry.foldedBody);
    if (sentences.isEmpty) return null;

    // Best sentence: most distinct content terms; ties by total term
    // frequency, then earliest position (strict-greater comparisons
    // keep the earliest sentence on full ties).
    var bestIdx = 0;
    var bestDistinct = -1;
    var bestTf = -1;
    for (var i = 0; i < sentences.length; i++) {
      final s = sentences[i];
      final counts = _sentenceTokenCounts(entry.foldedBody, s);
      var distinct = 0;
      var tf = 0;
      for (final term in terms) {
        var termTf = 0;
        for (final v in _variants(term)) {
          termTf += counts[v] ?? 0;
        }
        if (termTf > 0) {
          distinct++;
          tf += termTf;
        }
      }
      if (distinct > bestDistinct ||
          (distinct == bestDistinct && tf > bestTf)) {
        bestIdx = i;
        bestDistinct = distinct;
        bestTf = tf;
      }
    }

    // Confidence is graded on the best sentence alone (the seed of the
    // excerpt), before extension: extension adds context, never
    // evidence. The 60% bar uses integer math so the comparison is
    // exact.
    final coversAll = bestDistinct >= terms.length;
    final clearsBar =
        coversAll || (bestDistinct >= 2 && bestDistinct * 10 >= terms.length * 6);
    final confidence = (clearsBar && !capAtWeak)
        ? BarrioAnswerConfidence.answer
        : BarrioAnswerConfidence.weak;

    // Extend short excerpts with the sentences immediately after the
    // seed (same paragraph only), stopping at the grow target and
    // never past the cap. The excerpt stays one contiguous span, so
    // the verbatim law holds by construction.
    final seed = sentences[bestIdx];
    final start = seed.start;
    var end = seed.end;
    var next = bestIdx + 1;
    while (end - start < kExcerptGrowTarget &&
        next < sentences.length &&
        sentences[next].paragraph == seed.paragraph) {
      if (sentences[next].end - start > kExcerptCap) break;
      end = sentences[next].end;
      next++;
    }

    // Content terms that matched this unit, in query order: these are
    // the reader-jump highlight terms.
    final matched = <String>[
      for (final term in terms)
        if (_termFrequency(entry, _variants(term)) > 0) term,
    ];

    return BarrioTrainingAnswer(
      destinationId: entry.destinationId,
      docTitle: entry.doc.title,
      chapter: BarrioSearchChapterRef(
        entry.chapterIndex,
        entry.doc.chapters[entry.chapterIndex].title,
      ),
      unitTitle: entry.unit.title,
      unitIndex: entry.unitIndex,
      excerpt: entry.unit.body.substring(start, end),
      excerptStart: start,
      excerptEnd: end,
      matchedTerms: matched,
      score: score,
      confidence: confidence,
    );
  }

  /// Splits a folded body into edge-trimmed sentence spans with
  /// absolute offsets: paragraphs on blank lines first, then sentences
  /// on runs of `.`, `!`, `?` followed by whitespace (or paragraph
  /// end). A period not followed by whitespace (a decimal like 3.5, an
  /// abbreviation glued to a quote) does not split. Fold space equals
  /// body space (length-preserving fold), so these offsets cut the
  /// original body directly.
  static List<_Sentence> _splitSentences(String folded) {
    final sentences = <_Sentence>[];
    var paragraph = 0;
    var pStart = 0;
    while (pStart < folded.length) {
      var pEnd = folded.indexOf('\n\n', pStart);
      if (pEnd < 0) pEnd = folded.length;
      _splitParagraph(folded, pStart, pEnd, paragraph, sentences);
      paragraph++;
      pStart = pEnd + 2;
    }
    return sentences;
  }

  static bool _isSentenceEnder(int codeUnit) {
    return codeUnit == 0x2E || codeUnit == 0x21 || codeUnit == 0x3F;
  }

  static bool _isWhitespace(int codeUnit) {
    return codeUnit == 0x20 ||
        codeUnit == 0x0A ||
        codeUnit == 0x09 ||
        codeUnit == 0x0D;
  }

  static void _splitParagraph(
    String folded,
    int pStart,
    int pEnd,
    int paragraph,
    List<_Sentence> out,
  ) {
    var cursor = pStart;
    var i = pStart;
    while (i < pEnd) {
      if (!_isSentenceEnder(folded.codeUnitAt(i))) {
        i++;
        continue;
      }
      // Absorb the whole ender run (e.g. '?!' or '...').
      var j = i + 1;
      while (j < pEnd && _isSentenceEnder(folded.codeUnitAt(j))) {
        j++;
      }
      final endsSentence = j >= pEnd || _isWhitespace(folded.codeUnitAt(j));
      if (endsSentence) {
        _addTrimmed(folded, cursor, j, paragraph, out);
        cursor = j;
      }
      i = j;
    }
    // Tail without a closing ender is still a sentence.
    _addTrimmed(folded, cursor, pEnd, paragraph, out);
  }

  /// Adds [start, end) trimmed of edge whitespace; drops empty spans.
  static void _addTrimmed(
    String folded,
    int start,
    int end,
    int paragraph,
    List<_Sentence> out,
  ) {
    var s = start;
    var e = end;
    while (s < e && _isWhitespace(folded.codeUnitAt(s))) {
      s++;
    }
    while (e > s && _isWhitespace(folded.codeUnitAt(e - 1))) {
      e--;
    }
    if (s < e) out.add(_Sentence(s, e, paragraph));
  }

  /// Token counts of one sentence span of the folded body.
  static Map<String, int> _sentenceTokenCounts(String folded, _Sentence s) {
    final counts = <String, int>{};
    for (final m in _kTokenPattern.allMatches(folded.substring(s.start, s.end))) {
      final token = m.group(0)!;
      counts[token] = (counts[token] ?? 0) + 1;
    }
    return counts;
  }

  /// The cached index, built on first use. Iteration order of
  /// `kBarrioTrainingDocs` (insertion-ordered map) defines corpus
  /// order: registry order, then chapter, then unit, matching
  /// BarrioTrainingSearch exactly.
  static _AnswerIndex _index() {
    final cached = _cachedIndex;
    if (cached != null) return cached;
    final units = <_AnswerUnit>[];
    var totalTokens = 0;
    kBarrioTrainingDocs.forEach((destinationId, doc) {
      for (var c = 0; c < doc.chapters.length; c++) {
        final chapter = doc.chapters[c];
        for (var u = 0; u < chapter.units.length; u++) {
          final unit = chapter.units[u];
          final foldedBody = BarrioTrainingSearch.fold(unit.body);
          final foldedScope = BarrioTrainingSearch.fold(
            '${doc.title}\n${chapter.title}\n${unit.title}',
          );
          final counts = <String, int>{};
          var tokenTotal = 0;
          for (final token in _tokenize(foldedScope)) {
            counts[token] = (counts[token] ?? 0) + 1;
            tokenTotal++;
          }
          for (final token in _tokenize(foldedBody)) {
            counts[token] = (counts[token] ?? 0) + 1;
            tokenTotal++;
          }
          units.add(
            _AnswerUnit(
              destinationId: destinationId,
              doc: doc,
              chapterIndex: c,
              unitIndex: u,
              unit: unit,
              foldedBody: foldedBody,
              tokenCounts: counts,
              tokenTotal: tokenTotal,
            ),
          );
          totalTokens += tokenTotal;
        }
      }
    });
    final avg = units.isEmpty ? 1.0 : totalTokens / units.length;
    final built = _AnswerIndex(units, avg);
    _cachedIndex = built;
    return built;
  }
}
