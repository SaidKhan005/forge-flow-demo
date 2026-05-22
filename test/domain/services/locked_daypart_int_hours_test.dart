// Unit tests for lib/domain/services/locked_daypart_int_hours.dart.
//
// The service is pure Dart with no I/O, so no mocking infrastructure is
// needed.  Fixtures build minimal WeeklyPlanSnapshot instances inline.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/locked_daypart_int_hours.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';

// ── Shared fixture helpers ────────────────────────────────────────────────

const _testDate = '2026-05-19';
const _otherDate = '2026-05-20';

final _definitions = ServicePeriodDefinitionResolver.demoDefinitions;

/// Minimal snapshot with no fields the service cares about set to
/// non-defaults.  Callers override [dayRows] and [dayDayparts].
WeeklyPlanSnapshot _snapshot({
  List<WeeklyPlanSnapshotDay> dayRows = const [],
  List<WeeklyPlanSnapshotDayDaypart> dayDayparts = const [],
}) =>
    WeeklyPlanSnapshot(
      snapshotId: 'snap_test',
      restaurantId: 'rest_test',
      weekStartDate: '2026-05-18',
      weekEndDate: '2026-05-24',
      targetCycleId: 'cycle_test',
      forecastCovers: 0,
      forecastSales: 0.0,
      requiredFohHours: 0,
      requiredBohHours: 0,
      theoreticalFohLaborDollars: 0.0,
      theoreticalBohLaborDollars: 0.0,
      coversSource: ForecastDemandSource.demoFallback,
      salesSource: ForecastDemandSource.demoFallback,
      generatedAt: '2026-05-18T00:00:00Z',
      lockedAt: '2026-05-18T00:00:00Z',
      dayRows: dayRows,
      dayDayparts: dayDayparts,
    );

WeeklyPlanSnapshotDay _dayRow({
  required String businessDate,
  required int fohHours,
  required int bohHours,
}) =>
    WeeklyPlanSnapshotDay(
      day: 'Mon',
      businessDate: businessDate,
      forecastCovers: 100,
      forecastSales: 2000.0,
      requiredFohHours: fohHours,
      requiredBohHours: bohHours,
    );

WeeklyPlanSnapshotDayDaypart _dayDaypart({
  required String businessDate,
  required String servicePeriodId,
  required double fohHours,
  required double bohHours,
  int covers = 50,
  double sales = 1000.0,
}) =>
    WeeklyPlanSnapshotDayDaypart(
      businessDate: businessDate,
      servicePeriodId: servicePeriodId,
      forecastCovers: covers,
      forecastSales: sales,
      requiredFohHours: fohHours,
      requiredBohHours: bohHours,
      theoreticalFohDollars: 0.0,
      theoreticalBohDollars: 0.0,
    );

// ── reconcileLockedDaypartIntHours ───────────────────────────────────────

void main() {
  group('reconcileLockedDaypartIntHours', () {
    test('empty dayDayparts → returns []', () {
      final snap = _snapshot(
        dayRows: [_dayRow(businessDate: _testDate, fohHours: 10, bohHours: 5)],
        dayDayparts: [],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, isEmpty);
    });

    test('no dayDayparts for requested date → returns []', () {
      // dayDayparts exist but for a different date
      final snap = _snapshot(
        dayRows: [_dayRow(businessDate: _testDate, fohHours: 10, bohHours: 5)],
        dayDayparts: [
          _dayDaypart(
              businessDate: _otherDate,
              servicePeriodId: 'lunch',
              fohHours: 4.0,
              bohHours: 2.0),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, isEmpty);
    });

    test('no day row for date → returns []', () {
      // dayDayparts exist for _testDate but no matching day row
      final snap = _snapshot(
        dayRows: [],
        dayDayparts: [
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'lunch',
              fohHours: 4.0,
              bohHours: 2.0),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, isEmpty);
    });

    test('single period: requiredFohHours == dayRow.requiredFohHours', () {
      const dayFoh = 7;
      const dayBoh = 3;
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: dayFoh, bohHours: dayBoh)
        ],
        dayDayparts: [
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'dinner',
              fohHours: 7.0,
              bohHours: 3.0),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, hasLength(1));
      expect(result.single.requiredFohHours, dayFoh);
      expect(result.single.requiredBohHours, dayBoh);
    });

    test(
        'multiple periods: Σ(requiredFohHours) == dayRow.requiredFohHours '
        'and Σ(requiredBohHours) == dayRow.requiredBohHours', () {
      const dayFoh = 10;
      const dayBoh = 6;
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: dayFoh, bohHours: dayBoh)
        ],
        dayDayparts: [
          // lunch ~40% of day FOH, dinner ~60%
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'lunch',
              fohHours: 4.0,
              bohHours: 2.5),
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'dinner',
              fohHours: 6.0,
              bohHours: 3.5),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, hasLength(2));

      final sumFoh = result.fold(0, (s, r) => s + r.requiredFohHours);
      final sumBoh = result.fold(0, (s, r) => s + r.requiredBohHours);
      expect(sumFoh, dayFoh,
          reason: 'Per-period FOH integers must sum to locked day FOH total');
      expect(sumBoh, dayBoh,
          reason: 'Per-period BOH integers must sum to locked day BOH total');
    });

    test(
        'three periods with uneven split: sums exactly match day-level totals',
        () {
      const dayFoh = 17;
      const dayBoh = 9;
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: dayFoh, bohHours: dayBoh)
        ],
        dayDayparts: [
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'lunch',
              fohHours: 4.5,
              bohHours: 2.3),
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'dinner',
              fohHours: 8.1,
              bohHours: 4.2),
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'late_night',
              fohHours: 4.4,
              bohHours: 2.5),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result, hasLength(3));

      final sumFoh = result.fold(0, (s, r) => s + r.requiredFohHours);
      final sumBoh = result.fold(0, (s, r) => s + r.requiredBohHours);
      expect(sumFoh, dayFoh);
      expect(sumBoh, dayBoh);
    });

    test('result rows carry correct servicePeriodId and label', () {
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: 8, bohHours: 4)
        ],
        dayDayparts: [
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'lunch',
              fohHours: 3.0,
              bohHours: 1.5),
          _dayDaypart(
              businessDate: _testDate,
              servicePeriodId: 'dinner',
              fohHours: 5.0,
              bohHours: 2.5),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      // Ordered by sortOrder: lunch (1) before dinner (2)
      expect(result[0].servicePeriodId, 'lunch');
      expect(result[0].label, 'Lunch');
      expect(result[1].servicePeriodId, 'dinner');
      expect(result[1].label, 'Dinner');
    });

    test('forecastCovers and forecastSales pass through unchanged', () {
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: 5, bohHours: 3)
        ],
        dayDayparts: [
          _dayDaypart(
            businessDate: _testDate,
            servicePeriodId: 'dinner',
            fohHours: 5.0,
            bohHours: 3.0,
            covers: 80,
            sales: 1600.0,
          ),
        ],
      );
      final result = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      expect(result.single.forecastCovers, 80);
      expect(result.single.forecastSales, 1600.0);
    });
  });

  // ── reconciledLockedDaypartFor ───────────────────────────────────────────

  group('reconciledLockedDaypartFor', () {
    WeeklyPlanSnapshot twoPeriodsSnap() => _snapshot(
          dayRows: [
            _dayRow(businessDate: _testDate, fohHours: 10, bohHours: 5)
          ],
          dayDayparts: [
            _dayDaypart(
                businessDate: _testDate,
                servicePeriodId: 'lunch',
                fohHours: 4.0,
                bohHours: 2.0),
            _dayDaypart(
                businessDate: _testDate,
                servicePeriodId: 'dinner',
                fohHours: 6.0,
                bohHours: 3.0),
          ],
        );

    test('returns the correct period row by servicePeriodId', () {
      final snap = twoPeriodsSnap();
      final lunch = reconciledLockedDaypartFor(
        snapshot: snap,
        businessDate: _testDate,
        servicePeriodId: 'lunch',
        definitions: _definitions,
      );
      expect(lunch, isNotNull);
      expect(lunch!.servicePeriodId, 'lunch');
    });

    test('returns null for an unknown servicePeriodId', () {
      final snap = twoPeriodsSnap();
      final unknown = reconciledLockedDaypartFor(
        snapshot: snap,
        businessDate: _testDate,
        servicePeriodId: 'brunch',
        definitions: _definitions,
      );
      expect(unknown, isNull);
    });

    test('returns null when no sub-rows exist for the date', () {
      final snap = _snapshot(
        dayRows: [
          _dayRow(businessDate: _testDate, fohHours: 10, bohHours: 5)
        ],
        dayDayparts: [],
      );
      final result = reconciledLockedDaypartFor(
        snapshot: snap,
        businessDate: _testDate,
        servicePeriodId: 'dinner',
        definitions: _definitions,
      );
      expect(result, isNull);
    });

    test(
        'dinner row: Σ parity — integer returned matches what '
        'reconcileLockedDaypartIntHours emits for the same (date, period)',
        () {
      final snap = twoPeriodsSnap();
      final allRows = reconcileLockedDaypartIntHours(
        snapshot: snap,
        businessDate: _testDate,
        definitions: _definitions,
      );
      final dinnerFromAll =
          allRows.firstWhere((r) => r.servicePeriodId == 'dinner');

      final dinnerDirect = reconciledLockedDaypartFor(
        snapshot: snap,
        businessDate: _testDate,
        servicePeriodId: 'dinner',
        definitions: _definitions,
      );
      expect(dinnerDirect, isNotNull);
      expect(dinnerDirect!.requiredFohHours, dinnerFromAll.requiredFohHours);
      expect(dinnerDirect.requiredBohHours, dinnerFromAll.requiredBohHours);
    });
  });
}
