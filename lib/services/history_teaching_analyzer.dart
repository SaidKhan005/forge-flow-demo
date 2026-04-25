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

    final leakCard = LeverCards.all.firstWhere(
      (l) => l.id == mostCommonLeakId,
      orElse: () => LeverCards.coversDown,
    );

    // Top 2 dayparts for the most common leak.
    final leakDpFreq = <String, int>{};
    for (final r in leakRecords.where((r) => r.leverId == mostCommonLeakId)) {
      leakDpFreq[r.fullLabel] = (leakDpFreq[r.fullLabel] ?? 0) + 1;
    }
    final topLeakDayparts = _topTwo(leakDpFreq);

    // Top 2 benchmark dayparts.
    final benchFreq = <String, int>{};
    final benchmarkRecords = records.where((r) => r.isBenchmark).toList();
    for (final r in benchmarkRecords) {
      benchFreq[r.fullLabel] = (benchFreq[r.fullLabel] ?? 0) + 1;
    }
    final benchmarkDayparts = _topTwo(benchFreq);

    // Most common benchmark lever pattern.
    String mostCommonBenchmarkId = '';
    int benchMaxCount = 0;
    String mostCommonBenchmarkSideLabel = 'No benchmark pattern yet';

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
      final benchCard = LeverCards.all.firstWhere(
        (l) => l.id == mostCommonBenchmarkId,
        orElse: () => LeverCards.ppaUp,
      );
      mostCommonBenchmarkSideLabel = benchCard.sideLabel;
    }

    return HistoryTeachingSummary(
      mostCommonLeakId: mostCommonLeakId,
      mostCommonLeakCount: maxCount,
      mostCommonLeakSideLabel: leakCard.sideLabel,
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
