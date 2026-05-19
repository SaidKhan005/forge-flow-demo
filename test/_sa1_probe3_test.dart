// TEMP PROBE 3 — deleted before commit. Per-location late_night bench.
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _mad(List<double> sorted, double med) {
  if (sorted.isEmpty) return 0;
  final d = sorted.map((x) => (x - med).abs()).toList()..sort();
  return _median(d);
}

double _q(List<double> s, double q) {
  if (s.isEmpty) return 0;
  if (s.length == 1) return s.first;
  final pos = (s.length - 1) * q;
  final lo = pos.floor(), hi = pos.ceil();
  if (lo == hi) return s[lo];
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

void main() {
  test('PROBE3 late_night bench per location', () async {
    await SqliteDatabase.instance.reseedDemo();
    final db = await SqliteDatabase.instance.database;
    const bd = '2026-03-27';
    final pp = bd.split('-').map(int.parse).toList();
    final co = DateTime(pp[0], pp[1], pp[2]).subtract(const Duration(days: 59));
    for (final rid in DemoScope.locations.map((l) => l.restaurantId)) {
      final rows = await db.rawQuery(
          "SELECT cplh,splh,ppa,business_date,day_label FROM shift_records "
          "WHERE restaurant_id=? AND daypart='late_night' AND status='closed'",
          [rid]);
      final win = rows
          .where((r) =>
              !DateTime.parse(r['business_date'] as String).isBefore(co))
          .toList();
      if (win.isEmpty) {
        // ignore: avoid_print
        print('$rid LN: empty');
        continue;
      }
      final cs = win.map((r) => (r['cplh'] as num).toDouble()).toList()
        ..sort();
      final med = _median(cs);
      final amad = _mad(cs, med) * 1.4826;
      final thr = 3.0 * amad;
      final kept = win
          .where((r) =>
              !(amad > 0 &&
                  ((r['cplh'] as num).toDouble() - med).abs() > thr))
          .toList();
      final keptC = kept.map((r) => (r['cplh'] as num).toDouble()).toList();
      double sd(List<double> v) {
        if (v.length < 2) return 0;
        final m = v.reduce((a, b) => a + b) / v.length;
        return math.sqrt(
            v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) /
                v.length);
      }

      final mC = _median(keptC);
      final mS =
          _median(kept.map((r) => (r['splh'] as num).toDouble()).toList());
      final mP =
          _median(kept.map((r) => (r['ppa'] as num).toDouble()).toList());
      final bench = kept
          .where((r) =>
              (r['cplh'] as num).toDouble() >= mC &&
              (r['splh'] as num).toDouble() >= mS &&
              (r['ppa'] as num).toDouble() >= mP)
          .toList();
      final bc = bench.map((r) => (r['cplh'] as num).toDouble()).toList()
        ..sort();
      final width = bc.isEmpty ? 0.0 : _q(bc, 0.75) - _q(bc, 0.25);
      // ignore: avoid_print
      print('$rid LN win=${win.length} kept=${kept.length} '
          'keptSd=${sd(keptC).toStringAsFixed(4)} '
          'medC=${mC.toStringAsFixed(3)} bench=${bench.length} '
          'benchW=${width.toStringAsFixed(4)} '
          'benchCPLH=${bc.toSet().toList()}');
    }
  });
}
