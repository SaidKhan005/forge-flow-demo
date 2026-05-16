// Deterministic analyzer that reads HistoryPatternRecords and returns
// a teaching summary: most common leak, where it repeats, and benchmark
// dayparts to study against it.

import '../domain/constants/app_defaults.dart';
import '../domain/constants/cross_axis_pair_catalog.dart';
import '../models/cross_axis_pair_record.dart';
import '../models/history_pattern_record.dart';

class HistoryTeachingSummary {
  final String mostCommonLeakId;
  final int mostCommonLeakCount;
  final String mostCommonLeakSideLabel;
  final List<String> topLeakDayparts;
  final List<String> benchmarkDayparts;
  final String mostCommonBenchmarkId;
  final int mostCommonBenchmarkCount;
  final String mostCommonBenchmarkSideLabel;

  /// Per-Daypart V1 (Slice D, Gap 39): the single service period the
  /// dominant leak repeats in most often (a `fullLabel` such as
  /// `Fri Dinner`), and how many times it repeated there. These let the
  /// Learn narration resolve to the period the pattern actually lives in
  /// instead of the whole day. Empty string / `0` when there is no
  /// recurring leak — the narration falls back to the existing general
  /// copy (Metric Honesty: no period is named that the data does not
  /// support). Derived from the same `leakDpFreq` the existing
  /// [topLeakDayparts] is built from; not a new source of truth.
  final String topLeakDaypartLabel;
  final int topLeakDaypartCount;

  /// Per-Daypart V1 (Slice D, Gap 39): a benchmark `fullLabel` on the
  /// SAME day of week as [topLeakDaypartLabel] but a different service
  /// period (e.g. `Fri Lunch` when the leak lives in `Fri Dinner`), so
  /// the narration can draw the period contrast Decision 13 describes
  /// ("Friday dinners run over while Friday lunches are dead on").
  /// `null` when no prominent same-day benchmark exists — the contrast
  /// clause is then omitted rather than invented.
  final String? contrastBenchmarkDaypartLabel;

  /// 7.58.cross-axis.0 — recurring CPLH x SPLH pair patterns observed
  /// across the closed-shift history window. Records are sorted by
  /// `count` descending. Empty when no (week, daypart) bucket has both
  /// a `cplh_*` lever and a `splh_*` lever firing. Single-axis-only
  /// shifts never contribute to pair counts.
  ///
  /// Each `pairId` matches a `CrossAxisPairData.id` in
  /// `lib/domain/constants/cross_axis_pair_catalog.dart`; consumers resolve through
  /// `CrossAxisPairs.lookup`. The single-axis path
  /// (`mostCommonLeakId` etc.) is unchanged by this field — the
  /// cross-axis pair detector runs in parallel and only fires when
  /// both axes appear in the same bucket.
  final List<CrossAxisPairRecord> crossAxisPairs;

  const HistoryTeachingSummary({
    required this.mostCommonLeakId,
    required this.mostCommonLeakCount,
    required this.mostCommonLeakSideLabel,
    required this.topLeakDayparts,
    required this.benchmarkDayparts,
    required this.mostCommonBenchmarkId,
    required this.mostCommonBenchmarkCount,
    required this.mostCommonBenchmarkSideLabel,
    this.crossAxisPairs = const [],
    this.topLeakDaypartLabel = '',
    this.topLeakDaypartCount = 0,
    this.contrastBenchmarkDaypartLabel,
  });
}

class HistoryTeachingAnalyzer {
  // Tie-break order: most operationally impactful leak type wins.
  static const _tieBreakOrder = [
    'cplh_down',
    'splh_down',
    'ppa_down',
    'covers_down',
    'foh_wage_up',
    'boh_wage_up',
  ];

  // Tie-break order for benchmark patterns.
  static const _benchmarkTieBreakOrder = [
    'ppa_up',
    'cplh_up',
    'splh_up',
    'covers_up',
    'foh_wage_down',
    'boh_wage_down',
  ];

  static final _favorableIds = LeverCards.all
      .where((l) => l.isFavorable)
      .map((l) => l.id)
      .toSet();

  // 7.61.1 (F-1): catalog allow-list applied to the benchmark side at
  // the record-filter layer so that neither the tie-break frequency
  // (`bFreq`) nor the daypart frequency (`benchFreq`) ever sees an
  // unknown id. The leak side keeps the post-tie-break `LeverCards.lookup`
  // reset because the empty-state default at line 79 is now `''`
  // (7.61.2, F-2): an all-unknown leak set still produces an empty id
  // through the tie-break and the `lookup` reset zeros the rest of the
  // envelope. Pre-7.61.2 the default was `'covers_down'`, so applying
  // the allow-list here would have pushed the all-unknown case onto a
  // real lever card.
  static final _knownLeverIds = LeverCards.all.map((l) => l.id).toSet();

  static HistoryTeachingSummary summarize(List<HistoryPatternRecord> records) {
    // Leak candidates: not a benchmark AND not a favorable lever.
    final leakRecords = records
        .where((r) => !r.isBenchmark && !_favorableIds.contains(r.leverId))
        .toList();

    // Frequency of each leverId among leaks.
    final freq = <String, int>{};
    for (final r in leakRecords) {
      freq[r.leverId] = (freq[r.leverId] ?? 0) + 1;
    }

    // Most common leak with tie-break. 7.61.2 (F-2): empty default is
    // `''`, not `'covers_down'`. With zero leak records, the analyzer
    // returns an empty id and the post-tie-break `lookup` reset below
    // zeros the count and dayparts together; line 177 falls back to
    // `'No leak pattern yet'` symmetric with the benchmark side. Pre-fix
    // an empty leak set still surfaced `'covers_down'`, which
    // `LearnTeachingAnalyzer` stamped into `primaryLeakId` and
    // `variance_learn_tab.dart:151-153` materialised as a real leak card
    // the operator had not earned. R-CONS-9.
    String mostCommonLeakId = '';
    int maxCount = 0;
    if (freq.isNotEmpty) {
      maxCount = freq.values.reduce((a, b) => a > b ? a : b);
      final tied = freq.entries
          .where((e) => e.value == maxCount)
          .map((e) => e.key)
          .toList();
      tied.sort((a, b) {
        final ai = _tieBreakOrder.indexOf(a);
        final bi = _tieBreakOrder.indexOf(b);
        // Unlisted ids sort last.
        final ai2 = ai < 0 ? 999 : ai;
        final bi2 = bi < 0 ? 999 : bi;
        return ai2.compareTo(bi2);
      });
      mostCommonLeakId = tied.first;
    }

    // 7.61.1 (F-1) + 7.61.2 (F-2): null-safe lookup. An unknown id
    // OR the post-7.61.2 empty-state default (`''`) zeros out every
    // leak summary field — id, count, dayparts, side label — so
    // downstream copy in LearnTeachingAnalyzer can't stitch a
    // "Fix no leak pattern yet first in <real daypart>" sentence out
    // of a phantom lever. R-CONS-2 + R-CONS-9 + R-STOR-7. With the
    // empty-state default flipped, the empty-set path and the
    // unknown-id path now share this same null-lookup branch.
    final LeverCardData? leakCard = LeverCards.lookup(mostCommonLeakId);
    if (leakCard == null) {
      mostCommonLeakId = '';
      maxCount = 0;
    }

    // Top 2 dayparts for the most common leak. After an empty-set OR
    // unknown-id reset, mostCommonLeakId is '', which never matches
    // r.leverId, so this stays empty — symmetric with the "no pattern"
    // state.
    final leakDpFreq = <String, int>{};
    for (final r in leakRecords.where((r) => r.leverId == mostCommonLeakId)) {
      leakDpFreq[r.fullLabel] = (leakDpFreq[r.fullLabel] ?? 0) + 1;
    }
    final topLeakDayparts = _topTwo(leakDpFreq);

    // 7.61.1 (F-1): filter benchmark records to known catalog ids upstream
    // so the tie-break (`bFreq`) and dayparts (`benchFreq`) computations
    // both ignore unknown-id rows. Pre-fix, a known winner could still
    // ship an unknown record's daypart in `benchmarkDayparts` because
    // `benchFreq` aggregated across all benchmark records regardless of
    // leverId — `LearnTeachingAnalyzer.studyLine` would then say
    // "Study benchmark dayparts: <unknown record's daypart>." even
    // though the most-common id was real. R-CONS-2 + R-CONS-9 + R-STOR-7.
    final benchmarkRecords = records
        .where((r) => r.isBenchmark && _knownLeverIds.contains(r.leverId))
        .toList();

    // Most common benchmark lever pattern + its dayparts.
    String mostCommonBenchmarkId = '';
    int benchMaxCount = 0;
    String mostCommonBenchmarkSideLabel = 'No benchmark pattern yet';
    List<String> benchmarkDayparts = const [];

    if (benchmarkRecords.isNotEmpty) {
      final bFreq = <String, int>{};
      for (final r in benchmarkRecords) {
        bFreq[r.leverId] = (bFreq[r.leverId] ?? 0) + 1;
      }
      benchMaxCount = bFreq.values.reduce((a, b) => a > b ? a : b);
      final tied = bFreq.entries
          .where((e) => e.value == benchMaxCount)
          .map((e) => e.key)
          .toList();
      tied.sort((a, b) {
        final ai = _benchmarkTieBreakOrder.indexOf(a);
        final bi = _benchmarkTieBreakOrder.indexOf(b);
        final ai2 = ai < 0 ? 999 : ai;
        final bi2 = bi < 0 ? 999 : bi;
        return ai2.compareTo(bi2);
      });
      mostCommonBenchmarkId = tied.first;
      // 7.61.1 (F-1): defense-in-depth. With the upstream `_knownLeverIds`
      // filter on `benchmarkRecords` above, every id in `bFreq` is in the
      // catalog and `lookup` never returns null on this path. The else
      // branch stays as a guardrail in case the filter is ever loosened.
      final LeverCardData? benchCard = LeverCards.lookup(mostCommonBenchmarkId);
      if (benchCard != null) {
        mostCommonBenchmarkSideLabel = benchCard.sideLabel;
        final benchFreq = <String, int>{};
        for (final r in benchmarkRecords) {
          benchFreq[r.fullLabel] = (benchFreq[r.fullLabel] ?? 0) + 1;
        }
        benchmarkDayparts = _topTwo(benchFreq);
      } else {
        mostCommonBenchmarkId = '';
        benchMaxCount = 0;
      }
    }

    final crossAxisPairs = _detectCrossAxisPairs(records);

    // Per-Daypart V1 (Slice D, Gap 39) — resolve the dominant leak to
    // the single service period it repeats in most. `topLeakDayparts` is
    // already the top-2 `fullLabel`s by frequency for `mostCommonLeakId`;
    // its first entry is the period the pattern lives in, and
    // `leakDpFreq` holds the real repeat count for that period. Both stay
    // empty when there is no recurring leak (empty-set / unknown-id reset
    // above), so the Learn copy honestly falls back to general guidance.
    final topLeakDaypartLabel =
        topLeakDayparts.isNotEmpty ? topLeakDayparts.first : '';
    final topLeakDaypartCount = topLeakDaypartLabel.isEmpty
        ? 0
        : (leakDpFreq[topLeakDaypartLabel] ?? 0);

    // Same-day, different-period benchmark for the Decision 13 contrast
    // clause. Only a prominent benchmark (already in `benchmarkDayparts`,
    // i.e. the top-2 favorable periods) qualifies, so the "while X holds
    // on plan" half of the sentence is never fabricated. `fullLabel` is
    // `'<Day> <Period>'`; the first token is the day of week.
    String? contrastBenchmarkDaypartLabel;
    if (topLeakDaypartLabel.isNotEmpty) {
      final leakDayToken = topLeakDaypartLabel.split(' ').first;
      for (final b in benchmarkDayparts) {
        if (b != topLeakDaypartLabel &&
            b.split(' ').first == leakDayToken) {
          contrastBenchmarkDaypartLabel = b;
          break;
        }
      }
    }

    return HistoryTeachingSummary(
      mostCommonLeakId: mostCommonLeakId,
      mostCommonLeakCount: maxCount,
      mostCommonLeakSideLabel: leakCard?.sideLabel ?? 'No leak pattern yet',
      topLeakDayparts: topLeakDayparts,
      benchmarkDayparts: benchmarkDayparts,
      mostCommonBenchmarkId: mostCommonBenchmarkId,
      mostCommonBenchmarkCount: benchMaxCount,
      mostCommonBenchmarkSideLabel: mostCommonBenchmarkSideLabel,
      crossAxisPairs: crossAxisPairs,
      topLeakDaypartLabel: topLeakDaypartLabel,
      topLeakDaypartCount: topLeakDaypartCount,
      contrastBenchmarkDaypartLabel: contrastBenchmarkDaypartLabel,
    );
  }

  // 7.58.cross-axis.0 — recurring CPLH x SPLH pair pattern detector.
  //
  // Bucket records by (weekId, daypart). A bucket contributes to a
  // cell ONLY when both a `cplh_*` lever and a `splh_*` lever fired
  // among its records. Single-axis-only buckets are ignored.
  //
  // Within a paired bucket the dominant CPLH and SPLH directions are
  // the most-frequent lever ids on each axis (tie-break: `cplh_down`
  // and `splh_down` win, mirroring the leak-side tie-break order so
  // operationally impactful directions surface first). The directional
  // pair maps to one of the locked catalog ids in
  // `CrossAxisPairs.all`. Combinations outside the catalog (e.g. both
  // axes above target) produce no record.
  //
  // The returned list is sorted by `count` descending, then by
  // `pairId` ascending for determinism. `count` is the total number
  // of contributing records (cplh_* + splh_*) across all paired
  // buckets in the cell. `topDayparts` is the top 2 fullLabel entries
  // by record frequency, sorted by count desc then label asc — same
  // shape the single-axis `topLeakDayparts` field uses.
  static List<CrossAxisPairRecord> _detectCrossAxisPairs(
    List<HistoryPatternRecord> records,
  ) {
    if (records.isEmpty) return const [];

    // Group records by (weekId, daypart).
    final buckets = <String, List<HistoryPatternRecord>>{};
    for (final r in records) {
      final key = '${r.weekId}|${r.daypart}';
      buckets.putIfAbsent(key, () => <HistoryPatternRecord>[]).add(r);
    }

    final cellRecords = <String, List<HistoryPatternRecord>>{};

    for (final entry in buckets.entries) {
      final bucket = entry.value;
      final cplhRecs = bucket
          .where((r) => r.leverId == 'cplh_down' || r.leverId == 'cplh_up')
          .toList();
      final splhRecs = bucket
          .where((r) => r.leverId == 'splh_down' || r.leverId == 'splh_up')
          .toList();

      // Detection rule: both CPLH and SPLH lever ids must have fired
      // for this (weekId, daypart). Single-axis-only buckets skip.
      if (cplhRecs.isEmpty || splhRecs.isEmpty) continue;

      final cplhDownCount =
          cplhRecs.where((r) => r.leverId == 'cplh_down').length;
      final cplhUpCount = cplhRecs.length - cplhDownCount;
      final splhDownCount =
          splhRecs.where((r) => r.leverId == 'splh_down').length;
      final splhUpCount = splhRecs.length - splhDownCount;

      // Tie-break: `cplh_down` / `splh_down` win on equality.
      final cplhBelow = cplhDownCount >= cplhUpCount;
      final splhBelow = splhDownCount >= splhUpCount;

      String? cellId;
      if (cplhBelow && !splhBelow) {
        cellId = CrossAxisPairs.cplhBelowSplhAbove.id;
      } else if (!cplhBelow && splhBelow) {
        cellId = CrossAxisPairs.cplhAboveSplhBelow.id;
      } else if (cplhBelow && splhBelow) {
        cellId = CrossAxisPairs.bothBelow.id;
      }
      // Both-above (cplh_up + splh_up) is outside the locked V1
      // catalog: no record emitted.

      if (cellId == null) continue;

      final cellList =
          cellRecords.putIfAbsent(cellId, () => <HistoryPatternRecord>[]);
      cellList.addAll(cplhRecs);
      cellList.addAll(splhRecs);
    }

    final result = <CrossAxisPairRecord>[];
    for (final entry in cellRecords.entries) {
      final dpFreq = <String, int>{};
      for (final r in entry.value) {
        dpFreq[r.fullLabel] = (dpFreq[r.fullLabel] ?? 0) + 1;
      }
      result.add(CrossAxisPairRecord(
        pairId: entry.key,
        count: entry.value.length,
        topDayparts: _topTwo(dpFreq),
      ));
    }
    result.sort((a, b) {
      final cmp = b.count.compareTo(a.count);
      return cmp != 0 ? cmp : a.pairId.compareTo(b.pairId);
    });
    return result;
  }

  // Returns up to 2 entries sorted by count descending, then label ascending.
  static List<String> _topTwo(Map<String, int> freq) {
    if (freq.isEmpty) return [];
    final sorted = freq.entries.toList()
      ..sort((a, b) {
        final cmp = b.value.compareTo(a.value);
        return cmp != 0 ? cmp : a.key.compareTo(b.key);
      });
    return sorted.take(2).map((e) => e.key).toList();
  }
}
