// Regression — location switch must not throw "setState() or
// markNeedsBuild() called during build" via the demo-mode scope path.
//
// Defect (operator-reproduced): switching the active location on
// mobile re-runs `_AppShellState.didChangeDependencies` (AppShell
// `context.watch`es `RestaurantScopeNotifier` for its business-scope
// drawer). That re-ran `_bindDemoModeNotifier` -> `_syncDemoModeScope`
// -> `DemoModeStateNotifier.setScope`, which synchronously cleared the
// snapshot and called `notifyListeners()` *inside the build phase*.
// The mounted `DemoModeBanner` (a `context.watch` dependent of the
// notifier) was then `markNeedsBuild`-ed mid-build -> framework throw,
// and the just-cleared empty snapshot flashed scope-dependent screens
// to their empty state.
//
// Fix: `_AppShellState` defers the notifier mutation to a post-frame
// callback (`lib/forge_flow_app.dart` `_syncDemoModeScope` ->
// `_applyDemoModeScope`). Semantics (scope resolution, dedupe key,
// empty->clear, refresh) are unchanged; only the timing moves out of
// build.
//
// This test mounts the real `AppShell` with the production-style
// provider set, lets the initial scope bind settle, then flips the
// active (operator, location) and pumps. Asserts: NO framework
// exception, `DemoModeStateNotifier` still received the new scope
// (semantics preserved), and the demo/scope-dependent consumer
// (`DemoModeBanner`) is still mounted (screen not torn down).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/state/app_refresh_coordinator.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';
import 'package:forge_and_flow/state/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_scope_repository.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/domain/repositories/week_record_repository.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

// ── Stubs (mirrors test/app_resume_refresh_test.dart harness) ────────────

class _NullShiftDataSource implements ShiftDataSource {
  const _NullShiftDataSource();
  @override
  Future<WeekData?> getWeekToDate() async => null;
  @override
  Future<List<WeekRecord>> getWeekHistory() async => [];
  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async => [];
  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => [];
  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => [];
}

class _StubDemandForecastNotifier extends DemandForecastContextNotifier {
  @override
  Future<void> load() async {}
}

class _FakeScopeRepo implements RestaurantScopeRepository {
  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async =>
      const RestaurantLocation(
        restaurantId: 'test',
        displayName: 'Test',
        businessTimezone: 'UTC',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
  @override
  Future<String> getActiveRestaurantId() async => 'test';
}

class _FakeWeekRepo implements WeekRecordRepository {
  @override
  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async => [];
  @override
  Future<int> upsertWeekRecord(WeekRecord record) async => 1;
}

class _FakeShiftRepo implements ShiftRecordRepository {
  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
    String restaurantId,
    String weekId,
  ) async => [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
    String restaurantId,
    List<String> weekIds,
  ) async => [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
    String restaurantId,
    String startDate,
    String endDate,
  ) async => [];
  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      null;
  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 1;
}

class _TrackingWeekDataNotifier extends WeekDataNotifier {
  _TrackingWeekDataNotifier() : super(const _NullShiftDataSource());
  @override
  Future<void> refresh() async {}
}

class _TrackingShiftDashboardNotifier extends ShiftDashboardNotifier {
  _TrackingShiftDashboardNotifier()
      : super.emptyForTest(AppDataStatus.noData);
  @override
  Future<void> refresh() async {}
}

class _TestBus extends ChangeNotifier implements AppRuntimeInvalidationBus {
  void fire() => notifyListeners();
  @override
  void notifyCurrentStateChanged() => fire();
  @override
  void notifyRuntimeWriteCompleted() => fire();
  @override
  void notifyImportCompletionPersisted() => fire();
}

/// Scope notifier whose active (operator, location) can be flipped
/// synchronously WITHOUT touching SQLite (the production
/// `activateBusinessScope` path persists through
/// `SqliteRestaurantScopeRepository`, unavailable in widget tests).
/// Overriding only `activeScope` is sufficient: `_AppShellState`
/// reads scope via `RestaurantScopeNotifier.activeScope`, and the
/// AppShell business-scope drawer `context.watch`es this notifier so
/// `switchScope` re-runs `didChangeDependencies` exactly as the real
/// location picker does.
class _ScopeSwitchableNotifier extends RestaurantScopeNotifier {
  _ScopeSwitchableNotifier(
    super.restaurant, {
    BusinessScope? activeScope,
  })  : _scope = activeScope,
        super.fromRestaurant();

  BusinessScope? _scope;

  @override
  BusinessScope? get activeScope => _scope;

  void switchScope(BusinessScope scope) {
    _scope = scope;
    notifyListeners();
  }
}

/// Minimal in-memory `SyncProxyClient`. Only `fetchDemoModeStates`
/// is exercised; everything else throws so an accidental read fails
/// loudly. Records every scope it was asked for.
class _StubSyncProxyClient implements SyncProxyClient {
  final List<String> fetchedScopes = <String>[];

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    fetchedScopes.add('$operatorId:$locationId');
    return <DemoModeRecord>[
      DemoModeRecord(
        operatorId: operatorId,
        locationId: locationId,
        category: IntegrationCategory.pos,
        isDemo: true,
      ),
    ];
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) =>
      throw UnimplementedError('not needed in this test');

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) =>
      throw UnimplementedError('not needed in this test');

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) =>
      throw UnimplementedError('not needed in this test');

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in this test');

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
      fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) =>
          throw UnimplementedError('not needed in this test');

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in this test');

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
      fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) =>
          throw UnimplementedError('not needed in this test');

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in this test');
}

BusinessScope _locationScope(String operatorId, String locationId) =>
    BusinessScope(
      scopeId: locationId,
      scopeType: 'location',
      operatorId: operatorId,
      locationId: locationId,
      label: 'Loc $locationId',
    );

({
  Widget widget,
  _ScopeSwitchableNotifier scope,
  DemoModeStateNotifier demo,
  _StubSyncProxyClient client,
}) _buildHarness() {
  final scope = _ScopeSwitchableNotifier(
    const RestaurantLocation(
      restaurantId: 'test',
      displayName: 'Test',
      businessTimezone: 'UTC',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    ),
    activeScope: _locationScope('op-1', 'loc-1'),
  );
  final target = ActiveTargetProfileNotifier.fromProfile(
    const ActiveTargetProfile(
      targetProfileId: 'p',
      restaurantId: 'test',
      sourceType: 'system_baseline',
      targetCPLH: 20,
      targetSPLH: 60,
      targetPPA: 30,
      fohWage: 15,
      bohWage: 18,
      opzFloorCPLH: 15,
      opzCeilingCPLH: 25,
      theoreticalFohLaborPct: 25,
      theoreticalBohLaborPct: 25,
      theoreticalLaborPct: 25,
      builtAt: '',
    ),
  );
  final client = _StubSyncProxyClient();
  final demo = DemoModeStateNotifier(client: client);
  final weights = ScheduleDistributionWeightsNotifier(
    scopeRepo: _FakeScopeRepo(),
    weekRepo: _FakeWeekRepo(),
    shiftRepo: _FakeShiftRepo(),
  );
  final bus = _TestBus();

  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>.value(value: scope),
      Provider<ShiftDataSource>.value(value: const _NullShiftDataSource()),
      ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(value: target),
      ChangeNotifierProvider<WeekDataNotifier>.value(
        value: _TrackingWeekDataNotifier(),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>.value(
        value: _TrackingShiftDashboardNotifier(),
      ),
      ChangeNotifierProvider<DemandForecastContextNotifier>(
        create: (_) => _StubDemandForecastNotifier(),
      ),
      ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>(
        create: (_) => weights,
      ),
      // Demo-mode wiring under test.
      ChangeNotifierProvider<DemoModeStateNotifier>.value(value: demo),
      Provider<SyncProxyClient?>.value(value: client),
      ChangeNotifierProvider<AppRuntimeInvalidationBus>.value(value: bus),
      ProxyProvider2<
        ActiveTargetProfileNotifier,
        AppRuntimeInvalidationBus,
        AppRefreshCoordinator
      >(
        create: (ctx) => AppRefreshCoordinator(
          restaurantScope: ctx.read<RestaurantScopeNotifier>(),
          activeTarget: ctx.read<ActiveTargetProfileNotifier>(),
          weekData: ctx.read<WeekDataNotifier>(),
          shiftDashboard: ctx.read<ShiftDashboardNotifier>(),
          demandForecast: ctx.read<DemandForecastContextNotifier>(),
          scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
        ),
        update: (ctx, _, __, previous) => previous!,
      ),
    ],
    child: const MaterialApp(
      home: AppShell(testDisableDefaultBoundaryEventOutbox: true),
    ),
  );

  return (widget: widget, scope: scope, demo: demo, client: client);
}

void main() {
  testWidgets(
    'location switch defers demo-mode scope notify out of build '
    '(no markNeedsBuild-during-build, scope semantics preserved)',
    (tester) async {
      final harness = _buildHarness();

      await tester.pumpWidget(harness.widget);
      // First-mount bind is itself post-frame deferred; pump to let
      // the post-frame callback + coalesced refresh settle.
      await tester.pump();
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'initial demo-mode bind must not throw during first build',
      );
      expect(harness.demo.snapshot.operatorId, 'op-1');
      expect(harness.demo.snapshot.locationId, 'loc-1');
      expect(find.byType(DemoModeBanner), findsOneWidget);

      // Operator switches the active location. AppShell `context.watch`es
      // RestaurantScopeNotifier (business-scope drawer), so this re-runs
      // `_AppShellState.didChangeDependencies` -> the demo-mode bind path
      // exactly like the real picker. Pre-fix this threw
      // "markNeedsBuild() called during build"; post-fix the notifier
      // mutation is post-frame.
      harness.scope.switchScope(_locationScope('op-2', 'loc-2'));
      await tester.pump();
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'location switch must not throw setState/markNeedsBuild '
            'called during build',
      );
      // Semantics preserved: the notifier was driven to the new scope.
      expect(harness.demo.snapshot.operatorId, 'op-2');
      expect(harness.demo.snapshot.locationId, 'loc-2');
      expect(harness.client.fetchedScopes, contains('op-2:loc-2'));
      // The demo/scope-dependent consumer is still mounted — the screen
      // was not torn down / blanked by the transient.
      expect(find.byType(DemoModeBanner), findsOneWidget);
    },
  );
}
