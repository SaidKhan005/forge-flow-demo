// HP#11 S2/S4 regression coverage — the admin cross-tenant
// business-timing-resolution gateway is INERT in the production admin
// app unless `lib/main_admin.dart` actually instantiates the HTTP
// gateway and passes it into the single production
// `AdminConsoleServicesScope(...)`. This locks the missing DI hop so it
// cannot silently regress back to the empty in-memory demo fallback.
//
// Two assertions:
//  (a) Production wiring path — `main_admin.dart` resolves and injects
//      a real `HttpAdminBusinessTimingResolutionGateway` exactly like
//      the working sibling `_resolveAdminNotificationPreferencesGateway`
//      (source-string assertion: the resolvers are private to
//      `main_admin.dart`, so this mirrors the established
//      `data_accuracy_live_wiring_test.dart` pattern), and a scope
//      constructed the production way (HTTP gateway passed in) makes
//      `timingResolutionGatewayOf` return that HTTP gateway — NOT the
//      InMemory demo one.
//  (b) Demo / share-preview path stays byte-equivalent — no scope (or
//      a scope with a null timing gateway, the demo/share-preview
//      shape) still resolves to the seeded in-memory fallback so the
//      S4 Timing screens render their honest "no profile yet" state.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_profiles_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';

void main() {
  test(
    'admin live entrypoint injects business-timing-resolution HTTP gateway '
    '(mirrors the notification-prefs sibling resolver)',
    () {
      final source = File('lib/main_admin.dart').readAsStringSync();

      // The HTTP gateway type is imported and instantiated.
      expect(source, contains('HttpAdminBusinessTimingResolutionGateway'));
      expect(
        source,
        contains(
          "import 'admin/services/"
          "admin_business_timing_resolution_gateway.dart';",
        ),
      );

      // A production resolver exists, byte-mirroring the working
      // notification-prefs sibling (same live-vs-null gating).
      expect(
        source,
        contains('_resolveAdminBusinessTimingResolutionGateway'),
      );
      expect(
        source,
        matches(
          RegExp(
            r'final adminBusinessTimingResolutionGateway = gateway == null'
            r'\s*\?\s*null\s*:\s*_resolveAdminBusinessTimingResolutionGateway',
            multiLine: true,
          ),
        ),
      );

      // It is passed into the single production
      // `AdminConsoleServicesScope(...)` construction.
      expect(
        source,
        contains(
          'timingResolutionGateway: adminBusinessTimingResolutionGateway',
        ),
      );
    },
  );

  testWidgets(
    'production scope (HTTP gateway injected) yields the HTTP gateway, '
    'NOT the in-memory demo fallback',
    (tester) async {
      final httpGateway = HttpAdminBusinessTimingResolutionGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 'test-token',
      );
      late AdminBusinessTimingResolutionGateway resolved;

      await tester.pumpWidget(
        AdminConsoleServicesScope(
          timingResolutionGateway: httpGateway,
          child: Builder(
            builder: (context) {
              resolved =
                  AdminConsoleServicesScope.timingResolutionGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        resolved,
        same(httpGateway),
        reason: 'production wiring must surface the HTTP gateway',
      );
      expect(resolved, isA<HttpAdminBusinessTimingResolutionGateway>());
      expect(
        resolved,
        isNot(isA<InMemoryAdminBusinessTimingResolutionGateway>()),
      );
    },
  );

  testWidgets(
    'demo / share-preview path (null timing gateway) stays byte-equivalent: '
    'in-memory fallback so the S4 screen renders the honest empty state',
    (tester) async {
      late AdminBusinessTimingResolutionGateway viaNullScope;
      late AdminBusinessTimingResolutionGateway viaNoScope;

      // Demo / share-preview: production resolver returns null, so the
      // scope is constructed with a null timing gateway.
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          timingResolutionGateway: null,
          child: Builder(
            builder: (context) {
              viaNullScope =
                  AdminConsoleServicesScope.timingResolutionGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Widget-test / no-scope shape (also exercised by the
      // walkthrough): same in-memory fallback.
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            viaNoScope =
                AdminConsoleServicesScope.timingResolutionGatewayOf(context);
            return const SizedBox.shrink();
          },
        ),
      );

      expect(
        viaNullScope,
        isA<InMemoryAdminBusinessTimingResolutionGateway>(),
        reason: 'demo / share-preview must keep the seeded in-memory '
            'fallback (honest "no profile yet" empty state)',
      );
      expect(
        viaNoScope,
        isA<InMemoryAdminBusinessTimingResolutionGateway>(),
      );
      // Byte-equivalent: both demo-shaped paths resolve to the SAME
      // shared seeded fallback instance (unchanged behavior).
      expect(viaNullScope, same(viaNoScope));
    },
  );

  // Timing-editable parity — the admin business-timing PROFILE WRITE
  // gateway is the NEW DI hop that powers the editable Timing screen. It
  // is INERT in the production admin app unless `main_admin.dart`
  // instantiates the HTTP gateway and passes it into the single
  // `AdminConsoleServicesScope(...)`. Mirror the resolution-gateway locks
  // above so this write hop cannot silently regress to the empty
  // in-memory demo fallback.

  test(
    'admin live entrypoint injects business-timing-profiles HTTP WRITE '
    'gateway (byte-mirrors the resolution sibling resolver)',
    () {
      final source = File('lib/main_admin.dart').readAsStringSync();

      expect(source, contains('HttpAdminBusinessTimingProfilesGateway'));
      expect(
        source,
        contains(
          "import 'admin/services/"
          "admin_business_timing_profiles_gateway.dart';",
        ),
      );
      expect(source, contains('_resolveAdminBusinessTimingProfilesGateway'));
      expect(
        source,
        matches(
          RegExp(
            r'final adminBusinessTimingProfilesGateway = gateway == null'
            r'\s*\?\s*null\s*:\s*_resolveAdminBusinessTimingProfilesGateway',
            multiLine: true,
          ),
        ),
      );
      expect(
        source,
        contains(
          'timingProfilesGateway: adminBusinessTimingProfilesGateway',
        ),
      );
    },
  );

  testWidgets(
    'production scope (HTTP profiles gateway injected) yields the HTTP '
    'gateway, NOT the in-memory demo fallback',
    (tester) async {
      final httpGateway = HttpAdminBusinessTimingProfilesGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 'test-token',
      );
      late AdminBusinessTimingProfilesGateway resolved;

      await tester.pumpWidget(
        AdminConsoleServicesScope(
          timingProfilesGateway: httpGateway,
          child: Builder(
            builder: (context) {
              resolved =
                  AdminConsoleServicesScope.timingProfilesGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(resolved, same(httpGateway));
      expect(resolved, isA<HttpAdminBusinessTimingProfilesGateway>());
      expect(
        resolved,
        isNot(isA<InMemoryAdminBusinessTimingProfilesGateway>()),
      );
    },
  );

  testWidgets(
    'demo / share-preview path (null profiles gateway) stays byte-equivalent: '
    'shared in-memory write fallback for the editor',
    (tester) async {
      late AdminBusinessTimingProfilesGateway viaNullScope;
      late AdminBusinessTimingProfilesGateway viaNoScope;

      await tester.pumpWidget(
        AdminConsoleServicesScope(
          timingProfilesGateway: null,
          child: Builder(
            builder: (context) {
              viaNullScope =
                  AdminConsoleServicesScope.timingProfilesGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        Builder(
          builder: (context) {
            viaNoScope =
                AdminConsoleServicesScope.timingProfilesGatewayOf(context);
            return const SizedBox.shrink();
          },
        ),
      );

      expect(viaNullScope, isA<InMemoryAdminBusinessTimingProfilesGateway>());
      expect(viaNoScope, isA<InMemoryAdminBusinessTimingProfilesGateway>());
      // Both demo-shaped paths resolve to the SAME shared seeded fallback
      // instance (mirrors the resolution sibling's same-instance behavior).
      expect(viaNullScope, same(viaNoScope));
    },
  );
}
