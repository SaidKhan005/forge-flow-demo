import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/services/target_snapshot_builder.dart';

void main() {
  group('TargetSnapshotBuilder.fromActiveTargetProfile', () {
    final profile = ActiveTargetProfile(
      targetProfileId: 'test_profile',
      restaurantId: 'test_restaurant',
      sourceType: 'manager_override',
      targetCPLH: 4.75,
      targetSPLH: 185.0,
      targetPPA: 43.5,
      fohWage: 17.0,
      bohWage: 22.0,
      opzFloorCPLH: 3.6,
      opzCeilingCPLH: 5.9,
      theoreticalFohLaborPct: 9.5,
      theoreticalBohLaborPct: 11.9,
      theoreticalLaborPct: 21.4,
      builtAt: '2026-03-30T12:00:00',
    );

    test('copies all target fields from profile', () {
      final snapshot = TargetSnapshotBuilder.fromActiveTargetProfile(
        profile,
        targetProfileVersionId: 'v1',
      );
      expect(snapshot.restaurantId, 'test_restaurant');
      expect(snapshot.targetProfileId, 'test_profile');
      expect(snapshot.targetProfileVersionId, 'v1');
      expect(snapshot.sourceType, 'manager_override');
      expect(snapshot.targetCPLH, 4.75);
      expect(snapshot.targetSPLH, 185.0);
      expect(snapshot.targetPPA, 43.5);
      expect(snapshot.fohWage, 17.0);
      expect(snapshot.bohWage, 22.0);
      expect(snapshot.opzFloorCPLH, 3.6);
      expect(snapshot.opzCeilingCPLH, 5.9);
      expect(snapshot.theoreticalLaborPct, 21.4);
    });
  });
}
