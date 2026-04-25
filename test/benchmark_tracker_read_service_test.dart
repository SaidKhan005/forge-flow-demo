import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';
import 'package:forge_and_flow/services/business_date_authority_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    BenchmarkTrackerReadService.disableBridgeOnly();
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    BaselineData.clearRecommendationSignals();
    await SqliteDatabase.instance.reseedDemo();
  });

  tearDown(() {
    BenchmarkTrackerReadService.disableBridgeOnly();
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    BaselineData.clearRecommendationSignals();
  });

  test('canonical load reads persisted manager override, not bridge state',
      () async {
    final candidates = await BaselineManagerService.instance.getCandidateShifts();
    final selectedKeys = candidates.take(2).map((c) => c.recordKey).toSet();
    await BaselineManagerService.instance.saveSelection(selectedKeys);

    // Clear the in-memory bridge so the canonical read must rely on
    // persisted state rather than BaselineData leftovers.
    BaselineData.clearManagerOverride();

    final view = await BenchmarkTrackerReadService.instance.load();

    expect(view.hasManagerOverride, isTrue);
    expect(view.selectedShiftCount, equals(2));
  });

  test('canonical graph geometry ignores bridge recommendation signals',
      () async {
    await BaselineManagerService.instance.saveSelection({});
    BaselineData.applyRecommendationSignals(
      const BaselineRecommendationSignals(
        sourceType: 'cycle_recommended_insufficient',
        overallQuality: 'insufficient',
        unionBandWidth: 0,
        selectedShiftCount: 0,
        rangeFloorCPLH: 1.11,
        rangeCeilingCPLH: 9.99,
        targetCPLH: 7.77,
      ),
    );

    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate!);

    final view = await BenchmarkTrackerReadService.instance.load();

    expect(view.rangeGraphModel.activeRangeStartCPLH,
        closeTo(cycle.opzFloorCPLH, 0.001));
    expect(view.rangeGraphModel.activeRangeEndCPLH,
        closeTo(cycle.opzCeilingCPLH, 0.001));
    expect(view.rangeGraphModel.targetCPLH, closeTo(cycle.targetCPLH, 0.001));
    expect(view.rangeGraphModel.targetCPLH, isNot(closeTo(7.77, 0.001)));
  });

  test('reseeded demo cycle projects the current recommendation geometry',
      () async {
    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    final recommendation = await BaselineManagerService.instance
        .resolveRecommendedSelection(restaurantId, businessDate!);
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate);
    final view = await BenchmarkTrackerReadService.instance.load();

    expect(recommendation.isInsufficient, isFalse);
    expect(cycle.opzFloorCPLH,
        closeTo(recommendation.unionOpzFloorCPLH, 0.001));
    expect(cycle.opzCeilingCPLH,
        closeTo(recommendation.unionOpzCeilingCPLH, 0.001));
    expect(cycle.targetCPLH,
        closeTo(recommendation.pooledRecommendedTargetCPLH, 0.001));
    expect(view.rangeGraphModel.activeRangeStartCPLH,
        closeTo(recommendation.unionOpzFloorCPLH, 0.001));
    expect(view.rangeGraphModel.activeRangeEndCPLH,
        closeTo(recommendation.unionOpzCeilingCPLH, 0.001));
    expect(view.rangeGraphModel.targetCPLH,
        closeTo(recommendation.pooledRecommendedTargetCPLH, 0.001));
  });
}
