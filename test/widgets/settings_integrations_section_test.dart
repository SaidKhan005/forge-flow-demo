// Wave 2 MP-1 — widget tests for the new mobile Integrations tab body.
//
// Covers:
//   * Per-category status rows (POS, Reservation, Labor) render with
//     the correct pill label based on the `demo_mode_state` snapshot.
//   * The C-4 master Demo→Live switch is mounted inside the section
//     (key `settings_demo_live_switch_card`).
//   * Tapping the "Manage integrations on operator console" pointer
//     row mints a B11.1 handoff code, launches the operator-web URL
//     with the short opaque code as a query parameter (addendum A1
//     — never a JWT), and shows the "Opening Operator Web" toast.
//   * The pointer row renders the in-app banner / clipboard fallback
//     when the proxy refuses the mint with `auth_handoff_unavailable`.
//
// What this slice deliberately does NOT cover (per MP-1 contract):
//   * Vendor connection management (mobile is read-only; that surface
//     lives on operator-web).
//   * Richer "polling-stale / error / no-vendor" status reporting —
//     out of scope for MP-1; a dedicated vendor-status provider would
//     be a new abstraction the slice forbids.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/screens/settings/settings_integrations_section.dart';
import 'package:forge_and_flow/services/auth/handoff_code_client.dart';
import 'package:forge_and_flow/services/auth/handoff_code_gateway.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsIntegrationsSection', () {
    testWidgets(
      'renders POS / Reservations / Labor rows with status pills',
      (tester) async {
        final client = _FakeSwitchClient(
          records: <DemoModeRecord>[
            DemoModeRecord(
              operatorId: 'op-1',
              locationId: 'loc-1',
              category: IntegrationCategory.pos,
              isDemo: true,
            ),
            DemoModeRecord(
              operatorId: 'op-1',
              locationId: 'loc-1',
              category: IntegrationCategory.reservation,
              isDemo: false,
            ),
            // Labor row omitted — exercises the `unknown` status path.
          ],
        );
        final notifier = DemoModeStateNotifier(client: client);
        await notifier.setScope(operatorId: 'op-1', locationId: 'loc-1');

        await tester.pumpWidget(_wrap(client, notifier));
        await tester.pump();

        expect(
          find.byKey(const Key('settings_integrations_section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('settings_integrations_status_pos')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('settings_integrations_status_reservation')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('settings_integrations_status_labor')),
          findsOneWidget,
        );

        expect(find.text('Demo'), findsOneWidget); // POS
        expect(find.text('Live'), findsOneWidget); // Reservations
        expect(find.text('Unknown'), findsOneWidget); // Labor (no row)
      },
    );

    testWidgets('mounts the C-4 master Demo→Live switch', (tester) async {
      final client = _FakeSwitchClient(
        records: <DemoModeRecord>[
          DemoModeRecord(
            operatorId: 'op-1',
            locationId: 'loc-1',
            category: IntegrationCategory.pos,
            isDemo: true,
          ),
        ],
      );
      final notifier = DemoModeStateNotifier(client: client);
      await notifier.setScope(operatorId: 'op-1', locationId: 'loc-1');

      await tester.pumpWidget(_wrap(client, notifier));
      await tester.pump();

      expect(
        find.byKey(const Key('settings_demo_live_switch_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_demo_live_switch')),
        findsOneWidget,
      );
    });

    testWidgets(
      'console pointer mints a handoff code and launches operator-web '
      'with the opaque code in the URL — never a JWT',
      (tester) async {
        final gateway = _FakeHandoffGateway(
          link: Uri.parse(
            'https://app.forgeflow.app/handoff?code=opaque-abc&nav=vendor_connections',
          ),
        );
        final launched = <Uri>[];

        await tester.pumpWidget(
          _wrap(
            _FakeSwitchClient(records: const <DemoModeRecord>[]),
            DemoModeStateNotifier(),
            section: SettingsIntegrationsSection(
              handoffCodeGateway: gateway,
              launchExternalUrl: (url) async {
                launched.add(url);
                return true;
              },
            ),
          ),
        );
        await tester.pump();

        // The InkWell inside `SettingsPointerRow` carries the row's
        // tap target. Tapping by key is equivalent and stable.
        await tester.tap(find.text('Manage integrations on operator console'));
        await tester.pump();

        expect(gateway.targets.single.navId, 'vendor_connections');
        expect(gateway.targets.single.targetPath, '/vendor-connections');
        expect(launched.single.host, 'app.forgeflow.app');
        expect(launched.single.path, '/handoff');
        expect(launched.single.queryParameters['code'], 'opaque-abc');
        expect(launched.single.queryParameters['nav'], 'vendor_connections');
        // Addendum A1 — code is short + opaque, not a JWT. JWTs are
        // dot-delimited base64 segments; an opaque code never contains
        // dots.
        expect(launched.single.queryParameters['code']!.contains('.'), isFalse);
        expect(find.text('Opening Operator Web'), findsOneWidget);
      },
    );

    testWidgets(
      'console pointer falls back to clipboard when the proxy returns '
      '503 auth_handoff_unavailable',
      (tester) async {
        final copied = <String>[];
        final gateway = _FakeHandoffGateway(
          error: const HandoffCodeMintRejected(
            code: 'auth_handoff_unavailable',
            message: 'handoff unavailable',
            statusCode: 503,
          ),
        );

        await tester.pumpWidget(
          _wrap(
            _FakeSwitchClient(records: const <DemoModeRecord>[]),
            DemoModeStateNotifier(),
            section: SettingsIntegrationsSection(
              handoffCodeGateway: gateway,
              copyToClipboard: (value) async => copied.add(value),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('Manage integrations on operator console'));
        await tester.pump();

        expect(
          copied,
          <String>['https://app.forgeflow.app/vendor-connections'],
        );
        expect(
          find.text('Operator Web link copied - open in browser'),
          findsOneWidget,
        );
      },
    );
  });
}

Widget _wrap(
  SyncProxyClient client,
  DemoModeStateNotifier notifier, {
  SettingsIntegrationsSection? section,
}) {
  return MultiProvider(
    providers: [
      Provider<SyncProxyClient?>.value(value: client),
      ChangeNotifierProvider<DemoModeStateNotifier>.value(value: notifier),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: section ?? const SettingsIntegrationsSection(),
        ),
      ),
    ),
  );
}

class _FakeSwitchClient implements SyncProxyClient, DemoModeMasterSwitchClient {
  _FakeSwitchClient({required this.records});

  final List<DemoModeRecord> records;
  final List<String> switchCalls = <String>[];

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    return records;
  }

  @override
  Future<List<DemoModeRecord>> switchDemoModeToLive({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
  }) async {
    switchCalls.add('$operatorId:$locationId:$idempotencyKey');
    return records;
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

class _FakeHandoffGateway implements HandoffCodeGateway {
  _FakeHandoffGateway({this.link, this.error});

  final Uri? link;
  final Object? error;
  final List<HandoffDeepLinkTarget> targets = <HandoffDeepLinkTarget>[];

  @override
  Future<HandoffDeepLink> createDeepLink({
    required HandoffDeepLinkTarget target,
  }) async {
    targets.add(target);
    final thrown = error;
    if (thrown != null) throw thrown;
    return HandoffDeepLink(url: link!, expiresIn: const Duration(seconds: 60));
  }
}
