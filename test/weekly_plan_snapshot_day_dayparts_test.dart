// Per-Daypart Targets V1 (Slice 1) — WeeklyPlanSnapshotService
// per-(day, period) lock-time computation tests.
//
// Locks the math for converting a TargetCycle's per-period rows + a
// weekly plan's day rows into WeeklyPlanSnapshotDayDaypart entries.
// Design Rule 5 — wages stay whole-day; per-period theoretical dollars
// use whole-day wages × per-period required hours.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';

void main() {
  group('WeeklyPlanSnapshotService.debugBuildDayDaypartRows', () {
    test(
      'allocates day forecast covers across periods using cycle '
      'coverCount as proportion source',
      () {
        final cycle = TargetCycle(
          cycleId: 'c1',
          restaurantId: 'r1',
          source: TargetCycleSource.recommended,
          effectiveStart: '2026-04-13',
          effectiveEnd: '2026-06-11',
          calibrationWindowStart: '2026-02-13',
          calibrationWindowEnd: '2026-04-13',
          targetCPLH: 4.75,
          targetSPLH: 187.5,
          targetPPA: 42.5,
          fohWage: 16.5,
          bohWage: 21.0,
          opzFloorCPLH: 3.5,
          opzCeilingCPLH: 5.5,
          createdAt: '2026-04-13T00:00:00Z',
          dayparts: const [
            TargetCycleDaypart(
              servicePeriodId: 'lunch',
              targetCPLH: 4.0,
              targetSPLH: 150.0,
              targetPPA: 35.0,
              opzFloorCPLH: 3.5,
              opzCeilingCPLH: 4.5,
              // 25% of the calibration window cover mass.
              coverCount: 100,
            ),
            TargetCycleDaypart(
              servicePeriodId: 'dinner',
              targetCPLH: 5.0,
              targetSPLH: 200.0,
              targetPPA: 45.0,
              opzFloorCPLH: 4.5,
              opzCeilingCPLH: 5.5,
              // 75% of the calibration window cover mass.
              coverCount: 300,
            ),
          ],
        );

        const monRow = WeeklyPlanSnapshotDay(
          day: 'Mon',
          businessDate: '2026-04-13',
          forecastCovers: 400,
          forecastSales: 17000.0,
          requiredFohHours: 84,
          requiredBohHours: 91,
        );

        final rows = WeeklyPlanSnapshotService.debugBuildDayDaypartRows(
          cycle: cycle,
          dayRows: const [monRow],
        );

        expect(rows.length, 2,
            reason: 'one row per (Mon, period) — the cycle has 2 periods');

        final lunch =
            rows.firstWhere((r) => r.servicePeriodId == 'lunch');
        final dinner =
            rows.firstWhere((r) => r.servicePeriodId == 'dinner');

        // Cover allocation: 400 covers split 100:300 → 100 lunch, 300 dinner.
        expect(lunch.forecastCovers, 100);
        expect(dinner.forecastCovers, 300);

        // Sales = period covers × period target PPA.
        // lunch:   100 × 35.0  = 3500
        // dinner:  300 × 45.0  = 13500
        expect(lunch.forecastSales, closeTo(3500.0, 0.001));
        expect(dinner.forecastSales, closeTo(13500.0, 0.001));

        // Required FOH hours = period covers / period target CPLH.
        expect(lunch.requiredFohHours, closeTo(100 / 4.0, 0.001));
        expect(dinner.requiredFohHours, closeTo(300 / 5.0, 0.001));

        // Required BOH hours = period sales / period target SPLH.
        expect(lunch.requiredBohHours, closeTo(3500 / 150.0, 0.001));
        expect(dinner.requiredBohHours, closeTo(13500 / 200.0, 0.001));

        // Theoretical dollars = required hours × whole-day wage.
        expect(lunch.theoreticalFohDollars,
            closeTo(lunch.requiredFohHours * 16.5, 0.001));
        expect(lunch.theoreticalBohDollars,
            closeTo(lunch.requiredBohHours * 21.0, 0.001));
        expect(dinner.theoreticalFohDollars,
            closeTo(dinner.requiredFohHours * 16.5, 0.001));
        expect(dinner.theoreticalBohDollars,
            closeTo(dinner.requiredBohHours * 21.0, 0.001));
      },
    );

    test(
      'Gap 42 fallback: cycle with empty dayparts returns empty list '
      '(read consumers fall back to whole-day day_rows)',
      () {
        final cycle = TargetCycle(
          cycleId: 'c1',
          restaurantId: 'r1',
          source: TargetCycleSource.recommended,
          effectiveStart: '2026-04-13',
          effectiveEnd: '2026-06-11',
          calibrationWindowStart: '2026-02-13',
          calibrationWindowEnd: '2026-04-13',
          targetCPLH: 4.58,
          targetSPLH: 180.0,
          targetPPA: 41.5,
          fohWage: 16.5,
          bohWage: 21.0,
          opzFloorCPLH: 4.0,
          opzCeilingCPLH: 5.5,
          createdAt: '2026-04-13T00:00:00Z',
          // Empty dayparts list — Gap 42 fallback.
        );

        const monRow = WeeklyPlanSnapshotDay(
          day: 'Mon',
          businessDate: '2026-04-13',
          forecastCovers: 400,
          forecastSales: 17000.0,
          requiredFohHours: 84,
          requiredBohHours: 91,
        );

        final rows = WeeklyPlanSnapshotService.debugBuildDayDaypartRows(
          cycle: cycle,
          dayRows: const [monRow],
        );

        expect(rows, isEmpty,
            reason: 'no per-period rows when the cycle has none '
                '— read consumers must fall back to whole-day day rows '
                '(never silently synthesize per-period rows)');
      },
    );
  });

  group('WeeklyPlanSnapshotWagesAtLockTime', () {
    test('round-trips through JSON', () {
      const stamp = WeeklyPlanSnapshotWagesAtLockTime(
        fohWage: 16.5,
        bohWage: 21.0,
        blendedWage: 18.25,
      );
      final round = WeeklyPlanSnapshotWagesAtLockTime.fromJson(stamp.toJson());
      expect(round.fohWage, 16.5);
      expect(round.bohWage, 21.0);
      expect(round.blendedWage, 18.25);
    });
  });
}
