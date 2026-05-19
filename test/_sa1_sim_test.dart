// TEMP SIM — deleted before commit. Search late12 good/soft params that
// give kept stdev>0.05 AND bench>=5 AND benchW in (0.03,1.25] for all 3
// per-location scales, using the EXACT SB pipeline math.
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _madRaw(List<double> sorted, double med) {
  final d = sorted.map((x) => (x - med).abs()).toList()..sort();
  return _median(d);
}

double _sd(List<double> v) {
  if (v.length < 2) return 0;
  final m = v.reduce((a, b) => a + b) / v.length;
  return math.sqrt(
      v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length);
}

double _q(List<double> s, double q) {
  if (s.isEmpty) return 0;
  if (s.length == 1) return s.first;
  final pos = (s.length - 1) * q;
  final lo = pos.floor(), hi = pos.ceil();
  if (lo == hi) return s[lo];
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

double _round2(double v) => double.parse(v.toStringAsFixed(2));

// in-window weeks: 4,5,6,7,8,9,10,11. good weeks {4,5,6,7,9,11},
// soft in-window {8,10}. weeks 8(splh-),10(cplh-) tilt down.
// Sat owns splh (driven down 0.88x) -> excluded from bench by SPLH gate.
// We model cplh only for the kept/MAD/median + bench-count gate; SPLH/PPA
// medians are low (Sat dragged) so Fri clear them — model that as: a Fri
// good shift is bench-eligible iff its cplh >= kept cplh median (the
// binding gate). Sat never bench-eligible.
({int bench, double keptSd, double benchW, bool ok}) evalScale(
    List<double> good6, List<double> soft2, double fine, double scale) {
  const baseC = 3.90;
  const tilt = 0.005;
  // good weeks order: [4,5,6,7,9,11] -> good6 ; soft weeks [8,10] -> soft2
  // fine vector per weekIndex (use the real one)
  const fineV = [
    0.005, -0.002, 0.003, -0.004, 0.002, -0.005,
    0.004, -0.003, 0.001, -0.002, 0.002, -0.001
  ];
  final shifts = <(double cplh, bool friGood)>[];
  final goodWeeks = [4, 5, 6, 7, 9, 11];
  final softWeeks = [8, 10];
  for (var k = 0; k < 6; k++) {
    final w = goodWeeks[k];
    final role = good6[k];
    final fr = _round2(baseC * (1 + role + fineV[w] + tilt) * scale);
    final sa = _round2(baseC * (1 + role + fineV[w] - tilt) * scale);
    shifts.add((fr, true)); // Fri good — bench-eligible if >= median
    shifts.add((sa, false)); // Sat — never bench-eligible (splh gate)
  }
  for (var k = 0; k < 2; k++) {
    final w = softWeeks[k];
    final role = soft2[k];
    final fr = _round2(baseC * (1 + role + fineV[w] + tilt) * scale);
    final sa = _round2(baseC * (1 + role + fineV[w] - tilt) * scale);
    shifts.add((fr, false));
    shifts.add((sa, false));
  }
  final cs = shifts.map((s) => s.$1).toList()..sort();
  final med = _median(cs);
  final amad = _madRaw(cs, med) * 1.4826;
  final thr = 3.0 * amad;
  final kept = shifts
      .where((s) => !(amad > 0 && (s.$1 - med).abs() > thr))
      .toList();
  if (kept.length < 3) return (bench: 0, keptSd: 0, benchW: 0, ok: false);
  final keptC = kept.map((s) => s.$1).toList();
  final keptSd = _sd(keptC);
  final mC = _median(keptC);
  final bench = kept.where((s) => s.$2 && s.$1 >= mC).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final bc = bench.map((s) => s.$1).toList()..sort();
  final w = bc.isEmpty ? 0.0 : _q(bc, 0.75) - _q(bc, 0.25);
  final ok = keptSd > 0.05 && bench.length >= 5 && w > 0.03 && w <= 1.25;
  return (bench: bench.length, keptSd: keptSd, benchW: w, ok: ok);
}

void main() {
  test('SIM search late12 params', () {
    // Try: good = continuum from gHi down to gLo (6 values), soft = sLo.
    final candidates = <String>[];
    for (final gHi in [0.030, 0.035, 0.038, 0.040, 0.042]) {
      for (final gLo in [0.012, 0.016, 0.020, 0.024, 0.028]) {
        if (gLo >= gHi) continue;
        for (final sLo in [-0.020, -0.026, -0.030, -0.034, -0.038]) {
          // 6 good evenly spaced gHi..gLo
          final good = <double>[];
          for (var i = 0; i < 6; i++) {
            good.add(gHi - (gHi - gLo) * i / 5.0);
          }
          // soft 2 at sLo (slightly different for zero-sum realism)
          final soft = [sLo, sLo - 0.002];
          var allOk = true;
          final detail = <String>[];
          for (final sc in [1.000, 1.045, 0.962, 1.028]) {
            final r = evalScale(good, soft, 0.0, sc);
            detail.add('sc$sc:b${r.bench}sd${r.keptSd.toStringAsFixed(3)}'
                'w${r.benchW.toStringAsFixed(3)}');
            if (!r.ok) allOk = false;
          }
          if (allOk) {
            candidates.add('gHi$gHi gLo$gLo sLo$sLo -> ${detail.join(" ")}');
          }
        }
      }
    }
    // ignore: avoid_print
    print('VIABLE (${candidates.length}):');
    for (final c in candidates) {
      // ignore: avoid_print
      print('  $c');
    }
    expect(candidates, isNotEmpty,
        reason: 'need at least one viable late12 param set');
  });
}
