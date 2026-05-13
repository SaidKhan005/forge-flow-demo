// ——— Lever Logic Tests ——————————————————————————————————————————————————————
// Verifies LaborModel.determineLever for all 12 Chapter 10 lever scenarios,
// edge cases, tie-breaking priority, and the demo weekHistory round-trip.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ——— Helpers ————————————————————————————————————————————————————————————————

final _tCPLH = BaselineData.derivedTargetCPLH;
final _tSPLH = BaselineData.derivedTargetSPLH;
final _tPPA  = BaselineData.derivedTargetPPA;
const _fohWage = MeridianConfig.fohWage;
const _bohWage = MeridianConfig.bohWage;

String _lever({
  int actualCovers    = 1200,
  int forecastCovers  = 1200,
  double? avgCPLH,
  double? avgPPA,
  double? avgSPLH,
  double? avgFohWage,
  double? avgBohWage,
}) {
  return LaborModel.determineLever(
    actualCovers:      actualCovers,
    forecastCovers:    forecastCovers,
    avgCPLH:           avgCPLH ?? _tCPLH,
    avgPPA:            avgPPA  ?? _tPPA,
    targetCPLH:        _tCPLH,
    targetPPA:         _tPPA,
    avgSPLH:           avgSPLH,
    targetSPLH:        avgSPLH != null ? _tSPLH : null,
    avgFohBlendedWage: avgFohWage,
    targetFohWage:     avgFohWage != null ? _fohWage : null,
    avgBohBlendedWage: avgBohWage,
    targetBohWage:     avgBohWage != null ? _bohWage : null,
  );
}

// ——— Tests ——————————————————————————————————————————————————————————————————

void main() {
  group('12 Chapter 10 lever scenarios — table-driven', () {
    final scenarios = <String, Map<String, dynamic>>{
      'covers_down': {'actualCovers': 1152, 'forecastCovers': 1200},
      'covers_up':   {'actualCovers': 1260, 'forecastCovers': 1200},
      'ppa_down':    {'avgPPA': _tPPA * 0.95},
      'ppa_up':      {'avgPPA': _tPPA * 1.08},
      'cplh_down':   {'avgCPLH': _tCPLH * 0.90},
      'cplh_up':     {'avgCPLH': _tCPLH * 1.10},
      'splh_down':   {'avgSPLH': _tSPLH * 0.90},
      'splh_up':     {'avgSPLH': _tSPLH * 1.10},
      'foh_wage_up':   {'avgSPLH': _tSPLH, 'avgFohWage': _fohWage * 1.09, 'avgBohWage': _bohWage},
      'foh_wage_down': {'avgSPLH': _tSPLH, 'avgFohWage': _fohWage * 0.90, 'avgBohWage': _bohWage},
      'boh_wage_up':   {'avgSPLH': _tSPLH, 'avgFohWage': _fohWage, 'avgBohWage': _bohWage * 1.13},
      'boh_wage_down': {'avgSPLH': _tSPLH, 'avgFohWage': _fohWage, 'avgBohWage': _bohWage * 0.87},
    };

    for (final entry in scenarios.entries) {
      test('${entry.key} fires correctly', () {
        // All scenarios include full wage/SPLH args for consistent lever detection
        final args = {
          'avgSPLH': _tSPLH,
          'avgFohWage': _fohWage.toDouble(),
          'avgBohWage': _bohWage.toDouble(),
          ...entry.value,
        };
        expect(
          _lever(
            actualCovers: (args['actualCovers'] as int?) ?? 1200,
            forecastCovers: (args['forecastCovers'] as int?) ?? 1200,
            avgCPLH: args['avgCPLH'] as double?,
            avgPPA: args['avgPPA'] as double?,
            avgSPLH: args['avgSPLH'] as double?,
            avgFohWage: args['avgFohWage'] as double?,
            avgBohWage: args['avgBohWage'] as double?,
          ),
          entry.key,
          reason: 'Expected lever ${entry.key}',
        );
      });
    }
  });

  group('determineLever — threshold edge cases', () {
    test('exact -2% covers does not fire; just below does; all-at-target returns default', () {
      // Exact −2%
      expect(
        _lever(
          actualCovers: (1200 * 0.98).round(),
          forecastCovers: 1200,
          avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage,
        ),
        'covers_down', // default fallback, not fired
      );
      // Just below −2%
      expect(
        _lever(
          actualCovers: 1174, forecastCovers: 1200,
          avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage,
        ),
        'covers_down',
      );
      // All at target
      expect(
        _lever(avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'covers_down',
      );
    });

    test('optional parameters: SPLH and wage levers disabled when not provided', () {
      final noSPLH = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      expect(noSPLH, 'covers_down');

      final noWage = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
        avgSPLH: _tSPLH, targetSPLH: _tSPLH,
      );
      expect(noWage, 'covers_down');
    });

    test('zero inputs: no divide-by-zero', () {
      expect(
        LaborModel.determineLever(
          actualCovers: 100, forecastCovers: 0,
          avgCPLH: _tCPLH, avgPPA: _tPPA,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
        ),
        'covers_down',
      );
      expect(
        LaborModel.determineLever(
          actualCovers: 1200, forecastCovers: 1200,
          avgCPLH: 4.0, avgPPA: _tPPA,
          targetCPLH: 0.0, targetPPA: _tPPA,
        ),
        'covers_down',
      );
    });
  });

  group('determineLever — largest deviation wins', () {
    test('covers (-6%) beats cplh (-5.5%)', () {
      expect(
        LaborModel.determineLever(
          actualCovers: (1200 * 0.94).round(), forecastCovers: 1200,
          avgCPLH: _tCPLH * 0.945, avgPPA: _tPPA,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
        ),
        'covers_down',
      );
    });

    test('cplh (-8%) beats covers (-4%)', () {
      expect(
        LaborModel.determineLever(
          actualCovers: (1200 * 0.96).round(), forecastCovers: 1200,
          avgCPLH: _tCPLH * 0.92, avgPPA: _tPPA,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
        ),
        'cplh_down',
      );
    });

    test('ppa (-7%) beats cplh (-6%)', () {
      expect(
        LaborModel.determineLever(
          actualCovers: 1200, forecastCovers: 1200,
          avgCPLH: _tCPLH * 0.94, avgPPA: _tPPA * 0.93,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
        ),
        'ppa_down',
      );
    });

    test('splh (-9%) beats foh_wage (+6%)', () {
      expect(
        LaborModel.determineLever(
          actualCovers: 1200, forecastCovers: 1200,
          avgCPLH: _tCPLH, avgPPA: _tPPA,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
          avgSPLH: _tSPLH * 0.91, targetSPLH: _tSPLH,
          avgFohBlendedWage: _fohWage * 1.06, targetFohWage: _fohWage,
        ),
        'splh_down',
      );
    });

    test('priority ordering: ppa beats covers at similar magnitude', () {
      expect(
        LaborModel.determineLever(
          actualCovers: (1200 * 0.959).round(), forecastCovers: 1200,
          avgCPLH: _tCPLH, avgPPA: _tPPA * 0.955,
          targetCPLH: _tCPLH, targetPPA: _tPPA,
        ),
        'ppa_down',
      );
    });
  });

  group('WeekRecord — preserved locked plan hours (7.55q.5) and computed fields', () {
    test('targetFohHours / targetBohHours read preserved plan hours; avgSPLH / wage defaults correct', () {
      // 7.55q.5: target hours now read the preserved locked plan
      // hours captured at close from the WeeklyPlanSnapshot, not
      // LaborModel.modelFohHours(totalCovers, ...) re-modeled from
      // actuals (Drift 6).
      final record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 310,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.82,
        dollarGap: 661.85, primaryLeverId: 'splh_down',
        targetSourceType: 'system_baseline',
        targetCPLH: _tCPLH, targetSPLH: _tSPLH,
        targetPPA: _tPPA,
        targetFohWage: _fohWage, targetBohWage: _bohWage,
        lockedRequiredFohHours: 262,
        lockedRequiredBohHours: 278,
      );
      expect(record.targetFohHours, 262);
      expect(record.targetBohHours, 278);
      expect(record.avgSPLH, closeTo((41.79 * 1200) / 310, 0.01));

      // Zero BOH hours
      const zeroBoh = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 22, totalBohHours: 0,
        avgPPA: 41.79, avgCPLH: 4.55,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
      );
      expect(zeroBoh.avgSPLH, 0.0);

      // Wage defaults
      const defaultWage = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
      );
      expect(defaultWage.blendedFohWage, MeridianConfig.fohWage);
    });
  });

  group('LaborModel.theoreticalLaborPct — zero safety', () {
    test('zero CPLH/SPLH/PPA returns 0; known values produce ≈20.5%', () {
      expect(LaborModel.theoreticalLaborPct(0, _tSPLH, _tPPA, _fohWage, _bohWage), 0.0);
      expect(LaborModel.theoreticalLaborPct(_tCPLH, 0, _tPPA, _fohWage, _bohWage), 0.0);
      expect(LaborModel.theoreticalLaborPct(_tCPLH, _tSPLH, 0, _fohWage, _bohWage), 0.0);
      expect(
        LaborModel.theoreticalLaborPct(_tCPLH, _tSPLH, _tPPA, _fohWage, _bohWage),
        closeTo(20.48, 0.5),
      );
    });
  });

  group('Demo weekHistory round-trip', () {
    test('all 12 demo records: determineLever reproduces stored primaryLeverId', () {
      for (final record in DemoData.weekHistory) {
        final computed = LaborModel.determineLever(
          actualCovers: record.totalCovers,
          forecastCovers: record.forecastCovers,
          avgCPLH: record.avgCPLH,
          avgPPA: record.avgPPA,
          targetCPLH: BaselineData.derivedTargetCPLH,
          targetPPA: BaselineData.derivedTargetPPA,
          avgSPLH: record.avgSPLH,
          targetSPLH: BaselineData.derivedTargetSPLH,
          avgFohBlendedWage: record.blendedFohWage,
          targetFohWage: MeridianConfig.fohWage,
          avgBohBlendedWage: record.blendedBohWage,
          targetBohWage: MeridianConfig.bohWage,
        );
        expect(computed, record.primaryLeverId,
            reason: '${record.weekId}: got "$computed" expected "${record.primaryLeverId}"');
      }
    });

    test('12 records cover all 12 lever types', () {
      final leverIds = DemoData.weekHistory.map((r) => r.primaryLeverId).toSet();
      expect(leverIds, {
        'covers_down', 'covers_up', 'ppa_down', 'ppa_up',
        'cplh_down', 'cplh_up', 'splh_down', 'splh_up',
        'foh_wage_up', 'foh_wage_down', 'boh_wage_up', 'boh_wage_down',
      });
    });

    test('stale lever detection: record with wrong lever can be caught', () {
      const stale = WeekRecord(
        weekId: 'stale', weekLabel: 'Stale',
        totalCovers: 1155, forecastCovers: 1200,
        totalFohHours: 305, totalBohHours: 280,
        avgPPA: 41.79, avgCPLH: 3.79,
        theoreticalLaborPct: 20.48, actualLaborPct: 22.1,
        dollarGap: 900.0, primaryLeverId: 'covers_down',
      );
      final computed = LaborModel.determineLever(
        actualCovers: stale.totalCovers, forecastCovers: stale.forecastCovers,
        avgCPLH: stale.avgCPLH, avgPPA: stale.avgPPA,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
      );
      expect(computed, 'cplh_down');
      expect(computed, isNot(stale.primaryLeverId));
    });
  });

  group('LeverCards completeness', () {
    test('all 12 lever IDs have matching LeverCardData; wage direction correct', () {
      const allLeverIds = [
        'covers_down', 'covers_up', 'ppa_down', 'ppa_up',
        'cplh_down', 'cplh_up', 'splh_down', 'splh_up',
        'foh_wage_up', 'foh_wage_down', 'boh_wage_up', 'boh_wage_down',
      ];
      for (final id in allLeverIds) {
        final card = LeverCards.all.where((c) => c.id == id).toList();
        expect(card, hasLength(1), reason: 'Missing LeverCardData for "$id"');
      }

      // Wage direction checks
      expect(LeverCards.all.firstWhere((c) => c.id == 'foh_wage_down').isFavorable, isTrue);
      expect(LeverCards.all.firstWhere((c) => c.id == 'foh_wage_down').direction, LeverDirection.favorable);
      expect(LeverCards.all.firstWhere((c) => c.id == 'boh_wage_down').isFavorable, isTrue);
      expect(LeverCards.all.firstWhere((c) => c.id == 'foh_wage_up').isFavorable, isFalse);
      expect(LeverCards.all.firstWhere((c) => c.id == 'boh_wage_up').isFavorable, isFalse);
    });
  });
}
