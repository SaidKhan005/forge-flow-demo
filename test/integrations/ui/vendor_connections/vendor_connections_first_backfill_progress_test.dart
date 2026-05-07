// Phase 8.operator-self-service / first-backfill progress indicator —
// widget tests.
//
// Pins the in-card progress chrome rendered for each
// `VendorConnectionFirstBackfillStatus` value so the operator-facing
// UX writing standard (plain English; no engineering jargon — the
// operator never sees "backfill" or "dead-lettered") cannot regress
// silently.

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
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> mount(
    WidgetTester tester,
    VendorConnectionsGateway gateway, {
    bool hasIndeterminateProgress = false,
  }) async {
    await sizeViewport(tester);
    await tester.pumpWidget(
      wrap(
        VendorConnectionsWidget(
          operatorId: 'op-1',
          locationId: 'loc-1',
          gateway: gateway,
        ),
      ),
    );
    if (hasIndeterminateProgress) {
      // The running/pending indicator paints an indeterminate
      // CircularProgressIndicator that never settles; tick the
      // microtask queue + one frame to render the resolved bundle
      // without blocking forever inside pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    } else {
      await tester.pumpAndSettle();
    }
  }

  VendorConnectionsBundle bundleWith(VendorConnectionRow row) {
    return VendorConnectionsBundle(
      operatorId: 'op-1',
      locationId: 'loc-1',
      locationName: 'Test location',
      posConnection: row.category == VendorCategory.pos ? row : null,
      laborConnection: row.category == VendorCategory.labor ? row : null,
      reservationConnection:
          row.category == VendorCategory.reservation ? row : null,
      demoFlags: const <VendorCategory, bool>{
        VendorCategory.pos: false,
        VendorCategory.labor: false,
        VendorCategory.reservation: true,
      },
    );
  }

  testWidgets(
    'running status renders the in-flight indicator with determinate '
    'progress when processed/total days are populated',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-toast',
              vendorId: 'toast',
              displayName: 'Toast',
              category: VendorCategory.pos,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
              firstBackfill: VendorConnectionFirstBackfill(
                status: VendorConnectionFirstBackfillStatus.running,
                startedAt: DateTime.utc(2026, 5, 7, 10),
                processedDays: 12,
                totalDays: 60,
              ),
            ),
          ),
        },
      );

      await mount(tester, gateway, hasIndeterminateProgress: true);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_toast_running'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Pulling 60 days of history... 12 of 60 days complete.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'pending status falls back to the indeterminate "we will let you know" '
    'message when progress counts are missing',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-7s',
              vendorId: '7shifts',
              displayName: '7shifts',
              category: VendorCategory.labor,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
              firstBackfill: const VendorConnectionFirstBackfill(
                status: VendorConnectionFirstBackfillStatus.pending,
              ),
            ),
          ),
        },
      );

      await mount(tester, gateway, hasIndeterminateProgress: true);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_7shifts_running'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Pulling 60 days of history. We will let you know when this is done.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'succeeded status renders the green completion line with the '
    'formatted start->end window when both timestamps are present',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-humanity',
              vendorId: 'humanity',
              displayName: 'Humanity',
              category: VendorCategory.labor,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
              firstBackfill: VendorConnectionFirstBackfill(
                status: VendorConnectionFirstBackfillStatus.succeeded,
                startedAt: DateTime.utc(2026, 5, 6, 22),
                completedAt: DateTime.utc(2026, 5, 6, 22, 22),
              ),
            ),
          ),
        },
      );

      await mount(tester, gateway);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_humanity_succeeded'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('60-day history loaded. Pulled 2026-05-06 to 2026-05-06.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'failed status surfaces the failure reason with the resume guidance',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-square',
              vendorId: 'square',
              displayName: 'Square',
              category: VendorCategory.pos,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
              firstBackfill: const VendorConnectionFirstBackfill(
                status: VendorConnectionFirstBackfillStatus.failed,
                failureReason: 'token revoked mid-pull',
              ),
            ),
          ),
        },
      );

      await mount(tester, gateway);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_square_failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '60-day history paused. Run Test connection to resume.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Reason from vendor sync: token revoked mid-pull'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'dead-lettered status is rendered using the same paused chrome as '
    'failed (operator never sees the engineering term)',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-opentable',
              vendorId: 'opentable',
              displayName: 'OpenTable',
              category: VendorCategory.reservation,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
              firstBackfill: const VendorConnectionFirstBackfill(
                status: VendorConnectionFirstBackfillStatus.deadLettered,
                failureReason: 'attempts exhausted',
              ),
            ),
          ),
        },
      );

      await mount(tester, gateway);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_opentable_failed'),
        ),
        findsOneWidget,
      );
      // The operator-facing copy must NOT leak the worker-tier term
      // 'dead-lettered'. The paused-line is the contract.
      expect(find.textContaining('dead'), findsNothing);
      expect(find.textContaining('backfill'), findsNothing);
      expect(
        find.text(
          '60-day history paused. Run Test connection to resume.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'firstBackfill == null hides the indicator entirely (legacy / '
    'pre-queue connection rows)',
    (tester) async {
      final gateway = InMemoryVendorConnectionsGateway(
        seed: <String, VendorConnectionsBundle>{
          'op-1/loc-1': bundleWith(
            VendorConnectionRow(
              connectionId: 'cnx-legacy',
              vendorId: 'toast',
              displayName: 'Toast',
              category: VendorCategory.pos,
              status: VendorConnectionStatus.connected,
              metadata: const <String, Object?>{},
              lastSyncAt: DateTime.utc(2026, 5, 7, 11),
            ),
          ),
        },
      );

      await mount(tester, gateway);

      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_toast_running'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_toast_succeeded'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_toast_failed'),
        ),
        findsNothing,
      );
    },
  );
}
