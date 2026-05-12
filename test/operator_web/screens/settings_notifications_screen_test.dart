// Phase 8 W2.B - Notifications screen widget tests.
//
// Coverage:
//   * renders all events for a manager-role actor
//   * admin-only event row hidden for a manager-only role
//   * manager-only events hidden for a non-manager role
//   * toggle fires PUT through the gateway
//   * gateway failure rolls the toggle back + surfaces error snackbar
//
// Slice C-8 (catalog completeness):
//   * every catalog entry renders for an admin actor
//   * "Coming soon" rows render disabled switches + the plain-English
//     subcopy and never call the gateway when tapped
//   * "Backend-only" rows (audit-chain integrity) render disabled
//     switches with audit-log subcopy

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

    // ---- Slice C-8: catalog completeness --------------------------------

    testWidgets(
        'C-8: admin actor sees every catalog entry with a state badge',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 1600));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();
      for (final event in kNotificationCatalog) {
        expect(
          find.byKey(Key('settings_notifications_event_${event.eventKey}')),
          findsOneWidget,
          reason: 'C-8 contract: render every catalog entry (${event.eventKey})',
        );
        expect(
          find.byKey(
              Key('settings_notifications_state_badge_${event.eventKey}')),
          findsOneWidget,
          reason: 'state badge present for ${event.eventKey}',
        );
      }
    });

    testWidgets(
        'C-8: "Coming soon" rows render disabled switches + subcopy and '
        'never call the gateway when tapped', (tester) async {
      await sizeViewport(tester, const Size(1024, 1600));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();

      // The 3 "Coming soon" entries per the audit matrix E4:
      //   notif.shift.stale, notif.star.override, notif.plan.updated.
      const comingSoon = <String>{
        'notif.shift.stale',
        'notif.star.override',
        'notif.plan.updated',
      };
      for (final key in comingSoon) {
        // Badge text "Coming soon" is present in the row.
        final badgeFinder = find.byKey(Key(
          'settings_notifications_state_badge_$key',
        ));
        expect(badgeFinder, findsOneWidget);
        expect(
          find.descendant(
            of: badgeFinder,
            matching: find.text('Coming soon'),
          ),
          findsOneWidget,
          reason: '$key badge reads "Coming soon"',
        );
        // Plain-English subcopy present.
        expect(
          find.byKey(Key('settings_notifications_subcopy_$key')),
          findsOneWidget,
          reason: '$key has plain-English subcopy',
        );
        // Every channel toggle for this row is disabled (Switch.onChanged
        // == null when the row is coming-soon).
        for (final channel in kNotificationChannelOrder) {
          final toggle = tester.widget<Switch>(
            find.byKey(Key('settings_notifications_toggle_${key}_$channel')),
          );
          expect(
            toggle.onChanged,
            isNull,
            reason: '$key channel $channel toggle must be disabled',
          );
        }
      }

      // Tapping a coming-soon switch must NOT call the gateway. We tap
      // the underlying Switch widget regardless of disabled state to
      // prove the guard short-circuits.
      gateway.upsertCalls.clear();
      // ignore: lines_longer_than_80_chars
      final switchFinder = find.byKey(
        const Key('settings_notifications_toggle_notif.shift.stale_push'),
      );
      // Disabled switches ignore taps; this acts as a regression guard
      // in case the disabled-state regresses later.
      await tester.tap(switchFinder, warnIfMissed: false);
      await tester.pump();
      expect(
        gateway.upsertCalls,
        isEmpty,
        reason: 'coming-soon toggle must not call the gateway',
      );
    });

    testWidgets(
        'C-8: "Backend-only" rows render disabled switches + audit-log '
        'subcopy', (tester) async {
      await sizeViewport(tester, const Size(1024, 1600));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();

      const auditKey = 'notif.audit.anchor_failure';
      // Badge text "Always on".
      expect(
        find.descendant(
          of: find.byKey(Key('settings_notifications_state_badge_$auditKey')),
          matching: find.text('Always on'),
        ),
        findsOneWidget,
      );
      // Subcopy mentions the audit log so the operator knows where to
      // look for activity.
      final subcopy = tester.widget<Text>(
        find.byKey(Key('settings_notifications_subcopy_$auditKey')),
      );
      expect(subcopy.data, contains('audit log'));
      // All channel toggles disabled.
      for (final channel in kNotificationChannelOrder) {
        final toggle = tester.widget<Switch>(
          find.byKey(
            Key('settings_notifications_toggle_${auditKey}_$channel'),
          ),
        );
        expect(
          toggle.onChanged,
          isNull,
          reason: 'audit-chain backend-only row toggle must be disabled',
        );
      }
    });

    testWidgets(
        'C-8: "Available" rows have no subcopy and stay interactive',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 1600));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();

      const availableKey = 'notif.backfill.complete';
      // No subcopy widget for available rows.
      expect(
        find.byKey(Key('settings_notifications_subcopy_$availableKey')),
        findsNothing,
      );
      // Badge present and reads "Available".
      expect(
        find.descendant(
          of: find.byKey(
              Key('settings_notifications_state_badge_$availableKey')),
          matching: find.text('Available'),
        ),
        findsOneWidget,
      );
      // Every channel toggle for this row has an onChanged handler.
      for (final channel in kNotificationChannelOrder) {
        final toggle = tester.widget<Switch>(
          find.byKey(
            Key('settings_notifications_toggle_${availableKey}_$channel'),
          ),
        );
        expect(
          toggle.onChanged,
          isNotNull,
          reason: 'available-row toggle must be interactive',
        );
      }
    });

    testWidgets(
        'C-8: catalog rendering preserves declared order within each '
        'category', (tester) async {
      await sizeViewport(tester, const Size(1024, 1600));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        wrap(SettingsNotificationsScreen(session: session, gateway: gateway)),
      );
      await tester.pumpAndSettle();

      // Group expected order by category from the catalog.
      final expectedByCategory =
          <NotificationCategory, List<String>>{};
      for (final entry in kNotificationCatalog) {
        expectedByCategory
            .putIfAbsent(entry.category, () => <String>[])
            .add(entry.eventKey);
      }
      // Inside the "shift" category, the rendered order of
      // `notif.shift.stale` then `notif.star.override` (per the
      // catalog) must match the on-screen y-coordinate order.
      final shiftEvents = expectedByCategory[NotificationCategory.shift]!;
      double? lastY;
      for (final key in shiftEvents) {
        final element = tester
            .element(find.byKey(Key('settings_notifications_event_$key')));
        final box = element.renderObject as RenderBox?;
        if (box == null) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        if (lastY != null) {
          expect(y, greaterThan(lastY),
              reason: 'catalog order must hold within shift category');
        }
        lastY = y;
      }
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
