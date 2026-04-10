import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// â”€â”€ Shared fixtures â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

// A realistic Monday-lunch closed shift.
final _baseDate = DateTime(2026, 3, 23);

const _snapshot = TargetSnapshot(
  targetCPLH: 4.58,
  targetSPLH: 180.07,
  targetPPA: 41.79,
  fohWage: 16.50,
  bohWage: 21.35,
  opzFloorCPLH: 3.5,
  opzCeilingCPLH: 5.8,
  theoreticalFohLaborPct: 8.63,
  theoreticalBohLaborPct: 11.86,
  theoreticalLaborPct: 20.49,
);

ClosedShiftInput _input({
  int covers = 154,
  int forecastCovers = 170,
  double actualSales = 6344.80,   // 154 Ã— 41.20
  int actualFohHours = 36,
  int actualBohHours = 37,
  int? scheduledFohHours,
  int? scheduledBohHours,
  double? actualFohLaborDollars,
  double? actualBohLaborDollars,
}) {
  return ClosedShiftInput(
    businessDate: _baseDate,
    weekId: '2026-W13',
    dayLabel: 'Mon',
    daypart: 'lunch',
    covers: covers,
    forecastCovers: forecastCovers,
    actualSales: actualSales,
    actualFohHours: actualFohHours,
    actualBohHours: actualBohHours,
    scheduledFohHours: scheduledFohHours,
    scheduledBohHours: scheduledBohHours,
    actualFohLaborDollars: actualFohLaborDollars,
    actualBohLaborDollars: actualBohLaborDollars,
    sourceSystem: 'test',
    sourceShiftId: 'test-001',
  );
}

// â”€â”€ Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

void main() {
  group('ShiftFactBuilder â€” rate metrics derived from raw source facts', () {
    test('ppa = actualSales / covers', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.ppa, closeTo(6344.80 / 154, 0.0001));
    });

    test('cplh = covers / actualFohHours', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.cplh, closeTo(154 / 36, 0.0001));
    });

    test('splh = actualSales / actualBohHours', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.splh, closeTo(6344.80 / 37, 0.0001));
    });
  });

  group('ShiftFactBuilder â€” labor dollar resolution', () {
    test('falls back to hours Ã— wage when actual labor dollars absent', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.actualFohLaborDollars, closeTo(36 * 16.50, 0.0001));
      expect(fact.actualBohLaborDollars, closeTo(37 * 21.35, 0.0001));
    });

    test('uses provided actual FOH labor dollars when present', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualFohLaborDollars: 620.00),
        _snapshot,
      );
      expect(fact.actualFohLaborDollars, 620.00);
    });

    test('uses provided actual BOH labor dollars when present', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualBohLaborDollars: 810.00),
        _snapshot,
      );
      expect(fact.actualBohLaborDollars, 810.00);
    });

    test('uses both provided labor dollar values independently', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualFohLaborDollars: 595.00, actualBohLaborDollars: 795.00),
        _snapshot,
      );
      expect(fact.actualFohLaborDollars, 595.00);
      expect(fact.actualBohLaborDollars, 795.00);
      expect(fact.totalLaborDollars, closeTo(595.00 + 795.00, 0.0001));
    });
  });

  group('ShiftFactBuilder â€” schedule variance hours', () {
    test('fohScheduledVarianceHours = actual âˆ’ scheduled when scheduled provided', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualFohHours: 36, scheduledFohHours: 34),
        _snapshot,
      );
      expect(fact.fohScheduledVarianceHours, 2);
    });

    test('bohScheduledVarianceHours = actual âˆ’ scheduled when scheduled provided', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualBohHours: 37, scheduledBohHours: 38),
        _snapshot,
      );
      expect(fact.bohScheduledVarianceHours, -1);
    });

    test('fohScheduledVarianceHours is null when scheduledFohHours absent', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.fohScheduledVarianceHours, isNull);
    });

    test('bohScheduledVarianceHours is null when scheduledBohHours absent', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.bohScheduledVarianceHours, isNull);
    });
  });

  group('ShiftFactBuilder â€” primaryLeverId populated from LaborModel', () {
    test('primaryLeverId is non-empty string', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.primaryLeverId, isNotEmpty);
    });

    test('covers_down fires when actual covers significantly below forecast', () {
      // 154 covers vs 200 forecast = âˆ’23% â†’ covers_down
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(covers: 154, forecastCovers: 200),
        _snapshot,
      );
      expect(fact.primaryLeverId, 'covers_down');
    });

    test('covers_up fires when actual covers significantly above forecast', () {
      // 230 covers vs 170 forecast = +35% covers_up.
      // BOH hours scaled so SPLH stays near target (230 Ã— 41.79 / 180.07 â‰ˆ 53).
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(
          covers: 230,
          forecastCovers: 170,
          actualSales: 230 * 41.79,
          actualFohHours: 50,  // CPLH = 230/50 = 4.6 â‰ˆ target (within 5%)
          actualBohHours: 53,  // SPLH = 9613.7/53 â‰ˆ 181.4 â‰ˆ target (within 5%)
        ),
        _snapshot,
      );
      expect(fact.primaryLeverId, 'covers_up');
    });
  });

  // ── Actual-sales BOH model-hour guardrail (Phase 7.55d.3a) ─────────────────

  group('ShiftFactBuilder — BOH model hours use actual sales, not target PPA', () {
    test('boh_hours_over fires when model BOH uses actual sales but not target PPA', () {
      // Scenario: high volume to amplify the PPA gap into different model BOH.
      //   actual covers = 1000, actual sales = 40000 → actual PPA = 40
      //   target PPA = 41 (delta = −2.4%, below 3% threshold → no PPA lever)
      //   target SPLH = 100
      //
      //   Actual-sales model BOH = 40000 / 100 = 400
      //   Target-PPA model BOH   = 1000 × 41 / 100 = 410
      //
      //   scheduled BOH = 445
      //   vs actual-sales model (400): (445−400)/400 = 11.25% > 10% → boh_hours_over
      //   vs target-PPA model  (410): (445−410)/410 = 8.5%  < 10% → would NOT fire
      //
      //   All other levers kept neutral:
      //   - covers: 1000 vs 1000 forecast → 0%
      //   - CPLH: 1000/250 = 4.0 vs 4.0 target → 0%
      //   - SPLH: 40000/400 = 100 vs 100 target → 0%
      //   - wages: fallback = target wage → 0%
      //   - FOH hours: 250 scheduled vs 250 model → 0%
      const snapshot = TargetSnapshot(
        targetCPLH: 4.0,
        targetSPLH: 100.0,
        targetPPA: 41.0,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.0,
        opzCeilingCPLH: 5.5,
        theoreticalFohLaborPct: 10.0,
        theoreticalBohLaborPct: 10.0,
        theoreticalLaborPct: 20.0,
      );

      final input = ClosedShiftInput(
        businessDate: DateTime(2026, 3, 23),
        weekId: '2026-W13',
        dayLabel: 'Mon',
        daypart: 'lunch',
        covers: 1000,
        forecastCovers: 1000,
        actualSales: 40000.0,      // actual PPA = 40
        actualFohHours: 250,       // CPLH = 1000/250 = 4.0 = target
        actualBohHours: 400,       // SPLH = 40000/400 = 100 = target
        scheduledFohHours: 250,    // exact match to model FOH (1000/4.0=250)
        scheduledBohHours: 445,    // over model BOH
        sourceSystem: 'test',
        sourceShiftId: 'guardrail-test-001',
      );

      final fact = ShiftFactBuilder.fromClosedShiftInput(input, snapshot);

      // The actual-sales model BOH = 40000 / 100 = 400
      final expectedModelBoh = LaborModel.modelBohHoursFromSales(40000.0, 100.0);
      expect(expectedModelBoh, 400);

      // The target-PPA model BOH would be 1000 × 41 / 100 = 410
      final targetPpaModelBoh = LaborModel.modelBohHours(1000, 41.0, 100.0);
      expect(targetPpaModelBoh, 410);

      // With actual-sales model (400), scheduled 445 is 11.25% over → fires
      // With target-PPA model (410), scheduled 445 is 8.5% over → would NOT fire
      expect(fact.primaryLeverId, 'boh_hours_over');
    });

    test('model BOH hours on ShiftFact getter uses actual PPA, not target PPA', () {
      // Verify the ShiftFact.modelBohHours getter also uses actual PPA
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(covers: 100, actualSales: 4000.0, actualBohHours: 40),
        _snapshot,
      );
      // ShiftFact.modelBohHours = LaborModel.modelBohHours(covers, ppa, targetSPLH)
      //   where ppa = actualSales/covers = 40.0
      final expected = LaborModel.modelBohHoursFromSales(4000.0, _snapshot.targetSPLH);
      expect(fact.modelBohHours, expected);
    });
  });

  group('LaborModel.isFavorableLever', () {
    test('ppa_up is favorable', () {
      expect(LaborModel.isFavorableLever('ppa_up'), isTrue);
    });

    test('ppa_down is not favorable', () {
      expect(LaborModel.isFavorableLever('ppa_down'), isFalse);
    });

    test('covers_up is favorable', () {
      expect(LaborModel.isFavorableLever('covers_up'), isTrue);
    });

    test('covers_down is not favorable', () {
      expect(LaborModel.isFavorableLever('covers_down'), isFalse);
    });

    test('cplh_up is favorable', () {
      expect(LaborModel.isFavorableLever('cplh_up'), isTrue);
    });

    test('splh_up is favorable', () {
      expect(LaborModel.isFavorableLever('splh_up'), isTrue);
    });

    test('foh_wage_down is favorable', () {
      expect(LaborModel.isFavorableLever('foh_wage_down'), isTrue);
    });

    test('boh_wage_down is favorable', () {
      expect(LaborModel.isFavorableLever('boh_wage_down'), isTrue);
    });

    test('foh_wage_up is not favorable', () {
      expect(LaborModel.isFavorableLever('foh_wage_up'), isFalse);
    });

    test('boh_wage_up is not favorable', () {
      expect(LaborModel.isFavorableLever('boh_wage_up'), isFalse);
    });

    test('unknown lever id is not favorable', () {
      expect(LaborModel.isFavorableLever('on_model'), isFalse);
    });
  });
}
