// 8.demo-mode-banner — DemoModeBanner widget behavioural tests.
//
// Asserts the runtime read-side promise from
// `lib/services/integration/demo_mode_state.dart` (header lines 12-15):
//   * banner shows one row per category whose `is_demo = true`
//   * banner clears when `is_demo` flips to false (HP #2 — no
//     redeploy required)
//   * banner stays hidden when no scope is bound or no proxy client
//     is wired (demo / no-Firebase shells)
//
// The widget reads the global demo-mode notifier via Provider; the
// notifier itself reads `demo_mode_state` rows through a
// `SyncProxyClient`. Tests inject an in-memory fake client.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

void main() {
  group('DemoModeBanner', () {
    testWidgets(
      'renders one row per is_demo=true category for the active scope',
      (tester) async {
        final client = _StubSyncProxyClient(
          onFetch: ({required operatorId, required locationId}) async {
            return <DemoModeRecord>[
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.pos,
                isDemo: true,
              ),
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.labor,
                isDemo: true,
              ),
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.reservation,
                isDemo: false,
              ),
            ];
          },
        );
        final notifier = DemoModeStateNotifier(client: client);
        await notifier.setScope(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );

        await tester.pumpWidget(_wrap(notifier));
        await tester.pump();

        expect(find.byKey(const Key('demo_mode_banner')), findsOneWidget);
        expect(
          find.byKey(const Key('demo_mode_banner_pos')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('demo_mode_banner_labor')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('demo_mode_banner_reservation')),
          findsNothing,
        );
        expect(
          find.text('Demo POS data — connect a POS to go live.'),
          findsOneWidget,
        );
        expect(
          find.text('Demo labor data — connect a labor system to go live.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'hides when every category has flipped to is_demo=false',
      (tester) async {
        final client = _StubSyncProxyClient(
          onFetch: ({required operatorId, required locationId}) async {
            return <DemoModeRecord>[
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.pos,
                isDemo: false,
                flippedToLiveAt: DateTime.utc(2026, 5, 8),
                flippedByConnectionId: 'conn-1',
              ),
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.labor,
                isDemo: false,
                flippedToLiveAt: DateTime.utc(2026, 5, 8),
                flippedByConnectionId: 'conn-2',
              ),
            ];
          },
        );
        final notifier = DemoModeStateNotifier(client: client);
        await notifier.setScope(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );

        await tester.pumpWidget(_wrap(notifier));
        await tester.pump();

        expect(find.byKey(const Key('demo_mode_banner')), findsNothing);
        expect(
          find.byKey(const Key('demo_mode_banner_pos')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'clears between renders when the row flips after first backfill',
      (tester) async {
        bool flipped = false;
        final client = _StubSyncProxyClient(
          onFetch: ({required operatorId, required locationId}) async {
            return <DemoModeRecord>[
              DemoModeRecord(
                operatorId: operatorId,
                locationId: locationId,
                category: IntegrationCategory.pos,
                isDemo: !flipped,
                flippedToLiveAt: flipped ? DateTime.utc(2026, 5, 8) : null,
                flippedByConnectionId: flipped ? 'conn-1' : null,
              ),
            ];
          },
        );
        final notifier = DemoModeStateNotifier(client: client);
        await notifier.setScope(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );

        await tester.pumpWidget(_wrap(notifier));
        await tester.pump();
        expect(
          find.byKey(const Key('demo_mode_banner_pos')),
          findsOneWidget,
        );

        // Simulate the vendor sink committing the first backfill;
        // `DemoModeFlipPolicy.evaluateFlip` flips the row server-side
        // and a realtime invalidation triggers a refresh.
        flipped = true;
        await notifier.refresh();
        await tester.pump();

        expect(
          find.byKey(const Key('demo_mode_banner_pos')),
          findsNothing,
        );
        expect(find.byKey(const Key('demo_mode_banner')), findsNothing);
      },
    );

    testWidgets('hides when no scope is bound', (tester) async {
      final client = _StubSyncProxyClient(
        onFetch: ({required operatorId, required locationId}) async {
          return <DemoModeRecord>[
            DemoModeRecord(
              operatorId: operatorId,
              locationId: locationId,
              category: IntegrationCategory.pos,
              isDemo: true,
            ),
          ];
        },
      );
      final notifier = DemoModeStateNotifier(client: client);
      // No `setScope` call — notifier is unscoped.

      await tester.pumpWidget(_wrap(notifier));
      await tester.pump();

      expect(find.byKey(const Key('demo_mode_banner')), findsNothing);
    });

    testWidgets(
      'hides when no proxy client is wired (demo / no-Firebase shells)',
      (tester) async {
        // Notifier with no client; setScope should not throw.
        final notifier = DemoModeStateNotifier();
        await notifier.setScope(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );

        await tester.pumpWidget(_wrap(notifier));
        await tester.pump();

        expect(find.byKey(const Key('demo_mode_banner')), findsNothing);
      },
    );
  });
}

Widget _wrap(DemoModeStateNotifier notifier) {
  return MaterialApp(
    home: ChangeNotifierProvider<DemoModeStateNotifier>.value(
      value: notifier,
      child: const Scaffold(body: DemoModeBanner()),
    ),
  );
}

/// Minimal in-memory fake of the proxy surface. Only
/// `fetchDemoModeStates` is exercised; every other method throws so a
/// regression that accidentally pulls timing / shift data through this
/// stub fails loudly instead of silently returning empties.
class _StubSyncProxyClient implements SyncProxyClient {
  _StubSyncProxyClient({
    required Future<List<DemoModeRecord>> Function({
      required String operatorId,
      required String locationId,
    }) onFetch,
  }) : _onFetch = onFetch;

  final Future<List<DemoModeRecord>> Function({
    required String operatorId,
    required String locationId,
  }) _onFetch;

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) =>
      _onFetch(operatorId: operatorId, locationId: locationId);

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
      fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) =>
          throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
      fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) =>
          throw UnimplementedError('not needed in DemoModeBanner tests');

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError('not needed in DemoModeBanner tests');
}
