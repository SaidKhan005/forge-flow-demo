// Phase 11W.8 / Wave A3 — Operator Web Vendor Connections route
// mount tests.
//
// Focuses on the route-mount seam introduced by Wave A3: the
// resolver wiring between [OperatorWebAuthSource] and
// [VendorConnectionsScreen], routed through
// [OperatorWebRouter]. Complements the broader screen tests in
// `vendor_connections_screen_test.dart` (which cover the picker,
// notify-me dialog, breakpoints, and inline gateway plumbing).
//
// Three contracts pinned here:
//
//   1. The vendor-connections route renders the existing shared
//      widget tree when an [OperatorWebAuthSource] surfaces a live
//      [VendorConnectionsGateway] via
//      [OperatorWebVendorConnectionsGatewayProvider].
//   2. A signed-in operator user without the configure permission
//      (here: `location_manager`) hits the friendly forbidden
//      surface — the shared widget never mounts.
//   3. A demo source (no provider mixin) falls back to the in-memory
//      catalog gateway so the walkthrough renders without Cloud Run.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/router/operator_web_router.dart';
import 'package:forge_and_flow/operator_web/screens/vendor_connections_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_resolver.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('Vendor connections route mount', () {
    testWidgets(
      'live source surfaces live gateway and renders the shared widget tree',
      (tester) async {
        await sizeViewport(tester);
        final liveGateway = _RecordingVendorConnectionsGateway();
        final source = _LiveOperatorWebAuthSource(liveGateway);
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavVendorConnections,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsOneWidget,
          reason:
              'Route mount must render the vendor-connections screen body, '
              'not the placeholder.',
        );
        expect(
          find.byKey(const Key('operator_web_vendor_connections_widget_host')),
          findsOneWidget,
          reason: 'Shared widget tree mounts inside the screen host.',
        );
        // The screen reads operator + location from the active web
        // session and passes them through to the gateway boundary.
        // Pinning operator + location at this seam protects the
        // RLS-Ready Schema rule (CLAUDE.md) — operator-scoped reads
        // carry the right tenant tuple.
        expect(liveGateway.loadBundleCalls, hasLength(1));
        expect(
          liveGateway.loadBundleCalls.single.operatorId,
          equals(kDemoOperatorWebSession.operatorId),
        );
        expect(
          liveGateway.loadBundleCalls.single.locationId,
          equals(kDemoOperatorWebSession.primaryLocationId),
        );
      },
    );

    testWidgets(
      'location_manager session lands on the friendly forbidden surface',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completedAsLocationManager();
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavVendorConnections,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_vendor_connections_forbidden')),
          findsOneWidget,
          reason:
              'Without the configure key the screen renders the honest '
              'permission-denied surface.',
        );
        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsNothing,
          reason: 'The shared widget tree must NOT render without the key.',
        );
        expect(
          find.byKey(const Key('operator_web_vendor_connections_widget_host')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'empty locationId renders the honest no-location surface',
      (tester) async {
        await sizeViewport(tester);
        const adminSession = OperatorWebSession(
          uid: 'brio-admin',
          email: 'alex@brio-restaurants.com',
          displayName: 'Alex Reyes',
          operatorId: 'brio-operator',
          businessName: 'Brio Restaurants',
          primaryLocationId: 'brio-chicago-loop',
          primaryLocationName: 'Brio - Chicago Loop',
          // G7d (spec §3): phantom operator_admin folds into
          // operator_owner; fixture drives the fold target.
          roles: <String>['operator_owner'],
        );

        await tester.pumpWidget(
          wrap(
            VendorConnectionsScreen(session: adminSession, locationId: ''),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('operator_web_vendor_connections_no_location'),
          ),
          findsOneWidget,
          reason:
              'Empty locationId must render the honest no-location surface.',
        );
        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsNothing,
          reason: 'The shared widget must NOT render without a location.',
        );
        expect(
          find.byKey(
            const Key('operator_web_vendor_connections_no_location_body'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'whitespace-only locationId also renders the no-location surface',
      (tester) async {
        await sizeViewport(tester);
        const adminSession = OperatorWebSession(
          uid: 'brio-admin',
          email: 'alex@brio-restaurants.com',
          displayName: 'Alex Reyes',
          operatorId: 'brio-operator',
          businessName: 'Brio Restaurants',
          primaryLocationId: 'brio-chicago-loop',
          primaryLocationName: 'Brio - Chicago Loop',
          // G7d (spec §3): phantom operator_admin folds into
          // operator_owner; fixture drives the fold target.
          roles: <String>['operator_owner'],
        );

        await tester.pumpWidget(
          wrap(
            VendorConnectionsScreen(session: adminSession, locationId: '   '),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('operator_web_vendor_connections_no_location'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'demo source falls back to the in-memory catalog gateway',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavVendorConnections,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsOneWidget,
        );
        // The shared widget under a demo source renders the
        // implemented adapter rows seeded by
        // `InMemoryVendorConnectionsGateway`.
        expect(
          find.byKey(const Key('vendor_connections_section_pos')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('vendor_connections_section_reservation')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('vendor_connections_section_labor')),
          findsOneWidget,
        );
      },
    );
  });

  group('OperatorWebVendorConnectionsResolver', () {
    test('returns the live gateway when source mixes the provider', () {
      final liveGateway = _RecordingVendorConnectionsGateway();
      final source = _LiveOperatorWebAuthSource(liveGateway);
      addTearDown(source.dispose);

      const resolver = OperatorWebVendorConnectionsResolver();
      expect(resolver.resolve(source), same(liveGateway));
      expect(resolver.isLive(source), isTrue);
    });

    test('returns null when source omits the provider mixin', () {
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      const resolver = OperatorWebVendorConnectionsResolver();
      expect(resolver.resolve(source), isNull);
      expect(resolver.isLive(source), isFalse);
    });

    test(
      'returns null when the provider yields a null gateway (demo + provider)',
      () {
        final source = _LiveOperatorWebAuthSource(null);
        addTearDown(source.dispose);

        const resolver = OperatorWebVendorConnectionsResolver();
        expect(resolver.resolve(source), isNull);
        expect(resolver.isLive(source), isFalse);
      },
    );

    test('demoFallback yields a fresh in-memory gateway', () {
      const resolver = OperatorWebVendorConnectionsResolver();
      final fallback = resolver.demoFallback();
      expect(fallback, isA<InMemoryVendorConnectionsGateway>());
    });
  });
}

/// Auth source that mounts the demo `operator_owner` session and
/// surfaces a [VendorConnectionsGateway] via the
/// [OperatorWebVendorConnectionsGatewayProvider] mixin. Stand-in for
/// the production Firebase source under tests.
class _LiveOperatorWebAuthSource extends DemoOperatorWebAuthSource
    implements OperatorWebVendorConnectionsGatewayProvider {
  _LiveOperatorWebAuthSource(this._gateway)
    : super(
        initial: const OperatorWebCompleted(session: kDemoOperatorWebSession),
      );

  final VendorConnectionsGateway? _gateway;

  @override
  VendorConnectionsGateway? get vendorConnectionsGateway => _gateway;
}

/// Recording gateway that captures `loadBundle` calls so the mount
/// test can pin the operator + location tuple plumbed through the
/// route. Returns an empty bundle so the widget renders its
/// empty-state cards without hitting the network.
class _RecordingVendorConnectionsGateway implements VendorConnectionsGateway {
  final List<_LoadBundleCall> loadBundleCalls = <_LoadBundleCall>[];

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    loadBundleCalls.add(
      _LoadBundleCall(operatorId: operatorId, locationId: locationId),
    );
    return VendorConnectionsBundle(
      operatorId: operatorId,
      locationId: locationId,
      locationName: 'Mount test location',
      posConnection: null,
      laborConnection: null,
      reservationConnection: null,
      demoFlags: const <VendorCategory, bool>{
        VendorCategory.pos: false,
        VendorCategory.labor: false,
        VendorCategory.reservation: false,
      },
    );
  }

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
  }) async => VendorApiKeyConnectResult(
    connectionId: 'mount-conn-$vendorId',
    connectedAt: DateTime.now().toUtc(),
    firstBackfillStarted: true,
  );
}

class _LoadBundleCall {
  _LoadBundleCall({required this.operatorId, required this.locationId});
  final String operatorId;
  final String locationId;
}
