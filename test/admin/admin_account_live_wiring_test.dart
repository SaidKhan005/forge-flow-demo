// G70 regression coverage — the admin "My Account" self-service
// identity-edit gateway is INERT in the production admin app unless
// `lib/main_admin.dart` actually instantiates the HTTP gateway and
// passes it into the single production `AdminConsoleServicesScope(...)`.
// This locks the missing DI hop so it cannot silently regress back to
// the null (edit-identity disabled) state. Without this binding G70's
// caller-stable idempotency-key fix never runs in production — only
// tests/mocks exercise it.
//
// Two assertions:
//  (a) Production wiring path — `main_admin.dart` resolves and injects
//      a real `HttpAdminAccountGateway` exactly like the working
//      siblings `_resolveAdminNotificationPreferencesGateway` (X-G71)
//      and `_resolveAdminBusinessTimingResolutionGateway` (#923)
//      (source-string assertion: the resolvers are private to
//      `main_admin.dart`, so this mirrors the established
//      `admin_business_timing_resolution_live_wiring_test.dart`
//      pattern), and a scope constructed the production way (HTTP
//      gateway passed in) makes `adminAccountGatewayOf` return that
//      HTTP gateway — NOT null and NOT the InMemory demo stub.
//  (b) Demo / share-preview path stays byte-equivalent — no scope (or
//      a scope with a null account gateway, the demo/share-preview
//      shape) still resolves to null so `my_account_admin_screen.dart`
//      keeps the edit-identity affordance disabled (unchanged today).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/services/admin_account_gateway.dart';

void main() {
  test(
    'admin live entrypoint injects the My Account HTTP gateway '
    '(mirrors the X-G71 / #923 sibling resolvers)',
    () {
      final source = File('lib/main_admin.dart').readAsStringSync();

      // The HTTP gateway type is imported and instantiated.
      expect(source, contains('HttpAdminAccountGateway'));
      expect(
        source,
        contains(
          "import 'admin/services/admin_account_gateway.dart';",
        ),
      );

      // A production resolver exists, byte-mirroring the working
      // notification-prefs / timing-resolution siblings (same
      // live-vs-null gating).
      expect(source, contains('_resolveAdminAccountGateway'));
      expect(
        source,
        matches(
          RegExp(
            r'final adminAccountGateway = gateway == null'
            r'\s*\?\s*null\s*:\s*_resolveAdminAccountGateway',
            multiLine: true,
          ),
        ),
      );

      // The resolver fail-closes on demo / share-preview exactly like
      // the siblings (same gate string).
      expect(
        source,
        contains(
          'if (_kAdminDemoAuth || _kAdminSharePreview) return null;',
        ),
      );

      // It is passed into the single production
      // `AdminConsoleServicesScope(...)` construction.
      expect(
        source,
        contains('adminAccountGateway: adminAccountGateway'),
      );
    },
  );

  testWidgets(
    'production scope (HTTP gateway injected) yields the HTTP gateway, '
    'NOT null and NOT the in-memory demo stub',
    (tester) async {
      final httpGateway = HttpAdminAccountGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 'test-token',
      );
      late AdminAccountGateway? resolved;

      await tester.pumpWidget(
        AdminConsoleServicesScope(
          adminAccountGateway: httpGateway,
          child: Builder(
            builder: (context) {
              resolved =
                  AdminConsoleServicesScope.adminAccountGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        resolved,
        same(httpGateway),
        reason: 'production wiring must surface the live HTTP gateway so '
            "G70's stable idempotency key actually runs on the PATCH",
      );
      expect(resolved, isA<HttpAdminAccountGateway>());
      expect(resolved, isNot(isA<InMemoryAdminAccountGateway>()));
      expect(resolved, isNotNull);
    },
  );

  testWidgets(
    'demo / share-preview path (null account gateway) stays '
    'byte-equivalent: gateway resolves null so the edit-identity '
    'affordance stays disabled',
    (tester) async {
      late AdminAccountGateway? viaNullScope;
      late AdminAccountGateway? viaNoScope;

      // Demo / share-preview: production resolver returns null, so the
      // scope is constructed with a null account gateway.
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          adminAccountGateway: null,
          child: Builder(
            builder: (context) {
              viaNullScope =
                  AdminConsoleServicesScope.adminAccountGatewayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Widget-test / no-scope shape (also exercised by the
      // walkthrough): still null.
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            viaNoScope =
                AdminConsoleServicesScope.adminAccountGatewayOf(context);
            return const SizedBox.shrink();
          },
        ),
      );

      expect(
        viaNullScope,
        isNull,
        reason: 'demo / share-preview must keep the gateway null so '
            'my_account_admin_screen keeps edit-identity disabled '
            '(unchanged behavior)',
      );
      expect(
        viaNoScope,
        isNull,
        reason: 'no-scope (widget-test / walkthrough) shape is also null '
            'and byte-equivalent to today',
      );
    },
  );
}
