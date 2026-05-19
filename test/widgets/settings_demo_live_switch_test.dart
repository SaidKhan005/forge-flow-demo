import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/screens/settings/settings_demo_live_switch.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  group('SettingsDemoLiveSwitch', () {
    testWidgets('confirms and calls proxy for Demo -> Live', (tester) async {
      final client = _FakeSwitchClient(isDemo: true);
      final notifier = DemoModeStateNotifier(client: client);
      await notifier.setScope(operatorId: 'op-1', locationId: 'loc-1');

      await tester.pumpWidget(_wrap(client, notifier));
      expect(tester.widget<Switch>(_switchFinder).value, isTrue);

      await tester.tap(_switchFinder);
      await tester.pumpAndSettle();
      expect(find.text('Switch demo data to live?'), findsOneWidget);

      await tester.tap(find.text('Switch to live'));
      await tester.pumpAndSettle();

      expect(client.switchCalls, <String>['op-1:loc-1:idem-1']);
      expect(find.text('Demo data switched to live.'), findsOneWidget);
      expect(tester.widget<Switch>(_switchFinder).value, isFalse);
    });

    testWidgets('refuses Live -> Demo in the client', (tester) async {
      final client = _FakeSwitchClient(isDemo: false);
      final notifier = DemoModeStateNotifier(client: client);
      await notifier.setScope(operatorId: 'op-1', locationId: 'loc-1');

      await tester.pumpWidget(_wrap(client, notifier));
      expect(tester.widget<Switch>(_switchFinder).value, isFalse);

      await tester.tap(_switchFinder);
      await tester.pumpAndSettle();

      expect(client.switchCalls, isEmpty);
      expect(
        find.text('Live data has arrived. Demo mode cannot be restored.'),
        findsWidgets,
      );
    });
  });
}

final Finder _switchFinder = find.byKey(const Key('settings_demo_live_switch'));

Widget _wrap(_FakeSwitchClient client, DemoModeStateNotifier notifier) {
  return MultiProvider(
    providers: [
      Provider<SyncProxyClient?>.value(value: client),
      ChangeNotifierProvider<DemoModeStateNotifier>.value(value: notifier),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SettingsDemoLiveSwitch(idempotencyKeyFactory: () => 'idem-1'),
      ),
    ),
  );
}

class _FakeSwitchClient implements SyncProxyClient, DemoModeMasterSwitchClient {
  _FakeSwitchClient({required bool isDemo}) : _isDemo = isDemo;

  bool _isDemo;
  final List<String> switchCalls = <String>[];

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    return <DemoModeRecord>[
      DemoModeRecord(
        operatorId: operatorId,
        locationId: locationId,
        category: IntegrationCategory.pos,
        isDemo: _isDemo,
      ),
    ];
  }

  @override
  Future<List<DemoModeRecord>> switchDemoModeToLive({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    switchCalls.add('$operatorId:$locationId:$idempotencyKey');
    _isDemo = false;
    return fetchDemoModeStates(operatorId: operatorId, locationId: locationId);
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) => throw UnimplementedError();

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) => throw UnimplementedError();

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? businessDate,
  }) => throw UnimplementedError();

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) => throw UnimplementedError();

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) => throw UnimplementedError();

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) => throw UnimplementedError();

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) => throw UnimplementedError();

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) => throw UnimplementedError();
}
