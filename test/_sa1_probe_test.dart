// TEMP PROBE — deleted before commit. Measures the SA→SB pipeline.
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';

double _stdev(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = xs.reduce((a, b) => a + b) / xs.length;
  return math.sqrt(
      xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / xs.length);
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _mad(List<double> sorted, double med) {
  if (sorted.isEmpty) return 0;
  final dev = sorted.map((x) => (x - med).abs()).toList()..sort();
  return _median(dev);
}

void main() {
  test('PROBE pipeline', () {
    final cands = <BaselineCandidateShift>[];
    for (final s in MockIntegrationReplaySeed.output.historicalClosedShifts) {
      cands.add(BaselineCandidateShift(
        recordKey: '${s.weekId}|${s.dayLabel}|${s.daypart}',
        weekId: s.weekId,
        weekLabel: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        covers: s.covers,
        cplh: s.cplh,
        splh: s.splh,
        ppa: s.ppa,
        primaryLeverId: s.normalizedLeverId,
        isSelected: false,
        businessDate: s.businessDate,
        actualLaborPct: s.totalLaborPct,
        hasActualLaborPctTruth: s.hasSourceBackedTotalLaborPct,
      ));
    }
    for (final dp in ['lunch', 'dinner', 'late_night']) {
      final xs = cands.where((c) => c.daypart == dp).toList();
      final cplh = xs.map((e) => e.cplh).toList();
      // replicate MAD on full cohort (gates: covers>=20, hours>=2 — all pass)
      final sorted = [...cplh]..sort();
      final med = _median(sorted);
      final amad = _mad(sorted, med) * 1.4826;
      final thr = 3.0 * amad;
      final kept = xs
          .where((c) => !(amad > 0 && (c.cplh - med).abs() > thr))
          .toList();
      final keptC = kept.map((e) => e.cplh).toList();
      final medC = _median(keptC);
      final medS = _median(kept.map((e) => e.splh).toList());
      final medP = _median(kept.map((e) => e.ppa).toList());
      final bench = kept
          .where((c) => c.cplh >= medC && c.splh >= medS && c.ppa >= medP)
          .toList();
      // ignore: avoid_print
      print('$dp  n=${xs.length} fullSdCPLH=${_stdev(cplh).toStringAsFixed(4)} '
          'kept=${kept.length} keptSdCPLH=${_stdev(keptC).toStringAsFixed(4)} '
          'bench(all3strong)=${bench.length}');
    }
    // late_night detail
    final ln = cands.where((c) => c.daypart == 'late_night').toList();
    final lc = ln.map((e) => e.cplh).toList();
    final lmedC = _median(lc);
    final lmedS = _median(ln.map((e) => e.splh).toList());
    final lmedP = _median(ln.map((e) => e.ppa).toList());
    for (final c in ln..sort((a, b) => a.recordKey.compareTo(b.recordKey))) {
      final strong = c.cplh >= lmedC && c.splh >= lmedS && c.ppa >= lmedP;
      // ignore: avoid_print
      print('LN ${c.recordKey} day=${c.dayLabel} cplh=${c.cplh} '
          'splh=${c.splh} ppa=${c.ppa} lever=${c.primaryLeverId} '
          'strong=$strong');
    }
    // ignore: avoid_print
    print('LN medians C=$lmedC S=$lmedS P=$lmedP');
    final res = RecommendedBenchmarkSelectionService.instance.select(cands);
    for (final e in res.perDaypartStats.entries) {
      // ignore: avoid_print
      print('VERDICT ${e.key} = ${e.value.verdict} '
          'sel=${e.value.selectedCount} '
          'band=[${e.value.opzFloorCPLH.toStringAsFixed(3)},'
          '${e.value.opzCeilingCPLH.toStringAsFixed(3)}]');
    }
    // ignore: avoid_print
    print('OVERALL = ${res.overallQuality}');
  });
}
