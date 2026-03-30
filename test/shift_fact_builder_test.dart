import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/domain/models/closed_shift_input.dart';
import 'package:forge_flow_demo/domain/models/target_snapshot.dart';
import 'package:forge_flow_demo/domain/services/shift_fact_builder.dart';
import 'package:forge_flow_demo/services/labor_model.dart';

// ── Shared fixtures ────────────────────────────────────────────────────────

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
  double actualSales = 6344.80,   // 154 × 41.20
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

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('ShiftFactBuilder — rate metrics derived from raw source facts', () {
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

  group('ShiftFactBuilder — labor dollar resolution', () {
    test('falls back to hours × wage when actual labor dollars absent', () {
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

  group('ShiftFactBuilder — schedule variance hours', () {
    test('fohScheduledVarianceHours = actual − scheduled when scheduled provided', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(actualFohHours: 36, scheduledFohHours: 34),
        _snapshot,
      );
      expect(fact.fohScheduledVarianceHours, 2);
    });

    test('bohScheduledVarianceHours = actual − scheduled when scheduled provided', () {
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

  group('ShiftFactBuilder — primaryLeverId populated from LaborModel', () {
    test('primaryLeverId is non-empty string', () {
      final fact = ShiftFactBuilder.fromClosedShiftInput(_input(), _snapshot);
      expect(fact.primaryLeverId, isNotEmpty);
    });

    test('covers_down fires when actual covers significantly below forecast', () {
      // 154 covers vs 200 forecast = −23% → covers_down
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(covers: 154, forecastCovers: 200),
        _snapshot,
      );
      expect(fact.primaryLeverId, 'covers_down');
    });

    test('covers_up fires when actual covers significantly above forecast', () {
      // 230 covers vs 170 forecast = +35% covers_up.
      // BOH hours scaled so SPLH stays near target (230 × 41.79 / 180.07 ≈ 53).
      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _input(
          covers: 230,
          forecastCovers: 170,
          actualSales: 230 * 41.79,
          actualFohHours: 50,  // CPLH = 230/50 = 4.6 ≈ target (within 5%)
          actualBohHours: 53,  // SPLH = 9613.7/53 ≈ 181.4 ≈ target (within 5%)
        ),
        _snapshot,
      );
      expect(fact.primaryLeverId, 'covers_up');
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
