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
      expect(
        profile.daypartFor('lunch'),
        isNull,
        reason:
            'Gap 42 fallback — caller must handle null and fall '
            'back to the whole-day pool; never substitute 0 (Design Rule 2)',
      );
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
      expect(
        profile.daypartFor('dinner'),
        isNull,
        reason: 'unknown period id resolves to null, not the parent pool',
      );
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
      expect(
        base.dayparts,
        isEmpty,
        reason: 'withDayparts is immutable — original profile unchanged',
      );
      expect(withRows.dayparts.length, 1);
      expect(withRows.daypartFor('dinner')?.daypartTargetCPLH, 5.0);
    });

    test('toMap does NOT serialize per-period rows (parent is flat shape)', () {
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
      expect(
        map.containsKey('dayparts'),
        isFalse,
        reason:
            'parent profile serialization is flat-shape; per-period '
            'rows live in a child table when persisted',
      );
    });

    test('toMap keeps active cycle identity for exact daypart hydration', () {
      const profile = ActiveTargetProfile(
        targetProfileId: 'profile-1',
        restaurantId: 'r1',
        targetCycleId: 'cycle-locked',
        targetProfileVersionId: 'version-locked',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 40.0,
        fohWage: 16.5,
        bohWage: 21.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.0,
        theoreticalFohLaborPct: 9.0,
        theoreticalBohLaborPct: 11.0,
        theoreticalLaborPct: 20.0,
        builtAt: '2026-05-19T00:00:00Z',
      );

      final restored = ActiveTargetProfile.fromMap(profile.toMap());

      expect(restored.targetCycleId, 'cycle-locked');
      expect(restored.targetProfileVersionId, 'version-locked');
    });
  });

  // Per-Daypart V1 (Slice 5 — Gap 7): the per-period theoretical-%
  // accessor that the Variance read seam swaps onto. Locks: null when
  // no per-period row (Gap 42 fallback — Design Rule 2), per-period
  // rates + whole-day wages (Design Rule 5), and the legacy
  // divide-by-zero boundary parity with the whole-day scalar.
  group('ActiveTargetProfile.daypartTheoreticalLaborPctFor', () {
    test('returns null when no per-period row exists (Gap 42 fallback)', () {
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
      expect(
        profile.daypartTheoreticalLaborPctFor('lunch'),
        isNull,
        reason:
            'no per-period row → null so the caller falls back to '
            'the whole-day pool; never a 0 sentinel (Design Rule 2)',
      );
    });

    test('derives per-period % from period rates + whole-day wages '
        '(matches build() formula)', () {
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
      // Same canonical formula as build(), but with the lunch period's
      // rate targets and the profile's whole-day wages (Design Rule 5).
      final expectedFohPct = 16.5 / (4.0 * 35.0) * 100;
      final expectedBohPct = 21.0 / 150.0 * 100;
      expect(
        profile.daypartTheoreticalLaborPctFor('lunch'),
        closeTo(expectedFohPct + expectedBohPct, 1e-9),
      );
      // Period-scoped value differs from the whole-day pool scalar —
      // proves the seam is genuinely per-period, not the pool in
      // disguise.
      expect(
        profile.daypartTheoreticalLaborPctFor('lunch'),
        isNot(closeTo(profile.theoreticalLaborPct, 1e-6)),
      );
      // Unknown period id resolves to null (Gap 42 fallback contract).
      expect(profile.daypartTheoreticalLaborPctFor('dinner'), isNull);
    });

    test(
      'degenerate period row keeps the legacy 0.0 divide-by-zero boundary',
      () {
        const degenerate = ActiveTargetProfileDaypart(
          servicePeriodId: 'late_night',
          daypartTargetCPLH: 0.0,
          daypartTargetSPLH: 0.0,
          daypartTargetPPA: 0.0,
          daypartOpzFloorCPLH: 0.0,
          daypartOpzCeilingCPLH: 0.0,
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
          dayparts: [degenerate],
        );
        // A present-but-degenerate row is NOT the Gap 42 "no row" case —
        // it returns the same 0.0 boundary the whole-day build() scalar
        // produces for non-positive rates (parity, not a new sentinel).
        expect(profile.daypartTheoreticalLaborPctFor('late_night'), 0.0);
      },
    );
  });
}
