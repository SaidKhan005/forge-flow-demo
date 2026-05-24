// X-G71 (cross-surface parity register §0b) — admin
// notification-preferences screen widget tests.
//
// Coverage:
//   * renders the full catalog (admin actor sees every event,
//     including the operator-only / manager-only rows — see the
//     role-gate divergence note in the screen header)
//   * a toggle fires an upsert through the gateway and the row reflects
//     the new state
//   * a gateway failure rolls the toggle back and surfaces the
//     plain-English error snackbar
//   * a retried toggle reuses the SAME idempotency key (never mints a
//     fresh one per attempt — the G60/G70 bug class)
//   * a null gateway renders the honest read-only "saving turned off"
//     note and disables every switch

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/admin_notification_preferences_screen.dart';
import 'package:forge_and_flow/admin/services/admin_notification_preferences_gateway.dart';
import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('AdminNotificationPreferencesScreen', () {
    testWidgets('renders the full catalog for the admin actor',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryAdminNotificationPreferencesGateway();
      await tester.pumpWidget(
        wrap(AdminNotificationPreferencesScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_notification_preferences_screen')),
        findsOneWidget,
      );
      // Admin has no operator role, so the screen renders every catalog
      // row unfiltered (including the audit-only + manager-only rows).
      for (final event in kNotificationCatalog) {
        expect(
          find.byKey(
            Key('admin_notification_preferences_event_${event.eventKey}'),
          ),
          findsOneWidget,
          reason: 'admin should see ${event.eventKey}',
        );
      }
    });

    testWidgets('event rows use the ops-style info button (no inline subcopy)',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryAdminNotificationPreferencesGateway();
      await tester.pumpWidget(
        wrap(AdminNotificationPreferencesScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      // A coming-soon row carries the info button and no inline subcopy:
      // the description + state detail live in the popover, matching the
      // operator-web Notifications screen.
      expect(
        find.byKey(const Key(
          'admin_notification_preferences_state_info_notif.shift.stale',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key(
          'admin_notification_preferences_subcopy_notif.shift.stale',
        )),
        findsNothing,
      );
    });

    testWidgets('toggling an available channel saves through the gateway',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryAdminNotificationPreferencesGateway();
      await tester.pumpWidget(
        wrap(AdminNotificationPreferencesScreen(
          gateway: gateway,
          idempotencyKeyFactory: () => 'idem-fixed-1',
        )),
      );
      await tester.pumpAndSettle();

      // `notif.backfill.complete` defaults push+email ON; toggling push
      // writes an enabled=false row.
      final toggle = find.byKey(const Key(
        'admin_notification_preferences_toggle_'
        'notif.backfill.complete_push',
      ));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(gateway.calls, hasLength(1));
      expect(gateway.calls.single.eventKey, 'notif.backfill.complete');
      expect(gateway.calls.single.channel, 'push');
      expect(gateway.calls.single.enabled, isFalse);
      expect(gateway.calls.single.scopeKind, 'operator');
      expect(gateway.calls.single.idempotencyKey, 'idem-fixed-1');
    });

    testWidgets('gateway failure rolls back and shows the error snackbar',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = _ThrowingGateway();
      await tester.pumpWidget(
        wrap(AdminNotificationPreferencesScreen(
          gateway: gateway,
          idempotencyKeyFactory: () => 'idem-fixed-2',
        )),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key(
        'admin_notification_preferences_toggle_'
        'notif.backfill.complete_push',
      ));
      await tester.ensureVisible(toggle);
      Switch readSwitch() => tester.widget<Switch>(toggle);
      expect(readSwitch().value, isTrue, reason: 'push defaults ON');

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key(
          'admin_notification_preferences_error_snackbar',
        )),
        findsOneWidget,
      );
      // Optimistic flip rolled back to the original ON state.
      expect(readSwitch().value, isTrue);
    });

    testWidgets('a retried toggle reuses the same idempotency key',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      // First attempt throws (rollback), second attempt succeeds. The
      // screen must reuse the SAME minted key on the retry, never mint
      // a fresh one per attempt (G60/G70 bug class).
      final gateway = _FailOnceGateway();
      var minted = 0;
      await tester.pumpWidget(
        wrap(AdminNotificationPreferencesScreen(
          gateway: gateway,
          idempotencyKeyFactory: () {
            minted += 1;
            return 'idem-key-$minted';
          },
        )),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key(
        'admin_notification_preferences_toggle_'
        'notif.backfill.complete_push',
      ));
      await tester.ensureVisible(toggle);

      // Attempt 1 — fails, rolls back.
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      // Attempt 2 (retry of the same logical toggle) — succeeds.
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(gateway.keys, hasLength(2));
      expect(
        gateway.keys.first,
        gateway.keys.last,
        reason: 'retry must replay the SAME idempotency key',
      );
      expect(minted, 1, reason: 'key minted exactly once for the row');
    });

    testWidgets('null gateway renders read-only with disabled switches',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await tester.pumpWidget(
        wrap(const AdminNotificationPreferencesScreen(gateway: null)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key(
          'admin_notification_preferences_disconnected_note',
        )),
        findsOneWidget,
      );
      // Every rendered switch is disabled (onChanged == null).
      final switches = tester.widgetList<Switch>(find.byType(Switch));
      expect(switches, isNotEmpty);
      for (final s in switches) {
        expect(s.onChanged, isNull);
      }
    });
  });
}

class _ThrowingGateway implements AdminNotificationPreferencesGateway {
  @override
  Future<List<AdminNotificationPreference>> listPreferences() async =>
      const <AdminNotificationPreference>[];

  @override
  Future<AdminNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    throw const AdminNotificationPreferencesGatewayError(
      statusCode: 503,
      errorCode: 'unavailable',
      message: 'down',
    );
  }
}

class _FailOnceGateway implements AdminNotificationPreferencesGateway {
  final List<String> keys = <String>[];
  bool _failedOnce = false;

  @override
  Future<List<AdminNotificationPreference>> listPreferences() async =>
      const <AdminNotificationPreference>[];

  @override
  Future<AdminNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    if (!_failedOnce) {
      _failedOnce = true;
      throw const AdminNotificationPreferencesGatewayError(
        statusCode: 503,
        errorCode: 'unavailable',
        message: 'transient',
      );
    }
    return AdminNotificationPreference(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeKind == 'operator' ? null : scopeId,
      enabled: enabled,
    );
  }
}
