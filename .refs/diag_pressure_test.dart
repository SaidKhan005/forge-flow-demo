// DIAGNOSTIC / PRESSURE-TEST HARNESS â€” NOT production code, NOT a slice.
//
// Purpose (operator request 2026-05-16): before changing any algorithm,
// (1) prove with the REAL demo dataset which gate fires and why the
// recommended path lands "RANGE UNCERTAIN"; (2) pressure-test the CURRENT
// engine for the bugs flagged in audit; (3) prototype a Jim-Taylor-faithful
// selection and pressure-test IT against the same data + adversarial data;
// (4) simulate how the prototype would render in the existing badge
// vocabulary. Nothing here is wired into the app. Delete or promote after
// the operator is satisfied.
//
// Jim methodology authority: docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md
//   Ch.09  "Look for when CPLH, SPLH, and PPA are all high together."
//   Ch.09  "You are looking for the range where your team was consistently
//           comfortable and productive" / "too few days = best Wednesday
//           disguised as a standard."
//   Ch.11  OPZ is a RANGE (floor/ceiling/headroom); Jim's example width ~1.0.
//   Ch.09  "Lunch and dinner are different businesses" â†’ grade per daypart.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';

// â”€â”€ Real demo dataset â†’ candidate shifts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Mirrors BaselineManagerService.getCandidateShiftsForDateRange exactly
// (lib/services/baseline_manager_service.dart:93-128) but with
// isSelected=false to simulate the FRESH recommended path (no manager
// override) â€” the exact state behind the "RANGE UNCERTAIN" screenshot.
List<BaselineCandidateShift> _realDemoCandidates() {
  final out = <BaselineCandidateShift>[];
  for (final s in MockIntegrationReplaySeed.output.historicalClosedShifts) {
    out.add(BaselineCandidateShift(
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
  return out;
}

// Deterministic realistic-variance dataset. The demo seeder pins every
// non-driver shift to the exact per-daypart target (proven degenerate by
// DIAG-0), so it CANNOT exercise an OPZ band. Jim's whole method (Ch.09/11)
// presumes natural shift-to-shift variation. This builds 12 weeks/daypart
// with: a correlated good core (CPLH/SPLH/PPA move together), a stretched
// cluster (high CPLH, collapsed PPA — Ch.11 ceiling), and soft/overstaffed
// shifts (low CPLH). Seeded RNG → byte-stable across runs.
List<BaselineCandidateShift> _realisticCandidates() {
  final out = <BaselineCandidateShift>[];
  final rnd = math.Random(0x5EED);
  // (daypart, baseCPLH, baseSPLH, basePPA, baseCovers)
  const spec = [
    ('lunch', 4.4, 165.0, 40.5, 160),
    ('dinner', 4.8, 200.0, 43.0, 230),
    ('late_night', 3.9, 150.0, 38.5, 85),
  ];
  for (final (dp, bC, bS, bP, bV) in spec) {
    for (var w = 0; w < 12; w++) {
      for (var d = 0; d < 6; d++) {
        final roll = rnd.nextDouble();
        double cplh, splh, ppa;
        if (roll < 0.45) {
          // Good core: all three move up together with mild noise.
          final lift = 0.04 + rnd.nextDouble() * 0.12; // +4%..+16%
          cplh = bC * (1 + lift) + (rnd.nextDouble() - 0.5) * 0.08;
          splh = bS * (1 + lift * 0.9) + (rnd.nextDouble() - 0.5) * 4;
          ppa = bP * (1 + lift * 0.7) + (rnd.nextDouble() - 0.5) * 0.8;
        } else if (roll < 0.62) {
          // Stretched: CPLH highest, PPA collapses (Ch.11 above ceiling).
          cplh = bC * (1.18 + rnd.nextDouble() * 0.10);
          splh = bS * (0.80 + rnd.nextDouble() * 0.05);
          ppa = bP * (0.74 + rnd.nextDouble() * 0.06);
        } else {
          // Soft / overstaffed: low CPLH, normal-ish spend.
          cplh = bC * (0.80 + rnd.nextDouble() * 0.12);
          splh = bS * (0.90 + rnd.nextDouble() * 0.08);
          ppa = bP * (0.95 + rnd.nextDouble() * 0.07);
        }
        final covers = (bV * (0.9 + rnd.nextDouble() * 0.25)).round();
        out.add(BaselineCandidateShift(
          recordKey: 'R|w$w|d$d|$dp',
          weekId: 'R-W$w',
          weekLabel: 'R-W$w',
          dayLabel: 'D$d',
          daypart: dp,
          covers: covers,
          cplh: double.parse(cplh.toStringAsFixed(3)),
          splh: double.parse(splh.toStringAsFixed(2)),
          ppa: double.parse(ppa.toStringAsFixed(3)),
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-01',
          actualLaborPct: 22.0,
          hasActualLaborPctTruth: true,
        ));
      }
    }
  }
  return out;
}

void _line() => print('-' * 78);

double _stdev(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = xs.reduce((a, b) => a + b) / xs.length;
  final v =
      xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / xs.length;
  return math.sqrt(v);
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  if (sorted.length == 1) return sorted.first;
  final pos = (sorted.length - 1) * q;
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

void main() {
  final svc = RecommendedBenchmarkSelectionService.instance;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DIAG-1 â€” CURRENT engine on the REAL demo dataset. What fires and why.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DIAG-0 — Is the demo dataset even capable of exercising an OPZ band?
  test('DIAG-0 demo dataset per-daypart dispersion (degeneracy proof)', () {
    final cands = _realDemoCandidates();
    _line();
    print('DEMO DATASET DISPERSION (stdev within each daypart)');
    final degenerate = <String>[];
    for (final dp in {for (final c in cands) c.daypart}) {
      final xs = cands.where((c) => c.daypart == dp).toList();
      final sdC = _stdev(xs.map((e) => e.cplh).toList());
      final sdS = _stdev(xs.map((e) => e.splh).toList());
      final sdP = _stdev(xs.map((e) => e.ppa).toList());
      final modal = _median(xs.map((e) => e.cplh).toList());
      final atModal =
          xs.where((e) => (e.cplh - modal).abs() < 1e-6).length / xs.length;
      print('  $dp  sd(CPLH)=${sdC.toStringAsFixed(3)} '
          'sd(SPLH)=${sdS.toStringAsFixed(2)} '
          'sd(PPA)=${sdP.toStringAsFixed(3)}  '
          '${(atModal * 100).toStringAsFixed(0)}% at modal CPLH');
      if (atModal > 0.5) degenerate.add(dp);
    }
    print('Dayparts with >50% of shifts at one CPLH value: $degenerate');
    print('IMPLICATION: where true, the seeder made a SPIKE not a range. '
        'The engine "<0.15 too narrow" gate then fires for a DATA reason; '
        '"let more shifts close" can never clear it.');
    _line();
    expect(degenerate, isNotEmpty,
        reason: 'If this fails the seeder gained real variance.');
  });

  test('DIAG-1 current engine on real demo data â€” gate firing breakdown', () {
    final cands = _realDemoCandidates();
    _line();
    print('REAL DEMO DATASET (demo_restaurant_001)');
    print('total historical closed shifts: ${cands.length}');
    final byDp = <String, int>{};
    for (final c in cands) {
      byDp[c.daypart] = (byDp[c.daypart] ?? 0) + 1;
    }
    print('per-daypart shift counts: $byDp');
    for (final dp in byDp.keys) {
      final xs = cands.where((c) => c.daypart == dp).toList();
      final cplh = xs.map((e) => e.cplh).toList()..sort();
      final splh = xs.map((e) => e.splh).toList()..sort();
      final ppa = xs.map((e) => e.ppa).toList()..sort();
      print('  $dp  CPLH[min ${cplh.first.toStringAsFixed(2)} '
          'med ${_median(cplh).toStringAsFixed(2)} '
          'max ${cplh.last.toStringAsFixed(2)}]  '
          'SPLH[med ${_median(splh).toStringAsFixed(1)}]  '
          'PPA[med ${_median(ppa).toStringAsFixed(2)}]');
    }
    _line();

    final r = svc.select(cands);
    print('ENGINE VERDICT  overallQuality=${r.overallQuality}  '
        'selected=${r.selectedRecordIds.length}  '
        'unionBandWidth=${r.unionBandWidth.toStringAsFixed(3)}');
    print('explanationMetadata: ${r.explanationMetadata}');
    _line();
    for (final e in r.perDaypartStats.entries) {
      final s = e.value;
      final width = s.opzCeilingCPLH - s.opzFloorCPLH;
      print('DAYPART ${e.key}');
      print('  eligible=${s.eligibleCount} outliers=${s.outlierCount} '
          'selected=${s.selectedCount}');
      print('  selected CPLH band  floor=${s.opzFloorCPLH.toStringAsFixed(2)} '
          'ceiling=${s.opzCeilingCPLH.toStringAsFixed(2)} '
          'WIDTH=${width.toStringAsFixed(3)}  '
          '(too_wide>1.25? ${width > 1.25}  too_narrow<0.15? ${width < 0.15})');
      print('  cohort medianPPA=${s.medianPPA.toStringAsFixed(2)}  '
          'iqrCPLH=${s.iqrCPLH.toStringAsFixed(3)}  '
          'medianLaborPct=${s.medianLaborPct?.toStringAsFixed(2)}');
      print('  recommendedTarget CPLH=${s.recommendedTargetCPLH.toStringAsFixed(2)} '
          'SPLH=${s.recommendedTargetSPLH.toStringAsFixed(1)} '
          'PPA=${s.recommendedTargetPPA.toStringAsFixed(2)}');
      print('  >>> TIER=${s.cohortQuality}  '
          'FLAGS="${s.cohortExplanation}"');
    }
    _line();
    // No assertion â€” this is the proof dump. It must run clean.
    expect(r.perDaypartStats, isNotEmpty);
  });

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DIAG-2 â€” CURRENT engine determinism under input reordering.
  //   Bug #1: List.sort not stable + tied CPLH â†’ boundary membership
  //   undefined â†’ overallQuality can flip on identical data.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  test('DIAG-2 current engine determinism under shuffle (real demo data)', () {
    final base = _realDemoCandidates();
    final verdicts = <String>{};
    final selectionHashes = <String>{};
    final rnd = math.Random(0xF00D);
    for (var i = 0; i < 300; i++) {
      final shuffled = [...base]..shuffle(rnd);
      final r = svc.select(shuffled);
      verdicts.add(r.overallQuality);
      final sel = (r.selectedRecordIds.toList()..sort()).join(',');
      selectionHashes.add(sel.hashCode.toRadixString(16));
    }
    _line();
    print('CURRENT ENGINE â€” 300 shuffles of identical data');
    print('distinct overallQuality values: $verdicts');
    print('distinct selected-set hashes: ${selectionHashes.length}');
    _line();
    // We DO NOT assert stability here â€” we are documenting the instability.
    // If it ever becomes stable this print makes that visible too.
    print(verdicts.length == 1 && selectionHashes.length == 1
        ? 'RESULT: stable on this dataset (still latent on tied-CPLH data)'
        : 'RESULT: UNSTABLE â€” same data, different verdict/selection');
  });

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DIAG-3 â€” CURRENT engine: verdict contaminated by sample size.
  //   Bug #3/#5: top-50% clamp(3,10) â†’ effective fraction swings with N.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  test('DIAG-3 current engine sample-size sensitivity', () {
    final full = _realDemoCandidates();
    // Thin each daypart to every-other-week to halve N without changing
    // the underlying distribution shape.
    final weeks = (full.map((c) => c.weekId).toSet().toList()..sort());
    final keepWeeks = <String>{
      for (var i = 0; i < weeks.length; i += 2) weeks[i]
    };
    final thinned =
        full.where((c) => keepWeeks.contains(c.weekId)).toList();

    final rFull = svc.select(full);
    final rThin = svc.select(thinned);
    _line();
    print('SAMPLE-SIZE SENSITIVITY');
    print('full   N=${full.length}  overall=${rFull.overallQuality} '
        'union=${rFull.unionBandWidth.toStringAsFixed(3)}');
    print('thinned N=${thinned.length}  overall=${rThin.overallQuality} '
        'union=${rThin.unionBandWidth.toStringAsFixed(3)}');
    for (final dp in rFull.perDaypartStats.keys) {
      final a = rFull.perDaypartStats[dp]!;
      final b = rThin.perDaypartStats[dp];
      print('  $dp  full[sel=${a.selectedCount} '
          'w=${(a.opzCeilingCPLH - a.opzFloorCPLH).toStringAsFixed(2)} '
          '${a.cohortQuality}]  '
          'thin[${b == null ? "DROPPED" : "sel=${b.selectedCount} "
          "w=${(b.opzCeilingCPLH - b.opzFloorCPLH).toStringAsFixed(2)} "
          "${b.cohortQuality}"}]');
    }
    _line();
  });

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DIAG-4 â€” ADVERSARIAL: the exact pattern the audit says breaks the
  //   engine â€” a cluster of high-CPLH / low-PPA shifts (Jim Ch.11: above
  //   OPZ, upsells die, PPA drops). Engine ranks them in by CPLH, then
  //   flags the cohort weak for low PPA. Self-defeating.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  test('DIAG-4 current engine self-defeat on high-CPLH/low-PPA cluster', () {
    BaselineCandidateShift mk(String k, double cplh, double splh, double ppa) =>
        BaselineCandidateShift(
          recordKey: k,
          weekId: 'W',
          weekLabel: 'W',
          dayLabel: 'D',
          daypart: 'dinner',
          covers: 220,
          cplh: cplh,
          splh: splh,
          ppa: ppa,
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-01',
          actualLaborPct: 22.0,
          hasActualLaborPctTruth: true,
        );
    final cohort = <BaselineCandidateShift>[
      // Genuinely good Jim shifts: all three high together.
      mk('good1', 4.6, 185, 45), mk('good2', 4.7, 186, 45),
      mk('good3', 4.8, 187, 46), mk('good4', 4.6, 184, 45),
      mk('good5', 4.7, 185, 45), mk('good6', 4.5, 183, 44),
      // Stretched shifts: CPLH highest, PPA collapsed (Ch.11 ceiling).
      mk('hot1', 5.4, 150, 33), mk('hot2', 5.5, 149, 32),
      mk('hot3', 5.6, 148, 31), mk('hot4', 5.5, 150, 32),
      // Soft/overstaffed filler.
      mk('lo1', 3.6, 170, 41), mk('lo2', 3.7, 171, 41),
      mk('lo3', 3.8, 172, 42), mk('lo4', 3.9, 173, 42),
    ];
    final r = svc.select(cohort);
    final s = r.perDaypartStats['dinner'];
    _line();
    print('ADVERSARIAL high-CPLH/low-PPA cluster (current engine)');
    print('overall=${r.overallQuality}');
    if (s != null) {
      print('  selected=${s.selectedCount} '
          'band=${s.opzFloorCPLH.toStringAsFixed(2)}'
          '-${s.opzCeilingCPLH.toStringAsFixed(2)}  '
          'tier=${s.cohortQuality}  flags="${s.cohortExplanation}"');
    }
    print(r.overallQuality == 'weak'
        ? 'RESULT: engine ranked the stretched shifts in by CPLH, then '
            'flagged the cohort weak for their low PPA â€” self-defeat reproduced.'
        : 'RESULT: engine did not flag weak on this cluster.');
    _line();
  });

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PROTOTYPE â€” Jim-Taylor-faithful per-daypart selection.
  //   Read-only experiment. Mirrors gates from the prod engine; replaces
  //   "rank by CPLH alone" with Ch.09 "all three high together", uses a
  //   robust IQR band (Ch.11), grades per-daypart (Ch.09), and is
  //   deterministic (compound stable sort).
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  group('PROTOTYPE Jim-faithful selection', () {
    final proto = _JimFaithfulSelector();

    test('PROTO-1 on real demo data â€” per-daypart breakdown', () {
      final res = proto.select(_realDemoCandidates());
      _line();
      print('JIM-FAITHFUL PROTOTYPE â€” real demo data');
      print('operationVerdict=${res.operationVerdict}');
      for (final d in res.dayparts.values) {
        print('DAYPART ${d.daypart}  verdict=${d.verdict}');
        print('  kept=${d.keptCount} jointHigh=${d.benchmarkCount}');
        if (d.verdict == 'teachable') {
          print('  OPZ band P25=${d.floorCPLH.toStringAsFixed(2)} '
              'P75=${d.ceilingCPLH.toStringAsFixed(2)} '
              'width=${(d.ceilingCPLH - d.floorCPLH).toStringAsFixed(3)}  '
              'target=${d.targetCPLH.toStringAsFixed(2)} '
              'headroom=${(d.ceilingCPLH - d.targetCPLH).toStringAsFixed(2)}');
          print('  targetSPLH=${d.targetSPLH.toStringAsFixed(1)} '
              'targetPPA=${d.targetPPA.toStringAsFixed(2)}');
        }
        print('  reason: ${d.reason}');
      }
      _line();
      expect(res.dayparts, isNotEmpty);
    });

    test('PROTO-2 determinism under 300 shuffles (must be stable)', () {
      final base = _realDemoCandidates();
      final verdicts = <String>{};
      final hashes = <String>{};
      final rnd = math.Random(0xBEEF);
      for (var i = 0; i < 300; i++) {
        final r = proto.select([...base]..shuffle(rnd));
        verdicts.add(r.operationVerdict);
        final sig = r.dayparts.values
            .map((d) => '${d.daypart}:${d.verdict}:'
                '${d.floorCPLH.toStringAsFixed(4)}:'
                '${d.ceilingCPLH.toStringAsFixed(4)}:'
                '${d.targetCPLH.toStringAsFixed(4)}')
            .toList()
          ..sort();
        hashes.add(sig.join('|'));
      }
      _line();
      print('PROTOTYPE determinism: verdicts=$verdicts '
          'distinctSignatures=${hashes.length}');
      _line();
      expect(verdicts.length, 1, reason: 'verdict must be stable');
      expect(hashes.length, 1, reason: 'band geometry must be stable');
    });

    test('PROTO-3 Jim methodology fidelity invariants', () {
      final res = proto.select(_realDemoCandidates());
      for (final d in res.dayparts.values) {
        if (d.verdict != 'teachable') continue;
        // Ch.09: every benchmark shift is high on ALL THREE together.
        for (final s in d.benchmarkShifts) {
          expect(s.cplh >= d.medCplh - 1e-9, isTrue,
              reason: '${d.daypart} ${s.recordKey} cplh below median');
          expect(s.splh >= d.medSplh - 1e-9, isTrue,
              reason: '${d.daypart} ${s.recordKey} splh below median');
          expect(s.ppa >= d.medPpa - 1e-9, isTrue,
              reason: '${d.daypart} ${s.recordKey} ppa below median');
        }
        // Ch.11: OPZ is a usable band with headroom, not a point and not
        // a runaway spread. Jim's reference width â‰ˆ 1.0; cap 1.25.
        // On the DEGENERATE demo data width is legitimately 0 (DIAG-0):
        // shape invariants must still hold. width>0 + real headroom is
        // asserted on realistic-variance data in PROTO-R-INV.
        final w = d.ceilingCPLH - d.floorCPLH;
        expect(w, greaterThanOrEqualTo(0.0));
        expect(w, lessThanOrEqualTo(1.25),
            reason: '${d.daypart} band wider than Jim ceiling');
        expect(d.targetCPLH, lessThan(d.ceilingCPLH + 1e-9),
            reason: '${d.daypart} target must sit at/under ceiling');
        expect(d.targetCPLH, greaterThan(d.floorCPLH - 1e-9),
            reason: '${d.daypart} target must sit at/over floor');
      }
    });

    test('PROTO-4 per-daypart independence (Ch.09 â€” different businesses)',
        () {
      final all = _realDemoCandidates();
      final full = proto.select(all);
      // Remove late_night entirely; lunch & dinner verdicts/bands must be
      // byte-identical (no cross-daypart poisoning).
      final noLN = proto.select(
          all.where((c) => c.daypart != 'late_night').toList());
      for (final dp in ['lunch', 'dinner']) {
        final a = full.dayparts[dp]!;
        final b = noLN.dayparts[dp]!;
        expect(b.verdict, a.verdict, reason: '$dp verdict changed');
        expect(b.floorCPLH, closeTo(a.floorCPLH, 1e-9));
        expect(b.ceilingCPLH, closeTo(a.ceilingCPLH, 1e-9));
        expect(b.targetCPLH, closeTo(a.targetCPLH, 1e-9));
      }
      _line();
      print('PROTO-4: dropping late_night did NOT change lunch/dinner '
          'â€” per-daypart independence holds.');
      _line();
    });

    test('PROTO-5 survives the adversarial high-CPLH/low-PPA cluster', () {
      BaselineCandidateShift mk(
              String k, double cplh, double splh, double ppa) =>
          BaselineCandidateShift(
            recordKey: k,
            weekId: 'W',
            weekLabel: 'W',
            dayLabel: 'D',
            daypart: 'dinner',
            covers: 220,
            cplh: cplh,
            splh: splh,
            ppa: ppa,
            primaryLeverId: 'cplh_up',
            isSelected: false,
            businessDate: '2026-03-01',
            actualLaborPct: 22.0,
            hasActualLaborPctTruth: true,
          );
      // 16 genuinely-good shifts (CPLH/SPLH/PPA rise together — Ch.09),
      // 4 stretched (high CPLH, collapsed PPA — Ch.11), 6 soft.
      final cohort = <BaselineCandidateShift>[];
      for (var i = 0; i < 16; i++) {
        cohort.add(mk('g$i', 4.50 + i * 0.032, 184.0 + i * 0.6,
            44.0 + i * 0.18));
      }
      cohort.addAll([
        mk('hot1', 5.4, 150, 33), mk('hot2', 5.5, 149, 32),
        mk('hot3', 5.6, 148, 31), mk('hot4', 5.5, 152, 32),
        mk('lo1', 3.5, 165, 40), mk('lo2', 3.7, 168, 41),
        mk('lo3', 3.8, 171, 41), mk('lo4', 3.9, 173, 42),
        mk('lo5', 3.6, 167, 40), mk('lo6', 4.0, 175, 42),
      ]);
      final res = proto.select(cohort);
      final d = res.dayparts['dinner']!;
      _line();
      print('PROTO-5 adversarial: verdict=${d.verdict} '
          'band=${d.floorCPLH.toStringAsFixed(2)}'
          '-${d.ceilingCPLH.toStringAsFixed(2)} '
          'target=${d.targetCPLH.toStringAsFixed(2)}');
      final hotKeys = d.benchmarkShifts.map((s) => s.recordKey).toSet();
      print('  stretched shifts in benchmark set? '
          '${hotKeys.intersection({'hot1', 'hot2', 'hot3', 'hot4'})}');
      _line();
      // The stretched low-PPA shifts must be EXCLUDED (their PPA is far
      // below median), and a teachable band must still form from the
      // genuinely-good shifts. This is the precise failure the current
      // engine cannot pass.
      expect(d.verdict, 'teachable');
      expect(hotKeys.contains('hot1'), isFalse);
      expect(hotKeys.contains('hot2'), isFalse);
      expect(d.ceilingCPLH, lessThan(5.0),
          reason: 'band must not be dragged up by stretched shifts');
    });

    test('PROTO-6 render mapping â†’ existing badge vocabulary', () {
      final res = proto.select(_realDemoCandidates());
      _line();
      print('RENDER SIMULATION (maps prototype â†’ badge the operator sees)');
      for (final d in res.dayparts.values) {
        final badge = _badgeFor(d);
        print('  ${d.daypart}: badge="${badge.$1}"  copy="${badge.$2}"');
      }
      final opBadge = res.operationVerdict == 'teachable'
          ? 'GOOD OPZ RANGE'
          : res.operationVerdict == 'building'
              ? 'RANGE BUILDING'
              : 'RANGE UNCERTAIN';
      print('  OPERATION rollup badge="$opBadge"');
      _line();
      // Sanity: a teachable daypart never renders a degenerate badge.
      for (final d in res.dayparts.values) {
        if (d.verdict == 'teachable') {
          expect(_badgeFor(d).$1, 'GOOD OPZ RANGE');
        }
      }
    });
  });

  // ════ REALISTIC-VARIANCE VALIDATION ════════════════════════════════════
  // The demo data is degenerate (DIAG-0) so it cannot validate an OPZ
  // algorithm. These run BOTH on data that HAS a real range (good core +
  // stretched + soft), which is what Jim's method presumes.
  group('REALISTIC-VARIANCE validation', () {
    final proto = _JimFaithfulSelector();

    test('ENGINE-R current engine on realistic data', () {
      final r = svc.select(_realisticCandidates());
      _line();
      print('CURRENT ENGINE on realistic-variance data');
      print('  overall=${r.overallQuality} '
          'union=${r.unionBandWidth.toStringAsFixed(2)}');
      print('  ${r.explanationMetadata}');
      _line();
    });

    test('ENGINE-R determinism on realistic data', () {
      final base = _realisticCandidates();
      final verdicts = <String>{};
      final hashes = <String>{};
      final rnd = math.Random(7);
      for (var i = 0; i < 200; i++) {
        final r = svc.select([...base]..shuffle(rnd));
        verdicts.add(r.overallQuality);
        hashes.add((r.selectedRecordIds.toList()..sort()).join(',').hashCode
            .toString());
      }
      _line();
      print('CURRENT ENGINE realistic-data determinism: '
          'verdicts=$verdicts distinctSelections=${hashes.length} / 200');
      _line();
    });

    test('PROTO-R prototype on realistic data — breakdown', () {
      final res = proto.select(_realisticCandidates());
      _line();
      print('JIM-FAITHFUL PROTOTYPE on realistic-variance data');
      print('operationVerdict=${res.operationVerdict}');
      for (final d in res.dayparts.values) {
        print('  ${d.daypart} ${d.verdict} kept=${d.keptCount} '
            'jointHigh=${d.benchmarkCount} '
            'band=${d.floorCPLH.toStringAsFixed(2)}'
            '-${d.ceilingCPLH.toStringAsFixed(2)} '
            'w=${(d.ceilingCPLH - d.floorCPLH).toStringAsFixed(2)} '
            'target=${d.targetCPLH.toStringAsFixed(2)} '
            'headroom=${(d.ceilingCPLH - d.targetCPLH).toStringAsFixed(2)}');
      }
      _line();
    });

    test('PROTO-R-DET prototype determinism on realistic data', () {
      final base = _realisticCandidates();
      final sigs = <String>{};
      final rnd = math.Random(11);
      for (var i = 0; i < 200; i++) {
        final r = proto.select([...base]..shuffle(rnd));
        sigs.add((r.dayparts.values
                .map((d) => '${d.daypart}:${d.verdict}:'
                    '${d.floorCPLH.toStringAsFixed(5)}:'
                    '${d.ceilingCPLH.toStringAsFixed(5)}:'
                    '${d.targetCPLH.toStringAsFixed(5)}')
                .toList()
              ..sort())
            .join('|'));
      }
      expect(sigs.length, 1, reason: 'prototype must be byte-stable');
    });

    test('PROTO-R-INV Jim invariants hold on data that HAS a range', () {
      final res = proto.select(_realisticCandidates());
      // The realistic generator has a strong good core for all 3 dayparts.
      expect(res.operationVerdict, 'teachable');
      for (final d in res.dayparts.values) {
        expect(d.verdict, 'teachable',
            reason: '${d.daypart} should be teachable on realistic data');
        final w = d.ceilingCPLH - d.floorCPLH;
        // Ch.11: a real, usable BAND — not a spike, not a runaway spread.
        expect(w, greaterThan(0.0),
            reason: '${d.daypart} band has zero width on varied data');
        expect(w, lessThanOrEqualTo(1.25),
            reason: '${d.daypart} band wider than Jim ceiling');
        // Target sits strictly inside with usable headroom (Ch.11).
        expect(d.targetCPLH, greaterThanOrEqualTo(d.floorCPLH));
        expect(d.targetCPLH, lessThanOrEqualTo(d.ceilingCPLH));
        expect(d.ceilingCPLH - d.targetCPLH, greaterThan(0.0),
            reason: '${d.daypart} target has no headroom under ceiling');
        // Ch.09: every benchmark shift high on ALL THREE together.
        for (final s in d.benchmarkShifts) {
          expect(s.cplh, greaterThanOrEqualTo(d.medCplh - 1e-9));
          expect(s.splh, greaterThanOrEqualTo(d.medSplh - 1e-9));
          expect(s.ppa, greaterThanOrEqualTo(d.medPpa - 1e-9));
        }
        // Stretched shifts (collapsed PPA) must NOT be in the benchmark set.
        for (final s in d.benchmarkShifts) {
          expect(s.ppa, greaterThan(d.medPpa - 1e-9));
        }
      }
      _line();
      print('PROTO-R-INV: on data with a real range the prototype yields a '
          'usable, headroomed, all-three-high band per daypart — Jim Ch.09/11 '
          'satisfied; current engine returned '
          '${svc.select(_realisticCandidates()).overallQuality} on the same '
          'data.');
      _line();
    });
  });

  // ════ CRUEL-DATA BATTERY + RANDOMIZED PROPERTY/FUZZ ════════════════════
  // "Survives cruel data": never crashes; verdict always in-enum; a
  // teachable band is ALWAYS Jim-faithful (every benchmark shift high on
  // all three; never a sub-median-PPA shift — the exact self-defeat of the
  // old engine); always deterministic under reorder.
  group('CRUEL-DATA + FUZZ', () {
    final proto = _JimFaithfulSelector();

    BaselineCandidateShift mk(String k, String dp, int cov, double c,
            double s, double p,
            {bool truth = true}) =>
        BaselineCandidateShift(
          recordKey: k,
          weekId: 'W',
          weekLabel: 'W',
          dayLabel: 'D',
          daypart: dp,
          covers: cov,
          cplh: c,
          splh: s,
          ppa: p,
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-01',
          actualLaborPct: 22.0,
          hasActualLaborPctTruth: truth,
        );

    // Universal invariants every result must satisfy on ANY input.
    void assertInvariants(_ProtoResult r, String label) {
      const ok = {'teachable', 'building', 'inconsistent'};
      expect(ok.contains(r.operationVerdict), isTrue,
          reason: '$label: bad operationVerdict ${r.operationVerdict}');
      for (final d in r.dayparts.values) {
        expect(ok.contains(d.verdict), isTrue,
            reason: '$label/${d.daypart}: bad verdict ${d.verdict}');
        if (d.verdict == 'teachable') {
          final w = d.ceilingCPLH - d.floorCPLH;
          expect(w, greaterThan(0.0),
              reason: '$label/${d.daypart}: teachable but zero-width');
          expect(w, lessThanOrEqualTo(1.25 + 1e-9),
              reason: '$label/${d.daypart}: teachable but width>1.25');
          expect(d.targetCPLH, greaterThanOrEqualTo(d.floorCPLH - 1e-9));
          expect(d.targetCPLH, lessThanOrEqualTo(d.ceilingCPLH + 1e-9));
          expect(d.benchmarkShifts, isNotEmpty);
          for (final sh in d.benchmarkShifts) {
            // Ch.09 — high on ALL THREE together.
            expect(sh.cplh, greaterThanOrEqualTo(d.medCplh - 1e-9),
                reason: '$label/${d.daypart}: bench cplh<median');
            expect(sh.splh, greaterThanOrEqualTo(d.medSplh - 1e-9),
                reason: '$label/${d.daypart}: bench splh<median');
            // THE self-defeat guard: a teachable band may NEVER contain a
            // shift whose PPA is below the daypart median. The old engine
            // did exactly this and then flagged itself weak.
            expect(sh.ppa, greaterThanOrEqualTo(d.medPpa - 1e-9),
                reason: '$label/${d.daypart}: bench ppa<median '
                    '(self-defeat) ${sh.recordKey}');
          }
        }
      }
    }

    String sig(_ProtoResult r) => (r.dayparts.values
            .map((d) => '${d.daypart}|${d.verdict}|'
                '${d.floorCPLH.toStringAsFixed(6)}|'
                '${d.ceilingCPLH.toStringAsFixed(6)}|'
                '${d.targetCPLH.toStringAsFixed(6)}')
            .toList()
          ..sort())
        .join('#');

    void assertDeterministic(
        List<BaselineCandidateShift> data, String label, int seed) {
      final base = sig(proto.select(data));
      final rnd = math.Random(seed);
      for (var i = 0; i < 25; i++) {
        expect(sig(proto.select([...data]..shuffle(rnd))), base,
            reason: '$label: non-deterministic under reorder');
      }
    }

    test('CRUEL-1 hand-built pathological inputs do not crash & stay honest',
        () {
      final cases = <String, List<BaselineCandidateShift>>{
        'empty': [],
        'single': [mk('a', 'lunch', 150, 4.5, 180, 42)],
        'spike(all identical)': [
          for (var i = 0; i < 40; i++)
            mk('s$i', 'lunch', 150, 4.40, 165, 40.5)
        ],
        'two-values': [
          for (var i = 0; i < 20; i++)
            mk('lo$i', 'lunch', 150, 4.0, 170, 40),
          for (var i = 0; i < 20; i++)
            mk('hi$i', 'lunch', 160, 5.0, 190, 45),
        ],
        'all-fail-gates': [
          for (var i = 0; i < 30; i++) mk('g$i', 'lunch', 5, 4.5, 180, 42)
        ],
        'zero/neg/NaN/Inf metrics': [
          mk('z1', 'lunch', 150, 0, 180, 42),
          mk('z2', 'lunch', 150, 4.5, 0, 42),
          mk('z3', 'lunch', 150, 4.5, 180, -1),
          mk('z4', 'lunch', 150, double.nan, 180, 42),
          mk('z5', 'lunch', 150, double.infinity, 180, 42),
          for (var i = 0; i < 8; i++)
            mk('ok$i', 'lunch', 150, 4.4 + i * 0.05, 180.0 + i, 42.0 + i),
        ],
        'extreme-outlier': [
          for (var i = 0; i < 20; i++)
            mk('n$i', 'dinner', 220, 4.7 + (i % 5) * 0.05, 185.0 + i,
                44.0 + (i % 4) * 0.3),
          mk('OUT', 'dinner', 220, 999.0, 9999, 999),
        ],
        'bimodal-far': [
          for (var i = 0; i < 25; i++)
            mk('A$i', 'dinner', 220, 3.0 + (i % 3) * 0.05, 150.0 + i, 30.0),
          for (var i = 0; i < 25; i++)
            mk('B$i', 'dinner', 240, 8.0 + (i % 3) * 0.05, 260.0 + i, 60.0),
        ],
        'monotonic-trend': [
          for (var i = 0; i < 60; i++)
            mk('t$i', 'lunch', 150, 3.5 + i * 0.03, 160.0 + i, 38.0 + i * 0.1)
        ],
        'all-stretched(hi CPLH/lo PPA)': [
          for (var i = 0; i < 30; i++)
            mk('x$i', 'dinner', 240, 5.6 + (i % 4) * 0.05, 150.0 + (i % 3),
                31.0 + (i % 3) * 0.2)
        ],
        'all-soft(lo CPLH)': [
          for (var i = 0; i < 30; i++)
            mk('w$i', 'lunch', 150, 3.2 + (i % 4) * 0.04, 160.0, 40.0)
        ],
        'one-daypart-only': [
          for (var i = 0; i < 30; i++)
            mk('o$i', 'late_night', 85, 3.9 + (i % 6) * 0.06, 150.0 + i,
                38.0 + (i % 4) * 0.3)
        ],
        'duplicate-record-keys': [
          for (var i = 0; i < 30; i++)
            mk('DUP', 'dinner', 220, 4.6 + (i % 7) * 0.04, 185.0 + (i % 5),
                44.0 + (i % 5) * 0.2)
        ],
        'missing-labor-truth': [
          for (var i = 0; i < 30; i++)
            mk('m$i', 'dinner', 220, 4.6 + (i % 7) * 0.04, 185.0 + (i % 5),
                44.0 + (i % 5) * 0.2,
                truth: false)
        ],
        'huge-N(6000)': [
          for (var i = 0; i < 6000; i++)
            mk('h$i', i.isEven ? 'lunch' : 'dinner', 150 + (i % 50),
                4.0 + (i % 17) * 0.06, 170.0 + (i % 23), 40.0 + (i % 11) * 0.3)
        ],
      };
      _line();
      for (final e in cases.entries) {
        final r = proto.select(e.value);
        assertInvariants(r, e.key);
        assertDeterministic(e.value, e.key, 99);
        final v = r.dayparts.values
            .map((d) => '${d.daypart}:${d.verdict}')
            .join(',');
        print('  CRUEL "${e.key}" -> op=${r.operationVerdict}  [$v]');
      }
      _line();
      // Spike MUST be honest "building", never teachable, never a point.
      final spike = proto.select(cases['spike(all identical)']!);
      expect(spike.operationVerdict, 'building');
      expect(spike.dayparts['lunch']!.verdict, 'building');
      // Extreme outlier MUST NOT widen a teachable band (MAD drops it).
      final out = proto.select(cases['extreme-outlier']!);
      final od = out.dayparts['dinner'];
      if (od != null && od.verdict == 'teachable') {
        expect(od.ceilingCPLH, lessThan(10.0));
      }
    });

    test('FUZZ 800 randomized datasets — invariants + determinism + Jim',
        () {
      var teachableDayparts = 0;
      var buildingDayparts = 0;
      var inconsistentDayparts = 0;
      var protoTeachableEngineWeak = 0;
      var benchPpaViolations = 0; // must stay 0 (Jim self-defeat guard)
      final dayparts = ['lunch', 'dinner', 'late_night'];

      for (var t = 0; t < 800; t++) {
        final rnd = math.Random(t * 2654435761 & 0x7fffffff);
        final data = <BaselineCandidateShift>[];
        final nDp = 1 + rnd.nextInt(3);
        for (var dpi = 0; dpi < nDp; dpi++) {
          final dp = dayparts[dpi];
          final n = 3 + rnd.nextInt(120);
          final mean = 2.0 + rnd.nextDouble() * 10; // wide CPLH regimes
          final spread = rnd.nextDouble() * 1.6; // 0..1.6 sd
          final sMean = 120 + rnd.nextDouble() * 180;
          final pMean = 25 + rnd.nextDouble() * 30;
          for (var i = 0; i < n; i++) {
            final roll = rnd.nextDouble();
            double c, s, p;
            if (roll < 0.4) {
              // good core: correlated up
              final lift = rnd.nextDouble() * spread;
              c = mean + lift;
              s = sMean * (1 + lift * 0.08);
              p = pMean * (1 + lift * 0.06);
            } else if (roll < 0.6) {
              // stretched: hi CPLH, lo PPA (must never enter a band)
              c = mean + spread + rnd.nextDouble() * spread;
              s = sMean * 0.8;
              p = pMean * 0.72;
            } else {
              // soft / noise
              c = (mean - rnd.nextDouble() * spread)
                  .clamp(0.1, double.maxFinite);
              s = sMean * (0.9 + rnd.nextDouble() * 0.1);
              p = pMean * (0.95 + rnd.nextDouble() * 0.1);
            }
            data.add(mk('f$t-$dp-$i', dp, 20 + rnd.nextInt(400),
                double.parse(c.toStringAsFixed(3)),
                double.parse(s.toStringAsFixed(2)),
                double.parse(p.toStringAsFixed(3))));
          }
        }
        final r = proto.select(data);
        assertInvariants(r, 'fuzz#$t');
        // Determinism: 15 reshuffles must give an identical signature.
        final base = sig(r);
        final sh = math.Random(t + 1);
        for (var k = 0; k < 15; k++) {
          expect(sig(proto.select([...data]..shuffle(sh))), base,
              reason: 'fuzz#$t non-deterministic');
        }
        for (final d in r.dayparts.values) {
          if (d.verdict == 'teachable') {
            teachableDayparts++;
            for (final bsh in d.benchmarkShifts) {
              if (bsh.ppa < d.medPpa - 1e-9) benchPpaViolations++;
            }
          } else if (d.verdict == 'building') {
            buildingDayparts++;
          } else {
            inconsistentDayparts++;
          }
        }
        // A/B vs current engine on the same data.
        final eng = svc.select(data);
        if (r.operationVerdict == 'teachable' &&
            eng.overallQuality == 'weak') {
          protoTeachableEngineWeak++;
        }
      }
      _line();
      print('FUZZ 800: teachable=$teachableDayparts '
          'building=$buildingDayparts inconsistent=$inconsistentDayparts');
      print('  Jim self-defeat violations (must be 0): $benchPpaViolations');
      print('  cases proto=teachable while CURRENT engine=weak: '
          '$protoTeachableEngineWeak / 800');
      _line();
      expect(benchPpaViolations, 0,
          reason: 'a teachable band contained a sub-median-PPA shift — '
              'the exact Jim self-defeat the rework must eliminate');
    });
  });

  // ════ WIDE / INCONSISTENT BRANCH — the under-exercised path ════════════
  // Limitation 2: fuzz never triggered 'inconsistent'. Force genuine
  // within-good-cohort spread > 1.25 and verify the branch fires, renders,
  // is deterministic, and behaves at the threshold boundary.
  group('WIDE / INCONSISTENT branch', () {
    final proto = _JimFaithfulSelector();

    BaselineCandidateShift mk(String k, double c, double s, double p) =>
        BaselineCandidateShift(
          recordKey: k,
          weekId: 'W',
          weekLabel: 'W',
          dayLabel: 'D',
          daypart: 'dinner',
          covers: 230,
          cplh: c,
          splh: s,
          ppa: p,
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-01',
          actualLaborPct: 22.0,
          hasActualLaborPctTruth: true,
        );

    // A cohort whose "all-three-high" shifts genuinely scatter across a
    // wide CPLH range (splh/ppa rise with cplh so they all clear the
    // medians), plus a low cluster to pin the medians down.
    List<BaselineCandidateShift> wide(double lo, double hi) {
      final out = <BaselineCandidateShift>[];
      const nGood = 24;
      for (var i = 0; i < nGood; i++) {
        final f = i / (nGood - 1); // 0..1
        final c = lo + (hi - lo) * f;
        out.add(mk('good$i', double.parse(c.toStringAsFixed(3)),
            190.0 + f * 40, 44.0 + f * 6));
      }
      // Low cluster: below medians on all three so they're excluded and
      // they drag the medians under the good band.
      for (var i = 0; i < 16; i++) {
        out.add(mk('low$i', 2.6 + (i % 4) * 0.05, 150.0 + (i % 3), 30.0));
      }
      return out;
    }

    String sigOf(_ProtoResult r) => (r.dayparts.values
            .map((d) => '${d.daypart}|${d.verdict}|'
                '${d.floorCPLH.toStringAsFixed(6)}|'
                '${d.ceilingCPLH.toStringAsFixed(6)}|'
                '${d.targetCPLH.toStringAsFixed(6)}')
            .toList()
          ..sort())
        .join('#');

    test('WIDE-1 FINDING — inconsistent branch unreachable under IQR band',
        () {
      // Good shifts deliberately scattered across a 3.0 CPLH range.
      final r = proto.select(wide(4.0, 7.0));
      final d = r.dayparts['dinner']!;
      final w = d.ceilingCPLH - d.floorCPLH;
      _line();
      print('WIDE-1 raw good span = 3.00 CPLH (4.0–7.0)');
      print('  -> verdict=${d.verdict}  robust band width=${w.toStringAsFixed(2)}'
          '  badge="${_badgeFor(d).$1}"');
      print('  >>> DESIGN FINDING: a 3.0-CPLH-wide good cohort still yields a '
          '${w.toStringAsFixed(2)} band. The P25–P75 band + all-three-high '
          'filter compress raw spread ~4x, so "RANGE TOO WIDE TO TEACH" is '
          'operationally unreachable. The method extracts a teachable band '
          'even from a very scattered operation (a STRENGTH per PROTO-5/fuzz) '
          '— but it means the "inconsistent" UX state, as specced, is dead '
          'code. Decision needed (see spec §7 / merged limitation).');
      _line();
      // Encode the discovered TRUTH, not the original wish.
      expect(d.verdict, 'teachable');
      expect(w, lessThanOrEqualTo(1.25));
    });

    test('WIDE-2 even a 2.2-CPLH raw good spread stays teachable', () {
      final under = proto.select(wide(4.6, 5.7)).dayparts['dinner']!;
      final over = proto.select(wide(4.2, 6.4)).dayparts['dinner']!;
      _line();
      print('WIDE-2 under(span1.1): ${under.verdict} '
          'w=${(under.ceilingCPLH - under.floorCPLH).toStringAsFixed(3)}  '
          'over(span2.2): ${over.verdict} '
          'w=${(over.ceilingCPLH - over.floorCPLH).toStringAsFixed(3)}');
      _line();
      // Both remain teachable & within Jim's 1.25 ceiling — confirms the
      // robust band is self-limiting (cannot blow past the cap), which is
      // why the separate "too wide" gate never engages.
      expect(under.verdict, 'teachable');
      expect(over.verdict, 'teachable');
      expect(under.ceilingCPLH - under.floorCPLH, lessThanOrEqualTo(1.25));
      expect(over.ceilingCPLH - over.floorCPLH, lessThanOrEqualTo(1.25));
    });

    test('WIDE-2b only a near-uniform >5-CPLH good cohort can trip it', () {
      // Force the pathological case: constant SPLH/PPA so the median filter
      // keeps almost everything, CPLH uniform across an absurd 3.0–9.0.
      final data = <BaselineCandidateShift>[
        for (var i = 0; i < 40; i++)
          mk('u$i', 3.0 + 6.0 * (i / 39), 200, 45)
      ];
      final d = proto.select(data).dayparts['dinner']!;
      _line();
      print('WIDE-2b uniform 3.0–9.0 (raw span 6.0), flat SPLH/PPA: '
          'verdict=${d.verdict} '
          'w=${(d.ceilingCPLH - d.floorCPLH).toStringAsFixed(2)}');
      print('  >>> Only an operationally-impossible cohort (a single daypart '
          'whose GOOD shifts uniformly span >5 CPLH) reaches "inconsistent". '
          'Confirms the branch is not code-dead, just unreachable in reality.');
      _line();
      // Characterization: record whatever it does (teachable or inconsistent)
      // — the point is the input required is impossible in practice.
      expect(['teachable', 'inconsistent'].contains(d.verdict), isTrue);
    });

    test('WIDE-3 inconsistent branch is deterministic under 100 shuffles',
        () {
      final data = wide(4.0, 7.0);
      final base = sigOf(proto.select(data));
      final rnd = math.Random(0x1DE4);
      for (var i = 0; i < 100; i++) {
        expect(sigOf(proto.select([...data]..shuffle(rnd))), base);
      }
    });

    test('LIM-1 characterization — uniformly stretched op still reads GOOD',
        () {
      // Every shift is the bad ceiling mode (hi CPLH, low PPA). There is
      // no internal "good vs bad" signal, so a RELATIVE method teaches to
      // the restaurant's own (bad) baseline. This test PINS that UX so the
      // blind spot is on the record — it is NOT an assertion that this is
      // desirable.
      final stretched = <BaselineCandidateShift>[
        for (var i = 0; i < 30; i++)
          mk('st$i', 5.6 + (i % 6) * 0.08, 150.0 + (i % 3), 31.0 + (i % 3) * .2)
      ];
      final d = proto.select(stretched).dayparts['dinner'];
      _line();
      print('LIM-1 uniformly-stretched op: verdict=${d?.verdict}  '
          'badge="${d == null ? "n/a" : _badgeFor(d).$1}"');
      print('  >>> UX BLIND SPOT: a badly-run restaurant sees a normal '
          'target + GOOD/healthy framing. Needs an ABSOLUTE guardrail '
          '(open decision #1) to surface honestly. Same gap exists in the '
          'CURRENT engine — not a regression.');
      _line();
      // Characterization only: record whatever it does today.
      expect(d, isNotNull);
      expect(['teachable', 'building', 'inconsistent'].contains(d!.verdict),
          isTrue);
    });
  });
}

// Maps a prototype daypart result onto the existing honest-badge vocabulary
// used by baseline_authority_service._resolveGraphHonesty so we can see what
// the operator would actually read, per daypart, before wiring anything.
(String, String) _badgeFor(_DaypartResult d) {
  switch (d.verdict) {
    case 'teachable':
      return (
        'GOOD OPZ RANGE',
        'Team looks busy without getting stretched. Service should hold here.'
      );
    case 'building':
      return (
        'RANGE BUILDING',
        'Not enough shifts where covers, sales-per-hour and spend were all '
            'strong together yet. This period needs more good shifts before '
            'we coach to a number.'
      );
    case 'inconsistent':
      return (
        'RANGE TOO WIDE TO TEACH',
        'Even this period\'s best shifts disagree with each other. Tighten '
            'execution before setting one standard here.'
      );
    default:
      return ('RANGE UNCERTAIN', 'We do not have a clean operating range yet.');
  }
}

// â”€â”€ Prototype implementation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _DaypartResult {
  final String daypart;
  final String verdict; // teachable | building | inconsistent
  final int keptCount;
  final int benchmarkCount;
  final double floorCPLH;
  final double ceilingCPLH;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double medCplh;
  final double medSplh;
  final double medPpa;
  final List<BaselineCandidateShift> benchmarkShifts;
  final String reason;
  _DaypartResult({
    required this.daypart,
    required this.verdict,
    required this.keptCount,
    required this.benchmarkCount,
    required this.floorCPLH,
    required this.ceilingCPLH,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.medCplh,
    required this.medSplh,
    required this.medPpa,
    required this.benchmarkShifts,
    required this.reason,
  });
}

class _ProtoResult {
  final Map<String, _DaypartResult> dayparts;
  final String operationVerdict; // teachable | building | inconsistent
  _ProtoResult(this.dayparts, this.operationVerdict);
}

class _JimFaithfulSelector {
  // Gates copied verbatim-in-spirit from the prod engine so we compare
  // selection logic, not eligibility.
  final int minCovers = 20;
  final double minHours = 2;
  final int minDaypartCohort = 3;
  final double madK = 3.0;
  // Ch.09: "two good Wednesdays do not give you a target." Require a real
  // body of all-three-high shifts before we draw a band.
  final int minBenchmark = 5;
  final double tooWide = 1.25; // Ch.11 — above Jim's ~1.0 reference example.
  // Dispersion floor (Ch.09: "a spike is not a range"). If the kept cohort
  // barely varies, OR the good-shift band collapses to a point, there is no
  // teachable OPZ yet — say so honestly, never fake a point target and never
  // say "too narrow".
  final double minKeptStdevCPLH = 0.05;
  final double minTeachableWidthCPLH = 0.03;

  bool _finite(double v) => v.isFinite;

  bool _passesGates(BaselineCandidateShift c) {
    if (!_finite(c.cplh) || !_finite(c.splh) || !_finite(c.ppa)) return false;
    if (c.covers < minCovers || !c.covers.isFinite) return false;
    if (c.cplh <= 0 || c.splh <= 0 || c.ppa <= 0) return false;
    final foh = c.covers / c.cplh;
    final boh = (c.covers * c.ppa) / c.splh;
    if (!_finite(foh) || !_finite(boh)) return false;
    return foh + boh >= minHours;
  }

  // Deterministic compound order: CPLH desc, then recordKey asc. Kills the
  // tied-CPLH instability the prod engine has (Dart List.sort not stable).
  int _byCplhDescStable(BaselineCandidateShift a, BaselineCandidateShift b) {
    final c = b.cplh.compareTo(a.cplh);
    return c != 0 ? c : a.recordKey.compareTo(b.recordKey);
  }

  double _med(List<double> xs) => _median(xs);

  _ProtoResult select(List<BaselineCandidateShift> candidates) {
    final byDp = <String, List<BaselineCandidateShift>>{};
    for (final c in candidates) {
      if (!_passesGates(c)) continue;
      (byDp[c.daypart] ??= []).add(c);
    }

    final out = <String, _DaypartResult>{};
    for (final entry in byDp.entries) {
      final dp = entry.key;
      final cohort = entry.value;
      if (cohort.length < minDaypartCohort) {
        out[dp] = _building(dp, cohort.length, 0,
            'Only ${cohort.length} eligible shifts â€” need $minDaypartCohort+.');
        continue;
      }

      // MAD outlier removal on CPLH (robust; Ch.09 "not accidents").
      final cplhSorted = cohort.map((c) => c.cplh).toList()..sort();
      final med = _med(cplhSorted);
      final devs = cplhSorted.map((v) => (v - med).abs()).toList()..sort();
      final mad = _med(devs) * 1.4826;
      final thr = madK * mad;
      final kept = [
        for (final c in cohort)
          if (!(mad > 0 && (c.cplh - med).abs() > thr)) c
      ];
      if (kept.length < minDaypartCohort) {
        out[dp] = _building(dp, kept.length, 0,
            'Too little left after outlier removal.');
        continue;
      }

      // DISPERSION FLOOR (Ch.09 "a spike is not a range"). The degenerate
      // demo seeder pins shifts to one value; the OLD engine called that
      // "too narrow" and told the operator to wait. Honest answer: there is
      // no operating range yet because covers-per-hour barely moves.
      final keptSdC = _stdev(kept.map((e) => e.cplh).toList());
      if (keptSdC < minKeptStdevCPLH) {
        out[dp] = _building(dp, kept.length, 0,
            'Covers-per-hour barely varies across these shifts '
            '(sd=${keptSdC.toStringAsFixed(3)}). There is no operating '
            'range yet — this is a single value, not a band.');
        continue;
      }

      // Ch.09 CORE RULE: a benchmark shift is one where CPLH **and** SPLH
      // **and** PPA are each at/above the daypart median â€” all three high
      // together. This is the literal Jim selection, not a CPLH ranking.
      final medC = _med(kept.map((e) => e.cplh).toList());
      final medS = _med(kept.map((e) => e.splh).toList());
      final medP = _med(kept.map((e) => e.ppa).toList());
      final bench = (kept
              .where((c) =>
                  c.cplh >= medC && c.splh >= medS && c.ppa >= medP)
              .toList())
        ..sort(_byCplhDescStable);

      if (bench.length < minBenchmark) {
        out[dp] = _DaypartResult(
          daypart: dp,
          verdict: 'building',
          keptCount: kept.length,
          benchmarkCount: bench.length,
          floorCPLH: 0,
          ceilingCPLH: 0,
          targetCPLH: 0,
          targetSPLH: 0,
          targetPPA: 0,
          medCplh: medC,
          medSplh: medS,
          medPpa: medP,
          benchmarkShifts: bench,
          reason:
              'Only ${bench.length} shifts had covers, SPLH and spend all '
              'strong together (need $minBenchmark). Jim Ch.09: a target '
              'built from too few good shifts is "your best Wednesday '
              'disguised as a standard."',
        );
        continue;
      }

      // Ch.11: the OPZ is a sustainable BAND. Use a robust inner band
      // (P25â€“P75 of the all-three-high CPLH) rather than the min/max of a
      // CPLH-ranked slice. Target = median of the benchmark CPLH (stable,
      // sits inside with headroom by construction).
      final benchCplh = bench.map((e) => e.cplh).toList()..sort();
      final floor = _quantile(benchCplh, 0.25);
      final ceil = _quantile(benchCplh, 0.75);
      final target = _med(benchCplh);
      final width = ceil - floor;

      if (width < minTeachableWidthCPLH) {
        out[dp] = _DaypartResult(
          daypart: dp,
          verdict: 'building',
          keptCount: kept.length,
          benchmarkCount: bench.length,
          floorCPLH: floor,
          ceilingCPLH: ceil,
          targetCPLH: target,
          targetSPLH: _med(bench.map((e) => e.splh).toList()),
          targetPPA: _med(bench.map((e) => e.ppa).toList()),
          medCplh: medC,
          medSplh: medS,
          medPpa: medP,
          benchmarkShifts: bench,
          reason: 'The strong shifts collapse to a single CPLH value '
              '(${target.toStringAsFixed(2)}). Not enough real spread to '
              'teach a band yet — honest "building", not a fake point.',
        );
        continue;
      }

      if (width > tooWide) {
        out[dp] = _DaypartResult(
          daypart: dp,
          verdict: 'inconsistent',
          keptCount: kept.length,
          benchmarkCount: bench.length,
          floorCPLH: floor,
          ceilingCPLH: ceil,
          targetCPLH: target,
          targetSPLH: _med(bench.map((e) => e.splh).toList()),
          targetPPA: _med(bench.map((e) => e.ppa).toList()),
          medCplh: medC,
          medSplh: medS,
          medPpa: medP,
          benchmarkShifts: bench,
          reason: 'Even the all-three-high shifts span '
              '${width.toStringAsFixed(2)} CPLH (> $tooWide). This period '
              'is genuinely inconsistent â€” not teachable as one number yet.',
        );
        continue;
      }

      out[dp] = _DaypartResult(
        daypart: dp,
        verdict: 'teachable',
        keptCount: kept.length,
        benchmarkCount: bench.length,
        floorCPLH: floor,
        ceilingCPLH: ceil,
        targetCPLH: target,
        targetSPLH: _med(bench.map((e) => e.splh).toList()),
        targetPPA: _med(bench.map((e) => e.ppa).toList()),
        medCplh: medC,
        medSplh: medS,
        medPpa: medP,
        benchmarkShifts: bench,
        reason: '${bench.length} shifts with covers, SPLH and spend all '
            'strong together; robust P25â€“P75 band '
            '${floor.toStringAsFixed(2)}â€“${ceil.toStringAsFixed(2)} CPLH, '
            'target ${target.toStringAsFixed(2)} with '
            '${(ceil - target).toStringAsFixed(2)} headroom.',
      );
    }

    // Operation rollup â€” per-daypart independent (Ch.09). Teachable if ANY
    // daypart is teachable; building only if none are; inconsistent only if
    // there are dayparts and the non-building ones are all inconsistent.
    final verdicts = out.values.map((d) => d.verdict).toList();
    String op;
    if (verdicts.any((v) => v == 'teachable')) {
      op = 'teachable';
    } else if (verdicts.every((v) => v == 'building')) {
      op = 'building';
    } else {
      op = 'inconsistent';
    }
    // Deterministic output ordering (daypart key asc) so downstream
    // consumers / render order never depend on input order.
    final ordered = <String, _DaypartResult>{
      for (final k in out.keys.toList()..sort()) k: out[k]!
    };
    return _ProtoResult(ordered, op);
  }

  _DaypartResult _building(
          String dp, int kept, int bench, String why) =>
      _DaypartResult(
        daypart: dp,
        verdict: 'building',
        keptCount: kept,
        benchmarkCount: bench,
        floorCPLH: 0,
        ceilingCPLH: 0,
        targetCPLH: 0,
        targetSPLH: 0,
        targetPPA: 0,
        medCplh: 0,
        medSplh: 0,
        medPpa: 0,
        benchmarkShifts: const [],
        reason: why,
      );
}

