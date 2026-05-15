// Per-Daypart Targets V1 (Slice 1) — ActiveTargetProfile per-period
// accessor tests. Locks the `daypartFor` contract (Design Rule 2: null
// for absent — never `0` sentinel) and the `withDayparts` immutable
// update path.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';

void main() {
  group('ActiveTargetProfile per-period accessors', () {
    test('daypartFor returns null when no per-period rows present', () {
      final profile = ActiveTargetProfile.build(
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 40.0,
        fohWage: 16.5,
        bohWage: 21.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.0,
      );
      expect(profile.dayparts, isEmpty);
      expect(profile.daypartFor('lunch'), isNull,
          reason: 'Gap 42 fallback — caller must handle null and fall '
              'back to the whole-day pool; never substitute 0 (Design Rule 2)');
    });

    test('daypartFor returns matching per-period row when present', () {
      const lunch = ActiveTargetProfileDaypart(
        servicePeriodId: 'lunch',
        daypartTargetCPLH: 4.0,
        daypartTargetSPLH: 150.0,
        daypartTargetPPA: 35.0,
        daypartOpzFloorCPLH: 3.5,
        daypartOpzCeilingCPLH: 4.5,
      );
      final profile = ActiveTargetProfile.build(
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 40.0,
        fohWage: 16.5,
        bohWage: 21.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.0,
        dayparts: [lunch],
      );
      final row = profile.daypartFor('lunch');
      expect(row, isNotNull);
      expect(row!.daypartTargetCPLH, 4.0);
      expect(profile.daypartFor('dinner'), isNull,
          reason: 'unknown period id resolves to null, not the parent pool');
    });

    test('withDayparts produces a new profile with the replacement rows', () {
      final base = ActiveTargetProfile.build(
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 40.0,
        fohWage: 16.5,
        bohWage: 21.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.0,
      );
      final withRows = base.withDayparts(const [
        ActiveTargetProfileDaypart(
          servicePeriodId: 'dinner',
          daypartTargetCPLH: 5.0,
          daypartTargetSPLH: 200.0,
          daypartTargetPPA: 45.0,
          daypartOpzFloorCPLH: 4.5,
          daypartOpzCeilingCPLH: 5.5,
        ),
      ]);
      expect(base.dayparts, isEmpty,
          reason: 'withDayparts is immutable — original profile unchanged');
      expect(withRows.dayparts.length, 1);
      expect(withRows.daypartFor('dinner')?.daypartTargetCPLH, 5.0);
    });

    test('toMap does NOT serialize per-period rows (parent is flat shape)',
        () {
      final profile = ActiveTargetProfile.build(
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 40.0,
        fohWage: 16.5,
        bohWage: 21.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.0,
        dayparts: const [
          ActiveTargetProfileDaypart(
            servicePeriodId: 'lunch',
            daypartTargetCPLH: 4.0,
            daypartTargetSPLH: 150.0,
            daypartTargetPPA: 35.0,
            daypartOpzFloorCPLH: 3.5,
            daypartOpzCeilingCPLH: 4.5,
          ),
        ],
      );
      final map = profile.toMap();
      // Per-period rows live alongside on `active_target_profile_dayparts`
      // (when the repository writes that table). The parent row's
      // serialized shape stays flat for SQLite back-compat.
      expect(map.containsKey('dayparts'), isFalse,
          reason: 'parent profile serialization is flat-shape; per-period '
              'rows live in a child table when persisted');
    });
  });
}
