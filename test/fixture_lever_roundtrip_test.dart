// ─── 7.58.4 Fixture Lever Round-Trip ─────────────────────────────────────────
// Pins Sub-Slice Family `.4` from `phase_7_58_primary_driver_audit_plan.md`
// and Finding F-3 (`7.58.0c`): every demo / replay fixture row must
// reproduce its stored `primaryLever` / `primaryLeverId` when re-fed
// through `LaborModel.determineLever` against the same row inputs. The
// fixture and the engine cannot drift.
//
// Two surfaces are pinned:
//
//   1. `DemoData` — `currentWeekShifts`, `weekHistory`,
//      `historicalClosedShifts`. Targets come from `BaselineData` /
//      `MeridianConfig` (the same seam `lever_logic_test.dart`'s
//      "Demo weekHistory round-trip" test already pins for week-level).
//
//   2. `MockIntegrationReplaySeed` — `currentWeekShifts`,
//      `historicalClosedShifts`, `weekRecords`. Targets come from the
//      seed's own `_targetCPLH` / `_targetSPLH` / `_targetPPA` /
//      `_fohWage` / `_bohWage` constants (replicated below — no public
//      accessor; the seed defines them inline).
//
// Plus the F-3 closure: `StaticShiftDataSource.getWeekToDate`
// must agree with `ShiftService.getWeekToDate` on the lever id for the
// same fixture week. This test exercises only the StaticShiftDataSource
// side (the live path needs SQLite); parity with the live path is
// enforced by both call sites passing the full axis set into
// `determineLever` after `7.58.4`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';

// ── Mock-replay-seed target standards (must mirror the constants at
// `lib/data/mock_integration_replay_seed.dart` lines 76-81). The seed
// keeps them private; this duplication is intentional pinning.
const double _seedTargetCPLH = 4.58;
const double _seedTargetSPLH = 180.0;
const double _seedTargetPPA = 41.50;
const double _seedFohWage = 16.50;
const double _seedBohWage = 21.35;

String _engineLeverForDemoShift(ShiftRecord s) {
  return LaborModel.determineLever(
    actualCovers: s.covers,
    forecastCovers: s.forecastCovers,
    avgCPLH: s.cplh,
    avgPPA: s.ppa,
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    avgSPLH: s.splh,
    targetSPLH: BaselineData.derivedTargetSPLH,
  );
}

String _engineLeverForDemoWeek(WeekRecord w) {
  final avgSPLH = w.totalBohHours > 0
      ? (w.avgPPA * w.totalCovers) / w.totalBohHours
      : 0.0;
  return LaborModel.determineLever(
    actualCovers: w.totalCovers,
    forecastCovers: w.forecastCovers,
    avgCPLH: w.avgCPLH,
    avgPPA: w.avgPPA,
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    avgSPLH: avgSPLH,
    targetSPLH: BaselineData.derivedTargetSPLH,
    avgFohBlendedWage: w.blendedFohWage,
    targetFohWage: MeridianConfig.fohWage,
    avgBohBlendedWage: w.blendedBohWage,
    targetBohWage: MeridianConfig.bohWage,
  );
}

String _engineLeverForReplayShift(ShiftRecord s) {
  // Single shape for both closed + projected branches. Reads `avg*`
  // from the persisted record (`s.cplh`, `s.ppa`, `s.splh`) so the
  // test pins what was actually stored, not what the seed constants
  // claim. Targets and wages are seed constants because they are not
  // carried on the row. A future seed change that drifts persisted
  // values away from the inputs the seed fed `determineLever` will
  // fail this test loudly — exactly what the round-trip is for.
  final modelFoh = LaborModel.modelFohHours(s.covers, _seedTargetCPLH);
  final modelBoh =
      LaborModel.modelBohHoursFromSales(s.actualSales, _seedTargetSPLH);
  return LaborModel.determineLever(
    actualCovers: s.covers,
    forecastCovers: s.forecastCovers,
    avgCPLH: s.cplh,
    avgPPA: s.ppa,
    targetCPLH: _seedTargetCPLH,
    targetPPA: _seedTargetPPA,
    avgSPLH: s.splh,
    targetSPLH: _seedTargetSPLH,
    avgFohBlendedWage: _seedFohWage,
    targetFohWage: _seedFohWage,
    avgBohBlendedWage: _seedBohWage,
    targetBohWage: _seedBohWage,
    scheduledFohHours: s.fohHours,
    modelFohHours: modelFoh,
    scheduledBohHours: s.bohHours,
    modelBohHours: modelBoh,
  );
}

String _engineLeverForReplayWeek(WeekRecord w, List<ShiftRecord> shifts) {
  final totalSales = shifts.fold<double>(0, (s, r) => s + r.actualSales);
  final avgSPLH = w.totalBohHours > 0 ? totalSales / w.totalBohHours : 0.0;
  final modelFoh = LaborModel.modelFohHours(w.totalCovers, _seedTargetCPLH);
  final modelBoh =
      LaborModel.modelBohHoursFromSales(totalSales, _seedTargetSPLH);
  final fohLaborDollar =
      shifts.fold<double>(0, (s, r) => s + r.fohLaborDollar);
  final bohLaborDollar =
      shifts.fold<double>(0, (s, r) => s + r.bohLaborDollar);
  final blendedFoh =
      w.totalFohHours > 0 ? fohLaborDollar / w.totalFohHours : _seedFohWage;
  final blendedBoh =
      w.totalBohHours > 0 ? bohLaborDollar / w.totalBohHours : _seedBohWage;
  return LaborModel.determineLever(
    actualCovers: w.totalCovers,
    forecastCovers: w.forecastCovers,
    avgCPLH: w.avgCPLH,
    avgPPA: w.avgPPA,
    targetCPLH: _seedTargetCPLH,
    targetPPA: _seedTargetPPA,
    avgSPLH: avgSPLH,
    targetSPLH: _seedTargetSPLH,
    avgFohBlendedWage: blendedFoh,
    targetFohWage: _seedFohWage,
    avgBohBlendedWage: blendedBoh,
    targetBohWage: _seedBohWage,
    scheduledFohHours: w.totalFohHours,
    modelFohHours: modelFoh,
    scheduledBohHours: w.totalBohHours,
    modelBohHours: modelBoh,
  );
}

// ── F-3 parity check: replicate the StaticShiftDataSource WTD axis set
// against the seed currentWeekShifts. After 7.58.4 the producer-side
// call already includes wages + hours-flex; this helper proves the
// round-trip explicitly so a future axis-subset regression on either
// side is caught immediately.
String _engineLeverForReplayWtd(List<ShiftRecord> closed) {
  final totalCovers = closed.fold<int>(0, (s, r) => s + r.covers);
  final totalFoh = closed.fold<int>(0, (s, r) => s + r.fohHours);
  final totalBoh = closed.fold<int>(0, (s, r) => s + r.bohHours);
  final totalSales = closed.fold<double>(0, (s, r) => s + r.actualSales);
  final wtdForecast =
      closed.fold<int>(0, (s, r) => s + r.forecastCovers);
  final fohLaborDollar =
      closed.fold<double>(0, (s, r) => s + r.fohLaborDollar);
  final bohLaborDollar =
      closed.fold<double>(0, (s, r) => s + r.bohLaborDollar);
  final blendedFoh = totalFoh > 0
      ? fohLaborDollar / totalFoh
      : MeridianConfig.fohWage;
  final blendedBoh = totalBoh > 0
      ? bohLaborDollar / totalBoh
      : MeridianConfig.bohWage;
  final avgCPLH = totalFoh > 0 ? totalCovers / totalFoh : 0.0;
  final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;
  final avgSPLH = totalBoh > 0 ? totalSales / totalBoh : 0.0;
  final modelFoh =
      LaborModel.modelFohHours(totalCovers, BaselineData.derivedTargetCPLH);
  final modelBoh = LaborModel.modelBohHoursFromSales(
      totalSales, BaselineData.derivedTargetSPLH);
  return LaborModel.determineLever(
    actualCovers: totalCovers,
    forecastCovers: wtdForecast,
    avgCPLH: avgCPLH,
    avgPPA: avgPPA,
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    avgSPLH: avgSPLH,
    targetSPLH: BaselineData.derivedTargetSPLH,
    avgFohBlendedWage: blendedFoh,
    targetFohWage: MeridianConfig.fohWage,
    avgBohBlendedWage: blendedBoh,
    targetBohWage: MeridianConfig.bohWage,
    scheduledFohHours: totalFoh,
    modelFohHours: modelFoh,
    scheduledBohHours: totalBoh,
    modelBohHours: modelBoh,
  );
}

void main() {
  group('DemoData (lib/dev/fixture_seed_data.dart) — every row round-trips', () {
    test('currentWeekShifts: stored primaryLever matches engine output', () {
      for (final s in DemoData.currentWeekShifts) {
        final computed = _engineLeverForDemoShift(s).toUpperCase();
        expect(s.primaryLever, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${s.weekId} ${s.dayLabel} ${s.daypart} ${s.status}: '
                'fixture stored "${s.primaryLever}", engine returns "$computed"');
      }
    });

    test('weekHistory: stored primaryLeverId matches engine output', () {
      for (final w in DemoData.weekHistory) {
        final computed = _engineLeverForDemoWeek(w);
        expect(w.primaryLeverId, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${w.weekId}: fixture stored "${w.primaryLeverId}", '
                'engine returns "$computed"');
      }
    });

    test('historicalClosedShifts (teaching + fill): every row round-trips', () {
      for (final s in DemoData.historicalClosedShifts) {
        final computed = _engineLeverForDemoShift(s).toUpperCase();
        expect(s.primaryLever, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${s.weekId} ${s.dayLabel} ${s.daypart}: fixture stored '
                '"${s.primaryLever}", engine returns "$computed"');
      }
    });
  });

  group('MockIntegrationReplaySeed — every row round-trips', () {
    final replay = MockIntegrationReplaySeed.output;

    test('currentWeekShifts (closed + projected) round-trip', () {
      for (final s in replay.currentWeekShifts) {
        final computed = _engineLeverForReplayShift(s).toUpperCase();
        expect(s.primaryLever, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${s.weekId} ${s.dayLabel} ${s.daypart} ${s.status}: '
                'seed stored "${s.primaryLever}", engine returns "$computed"');
      }
    });

    test('historicalClosedShifts round-trip', () {
      for (final s in replay.historicalClosedShifts) {
        final computed = _engineLeverForReplayShift(s).toUpperCase();
        expect(s.primaryLever, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${s.weekId} ${s.dayLabel} ${s.daypart}: '
                'seed stored "${s.primaryLever}", engine returns "$computed"');
      }
    });

    test('weekRecords round-trip against their constituent shifts', () {
      // Group historicalClosedShifts by weekId so the WeekRecord helper
      // can derive blended wages + avgSPLH from the same truth the seed
      // used at build time.
      final shiftsByWeek = <String, List<ShiftRecord>>{};
      for (final s in replay.historicalClosedShifts) {
        shiftsByWeek.putIfAbsent(s.weekId, () => []).add(s);
      }
      for (final w in replay.weekRecords) {
        final shifts = shiftsByWeek[w.weekId] ?? [];
        final computed = _engineLeverForReplayWeek(w, shifts);
        expect(w.primaryLeverId, computed,
            reason: 'F-3 / Sub-Slice .4 — '
                '${w.weekId}: seed stored "${w.primaryLeverId}", '
                'engine returns "$computed"');
      }
    });
  });

  group('F-3 closure: StaticShiftDataSource WTD === seed-side engine output',
      () {
    test('replay-seed WTD lever matches the engine output for the same week',
        () async {
      const dataSource = StaticShiftDataSource();
      final wtd = await dataSource.getWeekToDate();
      expect(wtd, isNotNull);

      // Compute the expected lever from the same closed shifts the data
      // source aggregates over. Both sides now feed wages + hours-flex
      // into determineLever (7.58.4 / F-3); a future axis-subset
      // regression on either side will fail this assertion.
      final replay = MockIntegrationReplaySeed.output;
      final closed = replay.currentWeekShifts.where((s) => s.isClosed).toList();
      final expected = _engineLeverForReplayWtd(closed);
      expect(wtd!.primaryLeverId, expected,
          reason: 'F-3 — StaticShiftDataSource and the engine must agree '
              'on the WTD lever id for the same fixture week.');
    });
  });
}
