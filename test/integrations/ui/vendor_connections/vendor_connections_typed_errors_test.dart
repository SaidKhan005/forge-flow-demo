// Phase 8.0 / Wave C1 — Tests for the typed exception handlers in
// the shared `VendorConnectionsWidget`.
//
// Wave C1 replaced four bare `catch (e)` blocks with typed handlers
// that classify network/transport exceptions and surface a structured
// snackbar payload. These tests pin the contract:
//
//   * `SocketException` / `TimeoutException` / `FormatException`
//     produce honest snackbar copy with a remediation hint and do not
//     re-throw.
//   * `VendorConnectionsGatewayError` keeps surfacing through the
//     pre-existing typed branch with its own remediation hint.
//   * `Error` subclasses (programming bugs) re-throw so they surface
//     in tests and crash reporters instead of being silently swallowed.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('VendorConnectionsWidget typed error handlers', () {
    testWidgets(
      'disconnect surfaces a SocketException as a network snackbar',
      (tester) async {
        final gateway = _StubVendorConnectionsGateway(
          row: _connectedRow,
          throwOnDisconnect: const SocketException('connection refused'),
        );
        await mountWidget(tester, gateway);

        await tester.tap(
          find.byKey(const Key('vendor_connections_disconnect_libro')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('vendor_connections_disconnect_confirm')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not reach the vendor service'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Check your internet connection'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'disconnect surfaces a TimeoutException as a slow-vendor snackbar',
      (tester) async {
        final gateway = _StubVendorConnectionsGateway(
          row: _connectedRow,
          throwOnDisconnect: TimeoutException('took too long'),
        );
        await mountWidget(tester, gateway);

        await tester.tap(
          find.byKey(const Key('vendor_connections_disconnect_libro')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('vendor_connections_disconnect_confirm')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('took too long'), findsOneWidget);
      },
    );

    testWidgets(
      'view-logs surfaces a FormatException as a malformed-response snackbar',
      (tester) async {
        final gateway = _StubVendorConnectionsGateway(
          row: _connectedRow,
          throwOnLoadLogs: const FormatException('unexpected payload'),
        );
        await mountWidget(tester, gateway);

        await tester.tap(
          find.byKey(const Key('vendor_connections_logs_libro')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('returned an unexpected response'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'view-logs surfaces a VendorConnectionsGatewayError with its own remediation',
      (tester) async {
        final gateway = _StubVendorConnectionsGateway(
          row: _connectedRow,
          throwOnLoadLogs: VendorConnectionsGatewayError(
            message: 'Backend rejected the request',
            remediation: 'Try again after refreshing the page.',
          ),
        );
        await mountWidget(tester, gateway);

        await tester.tap(
          find.byKey(const Key('vendor_connections_logs_libro')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Backend rejected'), findsOneWidget);
        expect(
          find.textContaining('Try again after refreshing the page'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'programming errors (Error subclasses) re-throw instead of being swallowed',
      (tester) async {
        final gateway = _StubVendorConnectionsGateway(
          row: _connectedRow,
          throwOnLoadLogs: StateError('programming bug'),
        );
        await mountWidget(tester, gateway);

        // Tap the View-logs button inside a guarded zone so the
        // unhandled Error surfaces to the test rather than landing in
        // the framework's global error reporter after the test has
        // completed.
        Object? capturedError;
        await runZonedGuarded(() async {
          await tester.tap(
            find.byKey(const Key('vendor_connections_logs_libro')),
          );
          await tester.pumpAndSettle();
        }, (error, stack) {
          capturedError ??= error;
        });

        expect(capturedError, isA<StateError>());
        expect((capturedError! as StateError).message, equals('programming bug'));
        expect(
          find.textContaining('Could not reach the vendor service'),
          findsNothing,
          reason: 'Programming errors must NOT be hidden behind a snackbar.',
        );
      },
    );
  });
}

const VendorConnectionRow _connectedRow = VendorConnectionRow(
  connectionId: 'conn-libro',
  vendorId: 'libro',
  displayName: 'Libro Reserve',
  category: VendorCategory.reservation,
  status: VendorConnectionStatus.connected,
  metadata: <String, Object?>{},
);

/// Test-only gateway whose mutating endpoints throw the supplied
/// exception so the typed catch blocks in the parent widget can be
/// exercised. `loadBundle` returns a single connected reservation row
/// so the connected-card actions are visible.
class _StubVendorConnectionsGateway implements VendorConnectionsGateway {
  _StubVendorConnectionsGateway({
    required this.row,
    this.throwOnDisconnect,
    this.throwOnLoadLogs,
  });

  final VendorConnectionRow row;
  final Object? throwOnDisconnect;
  final Object? throwOnLoadLogs;

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async => VendorConnectionsBundle(
    operatorId: operatorId,
    locationId: locationId,
    locationName: 'Stub Location',
    posConnection: null,
    reservationConnection: row,
    laborConnection: null,
    demoFlags: const <VendorCategory, bool>{
      VendorCategory.pos: false,
      VendorCategory.reservation: false,
      VendorCategory.labor: false,
    },
  );

  @override
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  }) async => const <VendorPickerEntry>[];

  @override
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  }) async => const VendorConnectFlowStart(
    redirectUrl: 'about:blank',
    flowKind: VendorConnectFlowKind.oauthRedirect,
  );

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
  }) async {
    if (throwOnDisconnect != null) throw throwOnDisconnect!;
  }

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async {
    if (throwOnLoadLogs != null) throw throwOnLoadLogs!;
    return const <VendorSyncLogEntry>[];
  }
}
