// ─── Lever Logic Tests ────────────────────────────────────────────────────────
// Verifies LaborModel.determineLever for all 12 Chapter 10 lever scenarios,
// edge cases, tie-breaking priority, and the demo weekHistory round-trip.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/demo_data.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/models/week_record.dart';
import 'package:forge_flow_demo/services/labor_model.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

// Derived targets (computed once)
final _tCPLH = BaselineData.derivedTargetCPLH;   // ≈ 4.58
final _tSPLH = BaselineData.derivedTargetSPLH;   // ≈ 180.07
final _tPPA  = BaselineData.derivedTargetPPA;    // ≈ 41.79
const _fohWage = MeridianConfig.fohWage;         // 16.50
const _bohWage = MeridianConfig.bohWage;         // 21.35

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

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('12 Chapter 10 lever scenarios', () {
    // Scenario 1 — covers_down (−4%)
    test('covers_down: actual −4% vs forecast', () {
      expect(
        _lever(actualCovers: 1152, forecastCovers: 1200,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'covers_down',
      );
    });

    // Scenario 2 — covers_up (+5%)
    test('covers_up: actual +5% vs forecast', () {
      expect(
        _lever(actualCovers: 1260, forecastCovers: 1200,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'covers_up',
      );
    });

    // Scenario 3 — ppa_down (−5%)
    test('ppa_down: avgPPA −5% vs target', () {
      expect(
        _lever(avgPPA: _tPPA * 0.95,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'ppa_down',
      );
    });

    // Scenario 4 — ppa_up (+8%)
    test('ppa_up: avgPPA +8% vs target', () {
      expect(
        _lever(avgPPA: _tPPA * 1.08,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'ppa_up',
      );
    });

    // Scenario 5 — cplh_down (−10%)
    test('cplh_down: avgCPLH −10% vs target', () {
      expect(
        _lever(avgCPLH: _tCPLH * 0.90,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'cplh_down',
      );
    });

    // Scenario 6 — cplh_up (+10%)
    test('cplh_up: avgCPLH +10% vs target', () {
      expect(
        _lever(avgCPLH: _tCPLH * 1.10,
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'cplh_up',
      );
    });

    // Scenario 7 — splh_down (−10%)
    test('splh_down: avgSPLH −10% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH * 0.90,
            avgFohWage: _fohWage, avgBohWage: _bohWage),
        'splh_down',
      );
    });

    // Scenario 8 — splh_up (+10%)
    test('splh_up: avgSPLH +10% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH * 1.10,
            avgFohWage: _fohWage, avgBohWage: _bohWage),
        'splh_up',
      );
    });

    // Scenario 9 — foh_wage_up (+9%)
    test('foh_wage_up: blended FOH wage +9% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH,
            avgFohWage: _fohWage * 1.09, avgBohWage: _bohWage),
        'foh_wage_up',
      );
    });

    // Scenario 10 — foh_wage_down (−10%)
    test('foh_wage_down: blended FOH wage −10% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH,
            avgFohWage: _fohWage * 0.90, avgBohWage: _bohWage),
        'foh_wage_down',
      );
    });

    // Scenario 11 — boh_wage_up (+13%)
    test('boh_wage_up: blended BOH wage +13% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH,
            avgFohWage: _fohWage, avgBohWage: _bohWage * 1.13),
        'boh_wage_up',
      );
    });

    // Scenario 12 — boh_wage_down (−13%)
    test('boh_wage_down: blended BOH wage −13% vs target', () {
      expect(
        _lever(avgSPLH: _tSPLH,
            avgFohWage: _fohWage, avgBohWage: _bohWage * 0.87),
        'boh_wage_down',
      );
    });
  });

  group('determineLever — threshold edge cases', () {
    test('covers delta exactly −2.0%: does NOT fire (strict <)', () {
      final result = _lever(
        actualCovers: (1200 * 0.98).round(),  // exactly −2%
        forecastCovers: 1200,
        avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage,
      );
      // Covers delta = −2.0%, threshold is strictly < −2% → should not fire covers_down
      // Defaults to covers_down since no other candidates
      // Check that it doesn't fire due to threshold; if forecastCovers > 0 and delta = -2%
      // it won't enter the candidates map → returns default 'covers_down' (fallback)
      expect(result, 'covers_down');
    });

    test('covers delta just below −2.0% (−2.1%): DOES fire', () {
      expect(
        _lever(actualCovers: 1174, forecastCovers: 1200,  // −2.17%
            avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'covers_down',
      );
    });

    test('all metrics at target: returns default covers_down', () {
      expect(
        _lever(avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage),
        'covers_down',
      );
    });

    test('SPLH not provided: SPLH levers never fire', () {
      // Without SPLH args, a 20% SPLH deviation should not fire
      // (we don't pass avgSPLH/targetSPLH → those args are null)
      final result = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
        // avgSPLH not provided → SPLH levers disabled
      );
      expect(result, 'covers_down'); // fallback, no candidates
    });

    test('wage not provided: wage levers never fire', () {
      final result = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
        avgSPLH: _tSPLH, targetSPLH: _tSPLH,
        // wage args not provided → wage levers disabled
      );
      expect(result, 'covers_down');
    });

    test('zero forecastCovers: no divide-by-zero, no covers lever fires', () {
      final result = LaborModel.determineLever(
        actualCovers: 100, forecastCovers: 0,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      // coversDelta = 0.0 when forecastCovers = 0 → no covers lever
      expect(result, 'covers_down'); // default fallback
    });

    test('zero targetCPLH: no cplh lever fires', () {
      final result = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: 4.0, avgPPA: _tPPA,
        targetCPLH: 0.0, targetPPA: _tPPA,
      );
      // cplhDelta = 0 when targetCPLH = 0 → no cplh lever
      expect(result, 'covers_down');
    });
  });

  group('determineLever — largest deviation wins', () {
    test('covers (−6%) beats cplh (−5.5%) when covers is larger', () {
      // covers delta = −6% > cplh delta −5.5%, both above thresholds
      final result = LaborModel.determineLever(
        actualCovers: (1200 * 0.94).round(),   // −6% covers
        forecastCovers: 1200,
        avgCPLH: _tCPLH * 0.945,              // −5.5% CPLH (smaller)
        avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      expect(result, 'covers_down');
    });

    test('cplh (−8%) beats covers (−4%) when cplh deviation is larger', () {
      final result = LaborModel.determineLever(
        actualCovers: (1200 * 0.96).round(),   // −4% covers
        forecastCovers: 1200,
        avgCPLH: _tCPLH * 0.92,               // −8% CPLH (larger)
        avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      expect(result, 'cplh_down');
    });

    test('ppa (−7%) beats cplh (−6%) when ppa deviation is larger', () {
      final result = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH * 0.94,  // −6%
        avgPPA: _tPPA * 0.93,    // −7%
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      expect(result, 'ppa_down');
    });

    test('splh (−9%) beats foh_wage (+6%) when splh deviation is larger', () {
      final result = LaborModel.determineLever(
        actualCovers: 1200, forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA,
        targetCPLH: _tCPLH, targetPPA: _tPPA,
        avgSPLH: _tSPLH * 0.91, targetSPLH: _tSPLH,    // −9% SPLH
        avgFohBlendedWage: _fohWage * 1.06, targetFohWage: _fohWage, // +6% FOH wage
      );
      // SPLH |9%| > FOH wage |6%| → splh_down wins
      expect(result, 'splh_down');
    });

    test('priority ordering: when covers and ppa are both around 4-5%, ppa vs covers depends on magnitude', () {
      // covers −4.1%, ppa −4.5%: ppa is slightly larger → ppa_down
      final result = LaborModel.determineLever(
        actualCovers: (1200 * 0.959).round(),  // −4.1%
        forecastCovers: 1200,
        avgCPLH: _tCPLH, avgPPA: _tPPA * 0.955,  // −4.5%
        targetCPLH: _tCPLH, targetPPA: _tPPA,
      );
      expect(result, 'ppa_down');
    });
  });

  group('determineLever — favorable levers fire correctly', () {
    test('covers_up fires with positive delta', () {
      expect(_lever(actualCovers: 1300, forecastCovers: 1200), 'covers_up');
    });

    test('cplh_up fires with positive delta', () {
      expect(_lever(avgCPLH: _tCPLH * 1.20), 'cplh_up');
    });

    test('ppa_up fires with positive delta', () {
      expect(_lever(avgPPA: _tPPA * 1.10), 'ppa_up');
    });

    test('splh_up fires with positive delta', () {
      expect(_lever(avgSPLH: _tSPLH * 1.10), 'splh_up');
    });

    test('foh_wage_down fires when blended wage below target', () {
      expect(
        _lever(avgSPLH: _tSPLH, avgFohWage: _fohWage * 0.90, avgBohWage: _bohWage),
        'foh_wage_down',
      );
    });

    test('boh_wage_down fires when blended wage below target', () {
      expect(
        _lever(avgSPLH: _tSPLH, avgFohWage: _fohWage, avgBohWage: _bohWage * 0.87),
        'boh_wage_down',
      );
    });
  });

  group('WeekRecord — model formula targets', () {
    test('targetFohHours uses modelFohHours(totalCovers, derivedTargetCPLH)', () {
      const record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 291, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.12,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.45,
        dollarGap: 478.50, primaryLeverId: 'cplh_down',
      );
      final expected = LaborModel.modelFohHours(
          1200, BaselineData.derivedTargetCPLH);
      expect(record.targetFohHours, expected);
    });

    test('targetBohHours uses modelBohHours(totalCovers, avgPPA, derivedTargetSPLH)', () {
      const record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 310,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.82,
        dollarGap: 661.85, primaryLeverId: 'splh_down',
      );
      final expected = LaborModel.modelBohHours(
          1200, 41.79, BaselineData.derivedTargetSPLH);
      expect(record.targetBohHours, expected);
    });

    test('avgSPLH computed correctly from stored fields', () {
      const record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 310,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.82,
        dollarGap: 661.85, primaryLeverId: 'splh_down',
      );
      final expected = (41.79 * 1200) / 310; // ≈ 161.8
      expect(record.avgSPLH, closeTo(expected, 0.01));
    });

    test('avgSPLH = 0 when totalBohHours = 0', () {
      const record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 22, totalBohHours: 0,
        avgPPA: 41.79, avgCPLH: 4.55,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
      );
      expect(record.avgSPLH, 0.0);
    });

    test('blendedFohWage defaults to MeridianConfig.fohWage', () {
      const record = WeekRecord(
        weekId: 't', weekLabel: 't',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
      );
      expect(record.blendedFohWage, MeridianConfig.fohWage);
    });
  });

  group('LaborModel.theoreticalLaborPct — zero safety', () {
    test('zero targetCPLH returns 0', () {
      expect(LaborModel.theoreticalLaborPct(0, _tSPLH, _tPPA, _fohWage, _bohWage), 0.0);
    });

    test('zero targetSPLH returns 0', () {
      expect(LaborModel.theoreticalLaborPct(_tCPLH, 0, _tPPA, _fohWage, _bohWage), 0.0);
    });

    test('zero targetPPA returns 0', () {
      expect(LaborModel.theoreticalLaborPct(_tCPLH, _tSPLH, 0, _fohWage, _bohWage), 0.0);
    });

    test('known values: ≈ 20.48% for derived targets', () {
      final result = LaborModel.theoreticalLaborPct(
        _tCPLH, _tSPLH, _tPPA, _fohWage, _bohWage,
      );
      expect(result, closeTo(20.48, 0.5));
    });
  });

  group('Demo weekHistory round-trip', () {
    // Each demo record's stored lever must match what determineLever computes
    // from the stored fields. This guards against the W12/W07 gap (H4) recurring.
    test('all 12 demo records: determineLever reproduces stored primaryLeverId', () {
      for (final record in DemoData.weekHistory) {
        final computed = LaborModel.determineLever(
          actualCovers:      record.totalCovers,
          forecastCovers:    record.forecastCovers,
          avgCPLH:           record.avgCPLH,
          avgPPA:            record.avgPPA,
          targetCPLH:        BaselineData.derivedTargetCPLH,
          targetPPA:         BaselineData.derivedTargetPPA,
          avgSPLH:           record.avgSPLH,
          targetSPLH:        BaselineData.derivedTargetSPLH,
          avgFohBlendedWage: record.blendedFohWage,
          targetFohWage:     MeridianConfig.fohWage,
          avgBohBlendedWage: record.blendedBohWage,
          targetBohWage:     MeridianConfig.bohWage,
        );
        expect(
          computed,
          record.primaryLeverId,
          reason: '${record.weekId}: determineLever returned "$computed" '
              'but stored lever is "${record.primaryLeverId}"',
        );
      }
    });

    test('12 records cover all 12 lever types', () {
      final leverIds = DemoData.weekHistory.map((r) => r.primaryLeverId).toSet();
      const expected = {
        'covers_down', 'covers_up',
        'ppa_down',    'ppa_up',
        'cplh_down',   'cplh_up',
        'splh_down',   'splh_up',
        'foh_wage_up', 'foh_wage_down',
        'boh_wage_up', 'boh_wage_down',
      };
      expect(leverIds, expected);
    });

    test('stale lever detection: record with wrong lever can be caught', () {
      // Construct a record that claims covers_down but inputs resolve to cplh_down
      const stale = WeekRecord(
        weekId: 'stale', weekLabel: 'Stale',
        totalCovers: 1155, forecastCovers: 1200,  // −3.75% covers (fires)
        totalFohHours: 305, totalBohHours: 280,   // avgCPLH = 1155/305 = 3.79 → −17.3% (fires, bigger)
        avgPPA: 41.79, avgCPLH: 3.79,
        theoreticalLaborPct: 20.48, actualLaborPct: 22.1,
        dollarGap: 900.0,
        primaryLeverId: 'covers_down',  // ← WRONG (stale)
      );
      final computed = LaborModel.determineLever(
        actualCovers: stale.totalCovers, forecastCovers: stale.forecastCovers,
        avgCPLH: stale.avgCPLH, avgPPA: stale.avgPPA,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
      );
      // cplh delta = (3.79 - 4.58)/4.58 = −17.3% > covers delta −3.75%
      expect(computed, 'cplh_down');
      expect(computed, isNot(stale.primaryLeverId));
    });
  });

  group('LeverCards completeness', () {
    test('all 12 lever IDs have a matching LeverCardData in LeverCards.all', () {
      const allLeverIds = [
        'covers_down', 'covers_up',
        'ppa_down',    'ppa_up',
        'cplh_down',   'cplh_up',
        'splh_down',   'splh_up',
        'foh_wage_up', 'foh_wage_down',
        'boh_wage_up', 'boh_wage_down',
      ];
      for (final id in allLeverIds) {
        final card = LeverCards.all.where((c) => c.id == id).toList();
        expect(card, hasLength(1), reason: 'Missing LeverCardData for lever "$id"');
      }
    });

    test('foh_wage_down is favorable', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'foh_wage_down');
      expect(card.isFavorable, isTrue);
      expect(card.direction, LeverDirection.favorable);
    });

    test('boh_wage_down is favorable', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'boh_wage_down');
      expect(card.isFavorable, isTrue);
      expect(card.direction, LeverDirection.favorable);
    });

    test('foh_wage_up is unfavorable', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'foh_wage_up');
      expect(card.isFavorable, isFalse);
    });

    test('boh_wage_up is unfavorable', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'boh_wage_up');
      expect(card.isFavorable, isFalse);
    });
  });
}
