// Deterministic analyzer that reads HistoryPatternRecords and returns
// a teaching summary: most common leak, where it repeats, and benchmark
// dayparts to study against it.

import '../data/app_defaults.dart';
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

  const HistoryTeachingSummary({
    required this.mostCommonLeakId,
    required this.mostCommonLeakCount,
    required this.mostCommonLeakSideLabel,
    required this.topLeakDayparts,
    required this.benchmarkDayparts,
    required this.mostCommonBenchmarkId,
    required this.mostCommonBenchmarkCount,
    required this.mostCommonBenchmarkSideLabel,
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
  // reset because applying this allow-list there would push the
  // all-unknown case onto the F-2 default `'covers_down'` (line 69) and
  // re-introduce the silent overclaim until 7.61.2 flips that default
  // to `''`.
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

    // Most common leak with tie-break.
    String mostCommonLeakId = 'covers_down';
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

    // 7.61.1 (F-1): null-safe lookup. An unknown id (or an empty
    // mostCommonLeakId once 7.61.2 flips the empty-state default) zeros
    // out every leak summary field — id, count, dayparts, side label —
    // so downstream copy in LearnTeachingAnalyzer can't stitch a
    // "Fix no leak pattern yet first in <real daypart>" sentence out of
    // a phantom lever. R-CONS-2 + R-CONS-9 + R-STOR-7. The empty-state
    // default at line 69 is owned by 7.61.2 and intentionally unchanged.
    final LeverCardData? leakCard = LeverCards.lookup(mostCommonLeakId);
    if (leakCard == null) {
      mostCommonLeakId = '';
      maxCount = 0;
    }

    // Top 2 dayparts for the most common leak. After an unknown-id reset
    // mostCommonLeakId is '', which never matches r.leverId, so this stays
    // empty — symmetric with the "no pattern" state.
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

    return HistoryTeachingSummary(
      mostCommonLeakId: mostCommonLeakId,
      mostCommonLeakCount: maxCount,
      mostCommonLeakSideLabel: leakCard?.sideLabel ?? 'No leak pattern yet',
      topLeakDayparts: topLeakDayparts,
      benchmarkDayparts: benchmarkDayparts,
      mostCommonBenchmarkId: mostCommonBenchmarkId,
      mostCommonBenchmarkCount: benchMaxCount,
      mostCommonBenchmarkSideLabel: mostCommonBenchmarkSideLabel,
    );
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
