import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/models/shift_record.dart';

const TargetSnapshot _target = TargetSnapshot(
  restaurantId: 'rest-1',
  targetProfileId: 'target-profile-1',
  targetProfileVersionId: 'target-profile-version-1',
  sourceType: 'cycle_recommended',
  targetCPLH: 12,
  targetSPLH: 50,
  targetPPA: 40,
  fohWage: 18,
  bohWage: 20,
  opzFloorCPLH: 10,
  opzCeilingCPLH: 14,
  theoreticalFohLaborPct: 12.5,
  theoreticalBohLaborPct: 12.5,
  theoreticalLaborPct: 25,
);

void main() {
  group('timing provenance model fields', () {
    test('ClosedShiftInput carries timing triplet into ShiftFact', () {
      final input = ClosedShiftInput(
        restaurantId: 'rest-1',
        businessDate: DateTime.utc(2026, 5, 6),
        weekId: '2026-W19',
        dayLabel: 'Wed',
        daypart: 'Dinner',
        businessTimingProfileId: 'profile-1',
        businessTimingProfileVersionId: 'profile-1',
        servicePeriodKey: 'dinner',
        covers: 42,
        forecastCovers: 50,
        actualSales: 1680,
        actualFohHours: 4,
        actualBohHours: 6,
        actualFohLaborDollars: 72,
        actualBohLaborDollars: 120,
      );

      final fact = ShiftFactBuilder.fromClosedShiftInput(input, _target);

      expect(fact.businessTimingProfileId, 'profile-1');
      expect(fact.businessTimingProfileVersionId, 'profile-1');
      expect(fact.servicePeriodKey, 'dinner');
    });

    test('ShiftRecord serializes timing triplet additively', () {
      const record = ShiftRecord(
        restaurantId: 'rest-1',
        weekId: '2026-W19',
        dayLabel: 'Wed',
        daypart: 'Dinner',
        status: 'closed',
        covers: 42,
        forecastCovers: 50,
        ppa: 40,
        cplh: 10.5,
        splh: 280,
        fohHours: 4,
        bohHours: 6,
        theoreticalLaborPct: 25,
        primaryLever: 'ON_MODEL',
        businessDate: '2026-05-06',
        businessTimingProfileId: 'profile-1',
        businessTimingProfileVersionId: 'profile-1',
        servicePeriodKey: 'dinner',
      );

      final roundTrip = ShiftRecord.fromMap(record.toMap());

      expect(roundTrip.businessTimingProfileId, 'profile-1');
      expect(roundTrip.businessTimingProfileVersionId, 'profile-1');
      expect(roundTrip.servicePeriodKey, 'dinner');
    });

    test('OpenShiftSnapshot serializes timing triplet additively', () {
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'rest-1',
        weekId: '2026-W19',
        dayLabel: 'Wed',
        daypart: 'Whole Day',
        status: 'open',
        businessDate: '2026-05-06',
        businessTimingProfileId: 'profile-1',
        businessTimingProfileVersionId: 'profile-1',
        servicePeriodKey: 'whole_day',
        forecastCovers: 100,
        currentCovers: 40,
        scheduledFohHours: 20,
        scheduledBohHours: 16,
        currentPPA: 42,
        currentCPLH: 10,
        currentSPLH: 105,
        blendedWage: 19,
        updatedAt: '2026-05-06T12:00:00Z',
      );

      final roundTrip = OpenShiftSnapshot.fromMap(snapshot.toMap());

      expect(roundTrip.businessTimingProfileId, 'profile-1');
      expect(roundTrip.businessTimingProfileVersionId, 'profile-1');
      expect(roundTrip.servicePeriodKey, 'whole_day');
    });
  });
}
