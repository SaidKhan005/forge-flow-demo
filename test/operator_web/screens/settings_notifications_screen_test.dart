// Phase 8 W2.B - Notifications screen widget tests.
//
// Coverage:
//   * renders all events for a manager-role actor
//   * admin-only event row hidden for a manager-only role
//   * manager-only events hidden for a non-manager role
//   * toggle fires PUT through the gateway
//   * gateway failure rolls the toggle back + surfaces error snackbar

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/settings_notifications_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_notification_preferences_gateway_provider.dart';
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

  OperatorWebSession sessionWithRoles(List<String> roles) =>
      OperatorWebSession(
        uid: 'demo-uid',
        email: 'alex@brio-restaurants.com',
        displayName: 'Alex Morrison',
        operatorId: 'demo-operator',
        businessName: 'Brio Restaurants',
        primaryLocationId: 'demo-location',
        primaryLocationName: 'Brio Main Street',
        roles: roles,
        mfaEnrolled: false,
      );

  group('SettingsNotificationsScreen', () {
    testWidgets('admin actor sees every event including audit row',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('settings_notifications_screen')),
        findsOneWidget,
      );
      // Every catalog event for an admin (manager + adminOnly + any).
      for (final event in kNotificationCatalog) {
        expect(
          find.byKey(Key('settings_notifications_event_${event.eventKey}')),
          findsOneWidget,
          reason: 'admin should see ${event.eventKey}',
        );
      }
    });

    testWidgets('non-admin manager hides the audit-only row but keeps shift row',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      // operator_manager satisfies managerOnly but NOT adminOnly.
      final session = sessionWithRoles(<String>['operator_manager']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // adminOnly hidden.
      expect(
        find.byKey(const Key('settings_notifications_event_notif.audit.anchor_failure')),
        findsNothing,
        reason: 'audit anchor row is admin-only',
      );
      // managerOnly visible.
      expect(
        find.byKey(const Key('settings_notifications_event_notif.shift.stale')),
        findsOneWidget,
      );
      // any-role visible.
      expect(
        find.byKey(const Key('settings_notifications_event_notif.backfill.complete')),
        findsOneWidget,
      );
    });

    testWidgets(
        'non-manager actor (operator_staff) hides manager-only rows',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      // operator_staff satisfies neither managerOnly nor adminOnly.
      final session = sessionWithRoles(<String>['operator_staff']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Audit + shift staleness + plan all hidden.
      expect(
        find.byKey(const Key('settings_notifications_event_notif.audit.anchor_failure')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings_notifications_event_notif.shift.stale')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('settings_notifications_event_notif.plan.updated')),
        findsNothing,
      );
      // any-role event still visible.
      expect(
        find.byKey(const Key('settings_notifications_event_notif.backfill.complete')),
        findsOneWidget,
      );
    });

    testWidgets('toggle fires PUT through the gateway with a fresh idem key',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      var idemSeq = 0;
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(
          session: session,
          gateway: gateway,
          idempotencyKeyFactory: () {
            idemSeq += 1;
            return 'test-idem-$idemSeq';
          },
        )),
      );
      await tester.pumpAndSettle();
      // Toggle the push channel for backfill complete (default = on).
      await tester.tap(
        find.byKey(const Key(
            'settings_notifications_toggle_notif.backfill.complete_push')),
      );
      await tester.pumpAndSettle();
      expect(gateway.upsertCalls, hasLength(1));
      final call = gateway.upsertCalls.single;
      expect(call['eventKey'], equals('notif.backfill.complete'));
      expect(call['channel'], equals('push'));
      expect(call['enabled'], isFalse);
      expect(call['idempotencyKey'], equals('test-idem-1'));
    });

    testWidgets(
        'gateway failure rolls back the optimistic flip and shows '
        'an error snackbar', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway()..upsertShouldThrow = true;
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(
          session: session,
          gateway: gateway,
          idempotencyKeyFactory: () => 'test-idem-1',
        )),
      );
      await tester.pumpAndSettle();
      // Default email channel for backfill complete is on; toggle off.
      final toggleKey = const Key(
          'settings_notifications_toggle_notif.backfill.complete_email');
      final beforeSwitch = tester.widget<Switch>(find.byKey(toggleKey));
      expect(beforeSwitch.value, isTrue);
      await tester.tap(find.byKey(toggleKey));
      await tester.pump(); // optimistic flip
      // Pump to drain the error path + snackbar.
      await tester.pumpAndSettle();
      // Toggle is back to its pre-tap state.
      final afterSwitch = tester.widget<Switch>(find.byKey(toggleKey));
      expect(afterSwitch.value, isTrue);
      // Snackbar surfaced.
      expect(
        find.byKey(const Key('settings_notifications_error_snackbar')),
        findsOneWidget,
      );
    });
  });
}

class _FakeGateway implements WebNotificationPreferencesGateway {
  bool upsertShouldThrow = false;
  final List<Map<String, Object?>> upsertCalls = <Map<String, Object?>>[];

  @override
  Future<List<WebNotificationPreference>> listPreferences() async {
    return const <WebNotificationPreference>[];
  }

  @override
  Future<WebNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    upsertCalls.add(<String, Object?>{
      'eventKey': eventKey,
      'channel': channel,
      'scopeKind': scopeKind,
      'scopeId': scopeId,
      'enabled': enabled,
      'idempotencyKey': idempotencyKey,
    });
    if (upsertShouldThrow) {
      throw const WebNotificationPreferencesError(
        code: 'simulated_failure',
        message: 'fake gateway failure',
      );
    }
    return WebNotificationPreference(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeId,
      enabled: enabled,
    );
  }

  @override
  Future<void> deletePreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required String idempotencyKey,
  }) async {}
}
