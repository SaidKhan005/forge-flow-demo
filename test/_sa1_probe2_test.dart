// TEMP PROBE 2 — deleted before commit. Per-location late_night target.
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';

void main() {
  test('PROBE2 per-location daypart targets', () async {
    await SqliteDatabase.instance.reseedDemo();
    final out = MockIntegrationReplaySeed.output;
    final bd = out.scenario.currentBusinessDate;
    final ln = out.historicalClosedShifts
        .where((s) => s.daypart == 'late_night')
        .toList();
    final bdays = ln.map((s) => s.businessDate).toList()..sort();
    // ignore: avoid_print
    print('businessDate=$bd  totalLateNight=${ln.length} '
        'span=${bdays.first}..${bdays.last}');
    // 60-day window weekIndex survival (mirrors _seedRecommendationCandidates)
    final parts = bd.split('-').map(int.parse).toList();
    final cutoff = DateTime(parts[0], parts[1], parts[2])
        .subtract(const Duration(days: 59));
    final wk = <String, List<String>>{};
    for (final s in ln) {
      (wk[s.weekId] ??= []).add(
          '${s.dayLabel}:${s.cplh}:${s.splh}:${s.ppa}:'
          '${DateTime.parse(s.businessDate!).isAfter(cutoff) || DateTime.parse(s.businessDate!).isAtSameMomentAs(cutoff) ? "IN" : "OUT"}');
    }
    final keys = wk.keys.toList()..sort();
    for (final k in keys) {
      // ignore: avoid_print
      print('LN $k -> ${wk[k]}');
    }
    final db = await SqliteDatabase.instance.database;
    for (final rid in DemoScope.locations.map((l) => l.restaurantId)) {
      final r = await db.rawQuery(
          "SELECT COUNT(*) c FROM shift_records WHERE restaurant_id=? "
          "AND daypart='late_night' AND status='closed'",
          [rid]);
      // ignore: avoid_print
      print('$rid late_night closed rows = ${r.first['c']}');
    }
    // per-location late_night windowed CPLH spread
    final pp = bd.split('-').map(int.parse).toList();
    final co = DateTime(pp[0], pp[1], pp[2]).subtract(const Duration(days: 59));
    for (final rid in DemoScope.locations.map((l) => l.restaurantId)) {
      final rows = await db.rawQuery(
          "SELECT cplh,splh,ppa,business_date FROM shift_records "
          "WHERE restaurant_id=? AND daypart='late_night' AND status='closed'",
          [rid]);
      final win = rows
          .where((r) => !DateTime.parse(r['business_date'] as String)
              .isBefore(co))
          .toList();
      final cs = win.map((r) => (r['cplh'] as num).toDouble()).toList()
        ..sort();
      if (cs.length < 2) {
        // ignore: avoid_print
        print('$rid LN win n=${cs.length}');
        continue;
      }
      final m = cs.reduce((a, b) => a + b) / cs.length;
      final sd = (cs
                  .map((x) => (x - m) * (x - m))
                  .reduce((a, b) => a + b) /
              cs.length);
      // ignore: avoid_print
      print('$rid LN win n=${cs.length} cplh ${cs.first}..${cs.last} '
          'sd=${(sd > 0 ? sd : 0).toStringAsFixed(6)} '
          'vals=${cs.toSet().toList()}');
    }
    final ids = DemoScope.locations.map((l) => l.restaurantId).toList();
    for (final rid in ids) {
      final c = await SqliteTargetCycleRepository.instance.getActiveCycle(rid);
      if (c == null) {
        // ignore: avoid_print
        print('$rid -> NO CYCLE');
        continue;
      }
      for (final p in ['lunch', 'dinner', 'late_night']) {
        final d = c.daypartFor(p);
        // ignore: avoid_print
        print('$rid $p verdict=${d?.verdict} '
            'cplh=${d?.targetCPLH} splh=${d?.targetSPLH} ppa=${d?.targetPPA}');
      }
    }
  });
}
