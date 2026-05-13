// ─── Dollar-Impact Attribution Tests (7.58.1) ────────────────────────────────
// Pins `LaborModel.attributeDollarImpactByAxis` per the audit Findings:
//
//   docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md
//     Sub-Slice Family `.1` — per-driver dollar-impact attribution.
//     Findings F-3 — producer call sites pass different optional-axis
//     subsets; null axes contribute 0 dollars.
//
// Pinned behaviour:
//   • per-axis math for each of the 16 lever ids
//   • sign convention: positive = adverse, negative = favorable
//     (matches `LaborModel.isFavorableLever` polarity)
//   • per-axis sum equals `LaborModel.dollarGap(...)` on the trio fixture
//     (covers=1140 / sales=47838 / fohHrs=280 / bohHrs=290) borrowed from
//     test/wtd_variance_logic_test.dart
//   • optional axes whose inputs are null contribute 0
//   • empty candidate set (every axis on target) returns all zeros
//   • perfect schedule flex with covers nets to zero across covers and the
//     hours-vs-baseline axis

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

final _tCPLH = BaselineData.derivedTargetCPLH;
final _tSPLH = BaselineData.derivedTargetSPLH;
final _tPPA = BaselineData.derivedTargetPPA;
const _fohW = MeridianConfig.fohWage;
const _bohW = MeridianConfig.bohWage;

const _allLeverIds = <String>[
  'covers_down', 'covers_up',
  'ppa_down', 'ppa_up',
  'cplh_down', 'cplh_up',
  'splh_down', 'splh_up',
  'foh_wage_down', 'foh_wage_up',
  'boh_wage_down', 'boh_wage_up',
  'foh_hours_over', 'foh_hours_under',
  'boh_hours_over', 'boh_hours_under',
];

const _favorableIds = <String>{
  'covers_up', 'ppa_up', 'cplh_up', 'splh_up',
  'foh_wage_down', 'boh_wage_down',
  'foh_hours_under', 'boh_hours_under',
};

Map<String, double> _attribute({
  required int actualCovers,
  int forecastCovers = 1200,
  required int actualFohHours,
  required int actualBohHours,
  required double avgPPA,
  double? targetCPLH,
  double? targetSPLH,
  double? targetPPA,
  double? targetFohWage,
  double? targetBohWage,
  double? avgCPLH,
  double? avgSPLH,
  double? avgFohBlendedWage,
  double? avgBohBlendedWage,
  int? scheduledFohHours,
  int? modelFohHoursDenominator,
  int? scheduledBohHours,
  int? modelBohHoursDenominator,
}) {
  return LaborModel.attributeDollarImpactByAxis(
    actualCovers: actualCovers,
    forecastCovers: forecastCovers,
    actualFohHours: actualFohHours,
    actualBohHours: actualBohHours,
    avgPPA: avgPPA,
    targetCPLH: targetCPLH ?? _tCPLH,
    targetSPLH: targetSPLH ?? _tSPLH,
    targetPPA: targetPPA ?? _tPPA,
    targetFohWage: targetFohWage ?? _fohW,
    targetBohWage: targetBohWage ?? _bohW,
    avgCPLH: avgCPLH,
    avgSPLH: avgSPLH,
    avgFohBlendedWage: avgFohBlendedWage,
    avgBohBlendedWage: avgBohBlendedWage,
    scheduledFohHours: scheduledFohHours,
    modelFohHoursDenominator: modelFohHoursDenominator,
    scheduledBohHours: scheduledBohHours,
    modelBohHoursDenominator: modelBohHoursDenominator,
  );
}

double _sum(Map<String, double> m) =>
    m.values.fold<double>(0.0, (a, b) => a + b);

void main() {
  group('attributeDollarImpactByAxis — round-trip with dollarGap', () {
    test('trio fixture: per-axis sum equals dollarGap exactly', () {
      // Same trio used by test/wtd_variance_logic_test.dart →
      // 'dollarGap and annualized match manual computation'.
      const covers = 1140;
      const sales = 47838.0;
      const fohHrs = 280;
      const bohHrs = 290;
      final avgPPA = sales / covers;
      final avgCPLH = covers / fohHrs;
      final avgSPLH = sales / bohHrs;

      final gap = LaborModel.dollarGap(
        fohHrs * _fohW + bohHrs * _bohW,
        covers,
        avgPPA,
        targetCPLH: _tCPLH,
        targetSPLH: _tSPLH,
        fohWage: _fohW,
        bohWage: _bohW,
      );

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: avgPPA,
        avgCPLH: avgCPLH,
        avgSPLH: avgSPLH,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      // Sum across all 16 ids equals the dollarGap, modulo the rounding the
      // model-hour formula applies internally.
      expect(_sum(attribution), closeTo(gap, 0.01),
          reason: 'Σ axis contributions must equal dollarGap');
      // dollarGap is positive (over-model) on this fixture.
      expect(gap, greaterThan(0));
    });

    test('round-trip holds when wages are off-target', () {
      const covers = 1140;
      const sales = 47838.0;
      const fohHrs = 280;
      const bohHrs = 290;
      final avgPPA = sales / covers;
      final avgCPLH = covers / fohHrs;
      final avgSPLH = sales / bohHrs;
      const actualFohWage = 17.50;
      const actualBohWage = 22.50;

      final gap = LaborModel.dollarGap(
        fohHrs * actualFohWage + bohHrs * actualBohWage,
        covers,
        avgPPA,
        targetCPLH: _tCPLH,
        targetSPLH: _tSPLH,
        fohWage: _fohW,
        bohWage: _bohW,
      );

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: avgPPA,
        avgCPLH: avgCPLH,
        avgSPLH: avgSPLH,
        avgFohBlendedWage: actualFohWage,
        avgBohBlendedWage: actualBohWage,
      );

      expect(_sum(attribution), closeTo(gap, 0.01));
      expect(attribution['foh_wage_up'], greaterThan(0));
      expect(attribution['boh_wage_up'], greaterThan(0));
    });

    test('round-trip holds with covers_up + favorable rates', () {
      // Covers above forecast, cplh up, splh up, wages on target.
      // Verifies signed sum on a favorable-leaning shift.
      const covers = 1280;
      const fcCovers = 1200;
      const fohHrs = 250; // fewer hours than forecast model → favorable cplh
      const bohHrs = 245; // fewer hours than forecast model → favorable splh
      final avgPPA = _tPPA;
      final avgCPLH = covers / fohHrs;
      final avgSPLH = (covers * avgPPA) / bohHrs;

      final gap = LaborModel.dollarGap(
        fohHrs * _fohW + bohHrs * _bohW,
        covers,
        avgPPA,
        targetCPLH: _tCPLH,
        targetSPLH: _tSPLH,
        fohWage: _fohW,
        bohWage: _bohW,
      );

      final attribution = _attribute(
        actualCovers: covers,
        forecastCovers: fcCovers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: avgPPA,
        avgCPLH: avgCPLH,
        avgSPLH: avgSPLH,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(_sum(attribution), closeTo(gap, 0.01));
    });
  });

  group('attributeDollarImpactByAxis — sign convention', () {
    test('every non-zero entry agrees with LaborModel.isFavorableLever', () {
      // Sweep three deviation scenarios and confirm the polarity rule:
      //   adverse lever id → positive dollar contribution
      //   favorable lever id → negative dollar contribution
      final scenarios = <String, Map<String, dynamic>>{
        'trio (covers down + cplh down + splh down)': {
          'covers': 1140,
          'forecastCovers': 1200,
          'fohHrs': 280,
          'bohHrs': 290,
          'avgPPA': 47838.0 / 1140,
        },
        'covers up + favorable rates': {
          'covers': 1280,
          'forecastCovers': 1200,
          'fohHrs': 250,
          'bohHrs': 245,
          'avgPPA': _tPPA,
        },
        'wage premium up only': {
          'covers': 1200,
          'forecastCovers': 1200,
          'fohHrs': LaborModel.modelFohHours(1200, _tCPLH),
          'bohHrs': LaborModel.modelBohHours(1200, _tPPA, _tSPLH),
          'avgPPA': _tPPA,
          'fohWage': 17.50,
          'bohWage': 22.50,
        },
      };

      for (final entry in scenarios.entries) {
        final s = entry.value;
        final covers = s['covers'] as int;
        final fcCovers = s['forecastCovers'] as int;
        final fohHrs = s['fohHrs'] as int;
        final bohHrs = s['bohHrs'] as int;
        final avgPPA = s['avgPPA'] as double;
        final fohWage = (s['fohWage'] ?? _fohW) as double;
        final bohWage = (s['bohWage'] ?? _bohW) as double;

        final attribution = _attribute(
          actualCovers: covers,
          forecastCovers: fcCovers,
          actualFohHours: fohHrs,
          actualBohHours: bohHrs,
          avgPPA: avgPPA,
          avgCPLH: covers / fohHrs,
          avgSPLH: (covers * avgPPA) / bohHrs,
          avgFohBlendedWage: fohWage,
          avgBohBlendedWage: bohWage,
        );

        for (final id in _allLeverIds) {
          final dollar = attribution[id]!;
          if (dollar == 0.0) continue;
          final favorable = _favorableIds.contains(id);
          expect(LaborModel.isFavorableLever(id), favorable,
              reason: 'fixture sanity: $id favorability table');
          if (favorable) {
            expect(dollar, lessThan(0),
                reason:
                    '${entry.key}: $id is favorable → must carry NEGATIVE dollars');
          } else {
            expect(dollar, greaterThan(0),
                reason:
                    '${entry.key}: $id is adverse → must carry POSITIVE dollars');
          }
        }
      }
    });
  });

  group('attributeDollarImpactByAxis — empty candidate set', () {
    test('all axes on target → every lever id returns 0', () {
      const covers = 1200;
      final fohHrs = LaborModel.modelFohHours(covers, _tCPLH);
      final bohHrs = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        forecastCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: _tPPA,
        avgCPLH: covers / fohHrs,
        avgSPLH: (covers * _tPPA) / bohHrs,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        scheduledFohHours: fohHrs,
        modelFohHoursDenominator: fohHrs,
        scheduledBohHours: bohHrs,
        modelBohHoursDenominator: bohHrs,
      );

      for (final id in _allLeverIds) {
        expect(attribution[id], 0.0,
            reason: '$id must be 0 when every axis is on target');
      }
      expect(_sum(attribution), 0.0);
    });
  });

  group('attributeDollarImpactByAxis — covers axis (Walk Step 1)', () {
    test(
        'covers_down: covers below forecast → positive contribution on '
        'covers_down (model shed hours your forecast schedule was sized for)',
        () {
      const covers = 1100;
      const fcCovers = 1200;
      final mFhForecast = LaborModel.modelFohHours(fcCovers, _tCPLH);
      final mFhActual = LaborModel.modelFohHours(covers, _tCPLH);
      final mBhForecast = LaborModel.modelBohHours(fcCovers, _tPPA, _tSPLH);
      final mBhActualCoversTargetPpa =
          LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final fohHrs = mFhForecast; // schedule did not flex with covers
      final bohHrs = mBhForecast;

      final attribution = _attribute(
        actualCovers: covers,
        forecastCovers: fcCovers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: _tPPA,
        avgCPLH: covers / fohHrs,
        avgSPLH: (covers * _tPPA) / bohHrs,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      final expectedCovers =
          -(mFhActual - mFhForecast) * _fohW +
              -(mBhActualCoversTargetPpa - mBhForecast) * _bohW;
      expect(attribution['covers_down'], greaterThan(0));
      expect(attribution['covers_up'], 0.0);
      expect(attribution['covers_down'], closeTo(expectedCovers, 0.001));
    });

    test('covers_up: covers above forecast → negative contribution on covers_up',
        () {
      const covers = 1280;
      const fcCovers = 1200;
      final mFhForecast = LaborModel.modelFohHours(fcCovers, _tCPLH);
      final mFhActual = LaborModel.modelFohHours(covers, _tCPLH);
      final mBhForecast = LaborModel.modelBohHours(fcCovers, _tPPA, _tSPLH);
      final mBhActualCoversTargetPpa =
          LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        forecastCovers: fcCovers,
        actualFohHours: mFhForecast, // didn't flex up with covers
        actualBohHours: mBhForecast,
        avgPPA: _tPPA,
        avgCPLH: covers / mFhForecast,
        avgSPLH: (covers * _tPPA) / mBhForecast,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      final expectedCovers =
          -(mFhActual - mFhForecast) * _fohW +
              -(mBhActualCoversTargetPpa - mBhForecast) * _bohW;
      expect(attribution['covers_up'], lessThan(0));
      expect(attribution['covers_down'], 0.0);
      expect(attribution['covers_up'], closeTo(expectedCovers, 0.001));
    });

    test('perfect schedule flex with covers down: covers_down and cplh_up '
        'offset, sum stays at the wage-premium-only gap', () {
      // Covers come in low AND schedule flexes proportionally to the new
      // model. cplh stays on target. Walk Step 1 credits covers_down with
      // a positive amount, Walk Step 3 credits cplh_up with the same
      // amount negated → net 0 dollar gap (which is the right answer).
      const covers = 1100;
      const fcCovers = 1200;
      final mFhActual = LaborModel.modelFohHours(covers, _tCPLH);
      final mBhActual = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        forecastCovers: fcCovers,
        actualFohHours: mFhActual, // perfectly flexed with covers
        actualBohHours: mBhActual,
        avgPPA: _tPPA,
        avgCPLH: covers / mFhActual,
        avgSPLH: (covers * _tPPA) / mBhActual,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['covers_down'], greaterThan(0));
      expect(attribution['cplh_up'], lessThan(0));
      // Net of covers + cplh on FOH side: cancels.
      // Net of covers + splh on BOH side: cancels.
      expect(_sum(attribution), closeTo(0.0, 0.001));
    });
  });

  group('attributeDollarImpactByAxis — ppa axis (Walk Step 2)', () {
    test('ppa_down: actualPPA below target → positive contribution on ppa_down',
        () {
      const covers = 1200;
      final avgPPA = _tPPA * 0.94;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBhActualCoversTargetPpa =
          LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final mBhActual = LaborModel.modelBohHours(covers, avgPPA, _tSPLH);
      final fohHrs = mFh;
      final bohHrs = mBhActualCoversTargetPpa; // schedule sized for target ppa

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: avgPPA,
        avgCPLH: covers / fohHrs,
        avgSPLH: (covers * avgPPA) / bohHrs,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      final expectedPpa =
          -(mBhActual - mBhActualCoversTargetPpa) * _bohW;
      expect(attribution['ppa_down'], greaterThan(0));
      expect(attribution['ppa_up'], 0.0);
      expect(attribution['ppa_down'], closeTo(expectedPpa, 0.001));
    });

    test('ppa_up: actualPPA above target → negative contribution on ppa_up',
        () {
      const covers = 1200;
      final avgPPA = _tPPA * 1.07;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBhActualCoversTargetPpa =
          LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final mBhActual = LaborModel.modelBohHours(covers, avgPPA, _tSPLH);
      final fohHrs = mFh;
      final bohHrs = mBhActualCoversTargetPpa;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: avgPPA,
        avgCPLH: covers / fohHrs,
        avgSPLH: (covers * avgPPA) / bohHrs,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      final expectedPpa =
          -(mBhActual - mBhActualCoversTargetPpa) * _bohW;
      expect(attribution['ppa_up'], lessThan(0));
      expect(attribution['ppa_down'], 0.0);
      expect(attribution['ppa_up'], closeTo(expectedPpa, 0.001));
    });
  });

  group('attributeDollarImpactByAxis — productivity (cplh) axis (Walk Step 3)',
      () {
    test(
        'cplh_down: hours over forecast baseline → positive contribution on '
        'cplh_down', () {
      // Covers on forecast → modelFohForecast == modelFohActual; FOH hours
      // term is the pure productivity (or schedule-discipline) deviation.
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final actualFoh = mFh + 30;
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: actualFoh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / actualFoh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['cplh_down'], greaterThan(0));
      expect(attribution['cplh_up'], 0.0);
      expect(attribution['cplh_down'], (actualFoh - mFh) * _fohW);
    });

    test(
        'cplh_up: hours under forecast baseline → negative contribution on '
        'cplh_up', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final actualFoh = mFh - 25;
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: actualFoh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / actualFoh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['cplh_up'], lessThan(0));
      expect(attribution['cplh_down'], 0.0);
      expect(attribution['cplh_up'], (actualFoh - mFh) * _fohW);
    });

    test('avgCPLH null → cplh_up/down both 0 (axis returns 0)', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final actualFoh = mFh + 30;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: actualFoh,
        actualBohHours: LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
        avgPPA: _tPPA,
        // avgCPLH NOT provided → cplh axis disabled; falls through to
        // hours-flex axis which is also disabled (no scheduledFohHours).
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        avgSPLH: (covers * _tPPA) /
            LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
      );

      expect(attribution['cplh_down'], 0.0);
      expect(attribution['cplh_up'], 0.0);
      expect(attribution['foh_hours_over'], 0.0);
      expect(attribution['foh_hours_under'], 0.0);
    });
  });

  group('attributeDollarImpactByAxis — productivity (splh) axis (Walk Step 4)',
      () {
    test(
        'splh_down: BOH hours over forecast baseline → positive contribution on '
        'splh_down', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final actualBoh = mBh + 40;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: actualBoh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / actualBoh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['splh_down'], greaterThan(0));
      expect(attribution['splh_up'], 0.0);
      expect(attribution['splh_down'], (actualBoh - mBh) * _bohW);
    });

    test(
        'splh_up: BOH hours under forecast baseline → negative contribution on '
        'splh_up', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final actualBoh = mBh - 30;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: actualBoh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / actualBoh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['splh_up'], lessThan(0));
      expect(attribution['splh_down'], 0.0);
      expect(attribution['splh_up'], (actualBoh - mBh) * _bohW);
    });

    test('avgSPLH null → splh_up/down both 0 (axis returns 0)', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final actualBoh = mBh + 40;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: actualBoh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        // avgSPLH NOT provided.
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['splh_down'], 0.0);
      expect(attribution['splh_up'], 0.0);
    });
  });

  group('attributeDollarImpactByAxis — wage axes (Walk Steps 5/6)', () {
    test('foh_wage_up: actual FOH wage above target → positive contribution',
        () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      const actualFohWage = 17.50;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: actualFohWage,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['foh_wage_up'], greaterThan(0));
      expect(attribution['foh_wage_down'], 0.0);
      // Walk Step 5 uses actualFohHours (= mFh here), not modelFohActual.
      expect(attribution['foh_wage_up'], mFh * (actualFohWage - _fohW));
    });

    test('foh_wage_down: actual FOH wage below target → negative contribution',
        () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      const actualFohWage = 15.00;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: actualFohWage,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['foh_wage_down'], lessThan(0));
      expect(attribution['foh_wage_up'], 0.0);
      expect(attribution['foh_wage_down'], mFh * (actualFohWage - _fohW));
    });

    test('boh_wage_up: actual BOH wage above target → positive contribution',
        () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      const actualBohWage = 23.00;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: actualBohWage,
      );

      expect(attribution['boh_wage_up'], greaterThan(0));
      expect(attribution['boh_wage_down'], 0.0);
      expect(attribution['boh_wage_up'], mBh * (actualBohWage - _bohW));
    });

    test('boh_wage_down: actual BOH wage below target → negative contribution',
        () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      const actualBohWage = 19.50;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: actualBohWage,
      );

      expect(attribution['boh_wage_down'], lessThan(0));
      expect(attribution['boh_wage_up'], 0.0);
      expect(attribution['boh_wage_down'], mBh * (actualBohWage - _bohW));
    });

    test('avgFohBlendedWage null → foh_wage_up/down both 0', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        // avgFohBlendedWage NOT provided.
        avgBohBlendedWage: _bohW,
      );

      expect(attribution['foh_wage_up'], 0.0);
      expect(attribution['foh_wage_down'], 0.0);
    });

    test('avgBohBlendedWage null → boh_wage_up/down both 0', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgSPLH: (covers * _tPPA) / mBh,
        avgFohBlendedWage: _fohW,
        // avgBohBlendedWage NOT provided.
      );

      expect(attribution['boh_wage_up'], 0.0);
      expect(attribution['boh_wage_down'], 0.0);
    });
  });

  group('attributeDollarImpactByAxis — hours-flex fallback', () {
    test('avgCPLH null + scheduledFohHours/modelFohHoursDenominator given → '
        'foh_hours_over fires on positive hours-vs-baseline term', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final actualFoh = mFh + 30;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: actualFoh,
        actualBohHours: LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
        avgPPA: _tPPA,
        // avgCPLH NOT provided → fall back to hours-flex axis.
        avgSPLH: (covers * _tPPA) /
            LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        scheduledFohHours: actualFoh,
        modelFohHoursDenominator: mFh,
      );

      expect(attribution['foh_hours_over'], greaterThan(0));
      expect(attribution['foh_hours_under'], 0.0);
      expect(attribution['cplh_down'], 0.0,
          reason: 'cplh axis disabled when avgCPLH is null');
      expect(attribution['foh_hours_over'], (actualFoh - mFh) * _fohW);
    });

    test('avgCPLH null + scheduledFohHours/modelFohHoursDenominator given → '
        'foh_hours_under fires on negative hours-vs-baseline term', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final actualFoh = mFh - 25;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: actualFoh,
        actualBohHours: LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
        avgPPA: _tPPA,
        avgSPLH: (covers * _tPPA) /
            LaborModel.modelBohHours(covers, _tPPA, _tSPLH),
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        scheduledFohHours: actualFoh,
        modelFohHoursDenominator: mFh,
      );

      expect(attribution['foh_hours_under'], lessThan(0));
      expect(attribution['foh_hours_over'], 0.0);
    });

    test('avgSPLH null + scheduledBohHours/modelBohHoursDenominator given → '
        'boh_hours_over fires on positive BOH hours-vs-baseline term', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final actualBoh = mBh + 40;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: actualBoh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        // avgSPLH NOT provided → fall back to BOH hours-flex axis.
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        scheduledBohHours: actualBoh,
        modelBohHoursDenominator: mBh,
      );

      expect(attribution['boh_hours_over'], greaterThan(0));
      expect(attribution['boh_hours_under'], 0.0);
      expect(attribution['splh_down'], 0.0);
      expect(attribution['boh_hours_over'], (actualBoh - mBh) * _bohW);
    });

    test('avgSPLH null + scheduledBohHours/modelBohHoursDenominator given → '
        'boh_hours_under fires on negative BOH hours-vs-baseline term', () {
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);
      final actualBoh = mBh - 30;

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: actualBoh,
        avgPPA: _tPPA,
        avgCPLH: covers / mFh,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
        scheduledBohHours: actualBoh,
        modelBohHoursDenominator: mBh,
      );

      expect(attribution['boh_hours_under'], lessThan(0));
      expect(attribution['boh_hours_over'], 0.0);
      expect(attribution['splh_up'], 0.0);
      expect(attribution['boh_hours_under'], (actualBoh - mBh) * _bohW);
    });
  });

  group('attributeDollarImpactByAxis — invariants', () {
    test('every call returns exactly the 16 lever ids', () {
      const covers = 1140;
      const fohHrs = 280;
      const bohHrs = 290;
      const sales = 47838.0;
      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: fohHrs,
        actualBohHours: bohHrs,
        avgPPA: sales / covers,
        avgCPLH: covers / fohHrs,
        avgSPLH: sales / bohHrs,
        avgFohBlendedWage: _fohW,
        avgBohBlendedWage: _bohW,
      );

      expect(attribution.keys.toSet(), _allLeverIds.toSet());
    });

    test('all-null optional axes → only 0 entries (sum = 0)', () {
      // Hours match forecast model, no wage axis, no flex axis — empty
      // candidate set semantics: every id returns 0 (covers/ppa cancel
      // because hours == forecast model and ppa == target).
      const covers = 1200;
      final mFh = LaborModel.modelFohHours(covers, _tCPLH);
      final mBh = LaborModel.modelBohHours(covers, _tPPA, _tSPLH);

      final attribution = _attribute(
        actualCovers: covers,
        actualFohHours: mFh,
        actualBohHours: mBh,
        avgPPA: _tPPA,
        // All optional axes null.
      );

      for (final id in _allLeverIds) {
        expect(attribution[id], 0.0,
            reason: '$id must be 0 when no optional axis enabled');
      }
    });
  });
}
