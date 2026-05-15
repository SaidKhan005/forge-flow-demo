// Per-Daypart Targets V1 (Slice 1) — pool rollup invariant tests.
//
// Locks the cover-weighted pool math inside `TargetCycleDaypartPool.fromDayparts`.
// The cycle write path uses this helper to derive the parent
// `target_cycles` whole-day scalars FROM the per-period rows (Design
// Rule 4 — pool is computed inside the write path; nothing else is
// allowed to mutate it directly).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';

void main() {
  group('TargetCycleDaypartPool.fromDayparts', () {
    test('cover-weighted pool sums to weighted mean across periods', () {
      final dayparts = <TargetCycleDaypart>[
        const TargetCycleDaypart(
          servicePeriodId: 'lunch',
          targetCPLH: 4.0,
          targetSPLH: 150.0,
          targetPPA: 35.0,
          opzFloorCPLH: 3.5,
          opzCeilingCPLH: 4.5,
          coverCount: 100,
        ),
        const TargetCycleDaypart(
          servicePeriodId: 'dinner',
          targetCPLH: 5.0,
          targetSPLH: 200.0,
          targetPPA: 45.0,
          opzFloorCPLH: 4.5,
          opzCeilingCPLH: 5.5,
          coverCount: 300,
        ),
      ];

      final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

      // (4.0 * 100 + 5.0 * 300) / 400 = 4.75
      expect(pool.targetCPLH, closeTo(4.75, 0.001));
      // (150 * 100 + 200 * 300) / 400 = 187.5
      expect(pool.targetSPLH, closeTo(187.5, 0.001));
      // (35 * 100 + 45 * 300) / 400 = 42.5
      expect(pool.targetPPA, closeTo(42.5, 0.001));
      // OPZ floor = min across periods; ceiling = max across periods.
      expect(pool.opzFloorCPLH, 3.5);
      expect(pool.opzCeilingCPLH, 5.5);
    });

    test('zero-cover periods fall back to unweighted mean (no divide-by-zero)',
        () {
      final dayparts = <TargetCycleDaypart>[
        const TargetCycleDaypart(
          servicePeriodId: 'lunch',
          targetCPLH: 4.0,
          targetSPLH: 150.0,
          targetPPA: 35.0,
          opzFloorCPLH: 3.5,
          opzCeilingCPLH: 4.5,
          coverCount: 0,
        ),
        const TargetCycleDaypart(
          servicePeriodId: 'dinner',
          targetCPLH: 6.0,
          targetSPLH: 250.0,
          targetPPA: 45.0,
          opzFloorCPLH: 5.5,
          opzCeilingCPLH: 6.5,
          coverCount: 0,
        ),
      ];

      final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

      // Unweighted mean: (4 + 6) / 2 = 5
      expect(pool.targetCPLH, closeTo(5.0, 0.001));
      expect(pool.targetSPLH, closeTo(200.0, 0.001));
      expect(pool.targetPPA, closeTo(40.0, 0.001));
    });

    test('empty list throws ArgumentError (Gap 42 path bypasses this helper)',
        () {
      expect(
        () => TargetCycleDaypartPool.fromDayparts(<TargetCycleDaypart>[]),
        throwsArgumentError,
      );
    });

    test('single-period pool equals the period itself', () {
      const single = TargetCycleDaypart(
        servicePeriodId: 'dinner',
        targetCPLH: 5.0,
        targetSPLH: 200.0,
        targetPPA: 45.0,
        opzFloorCPLH: 4.5,
        opzCeilingCPLH: 5.5,
        coverCount: 100,
      );
      final pool = TargetCycleDaypartPool.fromDayparts([single]);
      expect(pool.targetCPLH, 5.0);
      expect(pool.targetSPLH, 200.0);
      expect(pool.targetPPA, 45.0);
      expect(pool.opzFloorCPLH, 4.5);
      expect(pool.opzCeilingCPLH, 5.5);
    });
  });
}
