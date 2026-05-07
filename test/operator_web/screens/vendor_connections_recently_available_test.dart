// Phase 11W.8 follow-up — widget tests for the Vendor Connections
// "Recently available" panel.
//
// Asserts the panel renders rows when the gateway returns recently-
// promoted vendors, hides itself when the result is empty, fires the
// connect callback on tap, and renders the correct relative-timestamp
// copy ("today" / "yesterday" / "N days ago").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_vendor_lifecycle_recently_available_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/vendor_connections_recently_available_panel.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  group('VendorConnectionsRecentlyAvailablePanel', () {
    Widget wrap(Widget child) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(
          backgroundColor: AppColors.backgroundDeep,
          body: SingleChildScrollView(child: child),
        ),
      );
    }

    OperatorWebRecentlyAvailableVendor vendor({
      required String vendorId,
      required String displayName,
      required DateTime promotedAt,
    }) {
      return OperatorWebRecentlyAvailableVendor(
        vendorId: vendorId,
        vendorDisplayName: displayName,
        lifecycleState: 'productionCredentialed',
        promotedAt: promotedAt,
      );
    }

    OperatorWebVendorLifecycleRecentlyAvailableGatewayInMemory gatewayWith(
      List<OperatorWebRecentlyAvailableVendor> vendors,
    ) {
      return OperatorWebVendorLifecycleRecentlyAvailableGatewayInMemory(
        operatorId: 'op-1',
        vendors: vendors,
        defaultSince: DateTime.utc(2026, 4, 23),
      );
    }

    testWidgets(
        'hides itself entirely when no gateway is wired',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          const VendorConnectionsRecentlyAvailablePanel(gateway: null),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_hidden'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_panel'),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'hides itself when the gateway returns no vendors',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsRecentlyAvailablePanel(
            gateway:
                gatewayWith(const <OperatorWebRecentlyAvailableVendor>[]),
            now: () => DateTime.utc(2026, 5, 7, 12),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_hidden'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_panel'),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'renders rows when the gateway returns recently-promoted vendors',
        (tester) async {
      final fixedNow = DateTime.utc(2026, 5, 7, 12);
      await tester.pumpWidget(
        wrap(
          VendorConnectionsRecentlyAvailablePanel(
            gateway: gatewayWith(<OperatorWebRecentlyAvailableVendor>[
              vendor(
                vendorId: 'toast',
                displayName: 'Toast',
                promotedAt: DateTime.utc(2026, 5, 4, 10),
              ),
              vendor(
                vendorId: 'seven_shifts',
                displayName: '7shifts',
                promotedAt: DateTime.utc(2026, 5, 7, 9),
              ),
            ]),
            now: () => fixedNow,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_panel'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'vendor_connections_recently_available_row_toast',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'vendor_connections_recently_available_row_seven_shifts',
          ),
        ),
        findsOneWidget,
      );
      // Subtitle copy reads as training.
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_subtitle'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'fires onConnectRequested with the tapped vendor',
        (tester) async {
      final fixedNow = DateTime.utc(2026, 5, 7, 12);
      OperatorWebRecentlyAvailableVendor? tapped;
      await tester.pumpWidget(
        wrap(
          VendorConnectionsRecentlyAvailablePanel(
            gateway: gatewayWith(<OperatorWebRecentlyAvailableVendor>[
              vendor(
                vendorId: 'toast',
                displayName: 'Toast',
                promotedAt: DateTime.utc(2026, 5, 4, 10),
              ),
            ]),
            now: () => fixedNow,
            onConnectRequested: (v) => tapped = v,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.byKey(
          const Key(
            'vendor_connections_recently_available_row_connect_toast',
          ),
        ),
      );
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.vendorId, equals('toast'));
    });

    test('relative time formatter returns plain-English copy', () {
      final now = DateTime.utc(2026, 5, 7, 12);
      expect(
        formatRecentlyAvailableRelativeTime(
          DateTime.utc(2026, 5, 7, 9),
          now: now,
        ),
        equals('today'),
      );
      expect(
        formatRecentlyAvailableRelativeTime(
          DateTime.utc(2026, 5, 6, 9),
          now: now,
        ),
        equals('yesterday'),
      );
      expect(
        formatRecentlyAvailableRelativeTime(
          DateTime.utc(2026, 5, 4, 9),
          now: now,
        ),
        equals('3 days ago'),
      );
      // Beyond the 14-day window falls back to a date string so the
      // panel never lies about freshness.
      expect(
        formatRecentlyAvailableRelativeTime(
          DateTime.utc(2026, 4, 1, 9),
          now: now,
        ),
        equals('2026-04-01'),
      );
    });

    testWidgets(
        'renders the failure body and retry CTA when the gateway throws',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsRecentlyAvailablePanel(
            gateway: _ThrowingGateway(),
            now: () => DateTime.utc(2026, 5, 7, 12),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_recently_available_retry'),
        ),
        findsOneWidget,
      );
    });
  });
}

class _ThrowingGateway
    implements OperatorWebVendorLifecycleRecentlyAvailableGateway {
  @override
  Future<OperatorWebRecentlyAvailableVendorsBundle> loadRecentlyAvailable({
    DateTime? since,
  }) async {
    throw const OperatorWebVendorLifecycleRecentlyAvailableError(
      code: 'transport_error',
      message: 'simulated transport failure',
    );
  }
}
