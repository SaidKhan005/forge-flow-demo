// Phase 8.0 / 8.operator-self-service — API-key paste dialog tests.
//
// Pins the in-widget flow for api-key vendors: when the picker
// resolves a `VendorAuthMode.keyPaste` entry, the parent widget
// shows the paste dialog (instead of starting an OAuth redirect),
// disables the Connect button until the operator types a key, and
// hands the key bundle to `connectWithApiKey` on submit. Cancel
// must NOT call the gateway at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_widget.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> mountWidget(
    WidgetTester tester,
    VendorConnectionsGateway gateway,
  ) async {
    await sizeViewport(tester);
    await tester.pumpWidget(
      wrap(
        VendorConnectionsWidget(
          operatorId: 'test-operator',
          locationId: 'test-location',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('VendorConnectionsWidget api-key paste flow', () {
    testWidgets(
      'picker -> paste dialog appears for a connectable key-paste vendor',
      (tester) async {
        final gateway = _ApiKeyTestGateway();
        await mountWidget(tester, gateway);

        await tester.tap(
          find.byKey(const Key('vendor_connections_connect_pos')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(
            const Key('vendor_connections_picker_choice_aloha_ncr_voyix'),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('vendor_connections_picker_continue')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('vendor_connections_api_key_dialog')),
          findsOneWidget,
        );
        expect(find.text('Connect Aloha (NCR Voyix)'), findsOneWidget);
        expect(
          find.byKey(const Key('vendor_connections_api_key_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('vendor_connections_api_secret_field')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Connect button stays disabled until both fields filled',
        (tester) async {
      final gateway = _ApiKeyTestGateway();
      await mountWidget(tester, gateway);
      await _openApiKeyDialog(tester, vendorId: 'aloha_ncr_voyix');

      final FilledButton submitButton = tester.widget<FilledButton>(
        find.byKey(const Key('vendor_connections_api_key_submit')),
      );
      expect(submitButton.onPressed, isNull,
          reason: 'Submit must start disabled when fields are empty.');

      await tester.enterText(
        find.byKey(const Key('vendor_connections_api_key_field')),
        'auth-token',
      );
      await tester.pump();
      final FilledButton stillDisabled = tester.widget<FilledButton>(
        find.byKey(const Key('vendor_connections_api_key_submit')),
      );
      expect(stillDisabled.onPressed, isNull,
          reason: 'Aloha requires a paired site id; submit stays disabled.');

      await tester.enterText(
        find.byKey(const Key('vendor_connections_api_secret_field')),
        'restaurant-guid',
      );
      await tester.pump();
      final FilledButton enabled = tester.widget<FilledButton>(
        find.byKey(const Key('vendor_connections_api_key_submit')),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('Submit calls connectWithApiKey with the typed credentials',
        (tester) async {
      final gateway = _ApiKeyTestGateway();
      await mountWidget(tester, gateway);
      await _openApiKeyDialog(tester, vendorId: 'aloha_ncr_voyix');

      await tester.enterText(
        find.byKey(const Key('vendor_connections_api_key_field')),
        'auth-token-xxx',
      );
      await tester.enterText(
        find.byKey(const Key('vendor_connections_api_secret_field')),
        'restaurant-guid-yyy',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('vendor_connections_api_key_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.connectCalls, hasLength(1));
      final call = gateway.connectCalls.single;
      expect(call.vendorId, 'aloha_ncr_voyix');
      expect(call.apiKey, 'auth-token-xxx');
      expect(call.apiSecret, 'restaurant-guid-yyy');
      expect(gateway.startConnectCalls, isEmpty,
          reason: 'OAuth redirect path must not be invoked for key-paste.');
    });

    testWidgets('Cancel does not call connectWithApiKey', (tester) async {
      final gateway = _ApiKeyTestGateway();
      await mountWidget(tester, gateway);
      await _openApiKeyDialog(tester, vendorId: 'aloha_ncr_voyix');

      await tester.tap(
        find.byKey(const Key('vendor_connections_api_key_cancel')),
      );
      await tester.pumpAndSettle();

      expect(gateway.connectCalls, isEmpty);
      expect(gateway.startConnectCalls, isEmpty);
    });

    testWidgets(
      'gateway error surfaces remediation text in a snackbar',
      (tester) async {
        final gateway = _ApiKeyTestGateway(
          throwOnConnect: VendorConnectionsGatewayError(
            message: 'Vendor rejected the key.',
            remediation: 'Double-check the value in your vendor portal.',
          ),
        );
        await mountWidget(tester, gateway);
        await _openApiKeyDialog(tester, vendorId: 'aloha_ncr_voyix');

        await tester.enterText(
          find.byKey(const Key('vendor_connections_api_key_field')),
          'auth-token',
        );
        await tester.enterText(
          find.byKey(const Key('vendor_connections_api_secret_field')),
          'restaurant-guid',
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('vendor_connections_api_key_submit')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Vendor rejected'), findsOneWidget);
        expect(
          find.textContaining('Double-check the value in your vendor portal'),
          findsOneWidget,
        );
      },
    );
  });
}

Future<void> _openApiKeyDialog(
  WidgetTester tester, {
  required String vendorId,
}) async {
  await tester.tap(
    find.byKey(const Key('vendor_connections_connect_pos')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(Key('vendor_connections_picker_choice_$vendorId')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const Key('vendor_connections_picker_continue')),
  );
  await tester.pumpAndSettle();
}

class _ConnectCall {
  _ConnectCall({
    required this.vendorId,
    required this.apiKey,
    this.apiSecret,
    this.module,
  });
  final String vendorId;
  final String apiKey;
  final String? apiSecret;
  final String? module;
}

class _StartConnectCall {
  _StartConnectCall({required this.vendorId, this.module});
  final String vendorId;
  final String? module;
}

/// Test-only gateway that promotes Aloha (NCR Voyix) to
/// `productionCredentialed` so the picker's lifecycle gate lets the
/// test reach the paste dialog. Aloha is first in the POS catalog so
/// it sits at the top of the picker grid (no scrolling needed under
/// the test viewport). Other vendors keep their `documented`
/// lifecycle so the fixture stays close to production reality.
class _ApiKeyTestGateway implements VendorConnectionsGateway {
  _ApiKeyTestGateway({this.throwOnConnect});

  final List<_ConnectCall> connectCalls = <_ConnectCall>[];
  final List<_StartConnectCall> startConnectCalls = <_StartConnectCall>[];
  final Object? throwOnConnect;

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async => VendorConnectionsBundle(
        operatorId: operatorId,
        locationId: locationId,
        locationName: 'Test Location',
        posConnection: null,
        laborConnection: null,
        reservationConnection: null,
        demoFlags: const <VendorCategory, bool>{
          VendorCategory.pos: true,
          VendorCategory.labor: true,
          VendorCategory.reservation: true,
        },
      );

  @override
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  }) async {
    return InMemoryVendorConnectionsGateway.vendorCatalog
        .where((entry) => entry.category == category)
        .map((entry) {
      // Promote Toast to production-credentialed so the picker's
      // lifecycle gate lets the dialog open under test. Other vendors
      // stay on their declared lifecycle so the picker chrome stays
      // honest.
      if (entry.vendorId == 'aloha_ncr_voyix') {
        return VendorPickerEntry(
          vendorId: entry.vendorId,
          displayName: entry.displayName,
          category: entry.category,
          authMode: entry.authMode,
          lifecycle: VendorLifecycle.productionCredentialed,
          coversFieldExposed: entry.coversFieldExposed,
          requiresModule: entry.requiresModule,
          modules: entry.modules,
          apiKeyFieldLabel: entry.apiKeyFieldLabel,
          apiSecretFieldLabel: entry.apiSecretFieldLabel,
          credentialsHelpText: entry.credentialsHelpText,
          credentialsPortalUrl: entry.credentialsPortalUrl,
        );
      }
      return entry;
    }).toList(growable: false);
  }

  @override
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  }) async {
    startConnectCalls.add(_StartConnectCall(vendorId: vendorId, module: module));
    return const VendorConnectFlowStart(
      redirectUrl: 'about:blank',
      flowKind: VendorConnectFlowKind.oauthRedirect,
    );
  }

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => const VendorTestConnectionResult(
        authValid: true,
        elapsedMs: 0,
        sampleSummary: '',
        fieldMapping: <String, String>{},
      );

  @override
  Future<void> disconnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String reason,
  }) async {}

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async => const <VendorSyncLogEntry>[];

  @override
  Future<VendorApiKeyConnectResult> connectWithApiKey({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
    String? module,
  }) async {
    connectCalls.add(_ConnectCall(
      vendorId: vendorId,
      apiKey: apiKey,
      apiSecret: apiSecret,
      module: module,
    ));
    if (throwOnConnect != null) throw throwOnConnect!;
    return VendorApiKeyConnectResult(
      connectionId: 'conn-$vendorId',
      connectedAt: DateTime.now().toUtc(),
      firstBackfillStarted: true,
    );
  }
}
