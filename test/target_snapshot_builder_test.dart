import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/domain/services/target_snapshot_builder.dart';

void main() {
  group('TargetSnapshotBuilder.fromCurrentBaseline', () {
    test('targetCPLH matches BaselineData.derivedTargetCPLH', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().targetCPLH,
        BaselineData.derivedTargetCPLH,
      );
    });

    test('targetSPLH matches BaselineData.derivedTargetSPLH', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().targetSPLH,
        BaselineData.derivedTargetSPLH,
      );
    });

    test('targetPPA matches BaselineData.derivedTargetPPA', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().targetPPA,
        BaselineData.derivedTargetPPA,
      );
    });

    test('fohWage matches MeridianConfig.fohWage', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().fohWage,
        MeridianConfig.fohWage,
      );
    });

    test('bohWage matches MeridianConfig.bohWage', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().bohWage,
        MeridianConfig.bohWage,
      );
    });

    test('theoreticalFohLaborPct matches BaselineData.derivedFohTheoreticalLaborPct', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().theoreticalFohLaborPct,
        BaselineData.derivedFohTheoreticalLaborPct,
      );
    });

    test('theoreticalBohLaborPct matches BaselineData.derivedBohTheoreticalLaborPct', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().theoreticalBohLaborPct,
        BaselineData.derivedBohTheoreticalLaborPct,
      );
    });

    test('theoreticalLaborPct matches BaselineData.derivedTheoreticalLaborPct', () {
      expect(
        TargetSnapshotBuilder.fromCurrentBaseline().theoreticalLaborPct,
        BaselineData.derivedTheoreticalLaborPct,
      );
    });
  });
}
