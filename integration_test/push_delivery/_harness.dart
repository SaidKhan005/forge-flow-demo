// Wave 2 Q-2c — Push delivery round-trip integration harness.
//
// Companion to Q-2b's `integration_test/in_app_notifications/
// _harness.dart`. Where Q-2b asserts that the inbox + badge + tile
// surfaces fire when the in-process notifier emits, Q-2c asserts the
// FULL round-trip — from "a push delivery arrives at the demo app"
// through "the bell badge advances, the notifications screen renders
// the expected tile, and the tap handler routes correctly".
//
// The harness boots the production `main_forgeflow.main()` with
// `--dart-define=kDemoMode=true` so the test exercises the same
// `AppNotificationService.emitPushDelivery` path the production FCM
// foreground/background/terminated handlers use. There is NO
// demo-only reader fork — HP #2 binds.
//
// Test Lab driving:
//   The same test file is what Firebase Test Lab runs on every device
//   in the matrix. The matrix runner at
//   `tool/firebase_test_lab/firebase_test_lab_runner.dart` ships the
//   APK / IPA + this test bundle to gcloud; Test Lab spins up the
//   device, drives the test, captures pass / fail per device.
//
// Latency budget:
//   30s cold-boot envelope (matches Q-2b's `kNotificationPathBudget`).
//   Conservatively the same so a slow Test Lab device does not flake
//   the matrix.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:forge_and_flow/domain/models/app_notification.dart';
import 'package:forge_and_flow/domain/services/utc_metadata_timestamp.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/main_forgeflow.dart' as ff_app;
import 'package:forge_and_flow/screens/notifications_screen.dart';
import 'package:forge_and_flow/services/app_notification_service.dart';

/// Compile-time guard. Refuses to run against a non-demo binary so
/// we never assert against production data shape.
const bool kDemoMode = bool.fromEnvironment('kDemoMode');

/// Hard ceiling for a single push-delivery round trip. From "seed
/// the FCM-shaped delivery" through "AppShell mounted, bell badge
/// reflects the unread count, notifications screen renders the tile
/// with the expected plain-English copy". 30s envelope matches the
/// Q-2b harness so a single budget tweak lives in one place.
const Duration kPushDeliveryPathBudget = Duration(seconds: 30);

/// Latency budget for the in-tree assertion that the seeded tile
/// surfaces in the notifications list AFTER navigation.
const Duration kPushTileRenderBudget = Duration(seconds: 5);

/// Boots the demo F&F app via the standard `main_forgeflow.main()`.
/// Mirrors `integration_test/in_app_notifications/_harness.dart` so
/// a single behaviour change to either harness lives in one place
/// at refactor time.
Future<void> launchDemoApp(WidgetTester tester) async {
  if (!kDemoMode) {
    throw StateError(
      'Q-2c push delivery integration test requires '
      '--dart-define=kDemoMode=true. The harness asserts against the '
      'demo seed; running against production-flavor data would tag '
      'rows the live writer owns. Re-invoke flutter test with the '
      'demo flag, or refer to tool/firebase_test_lab/README.md for '
      'the full command.',
    );
  }
  await ff_app.main();
  await tester.pump();
  await _pumpUntilSettledOrBudget(tester);
}

/// Initialises the Flutter integration_test binding. Each test file
/// calls this in its own `main()`. Test Lab layers its own platform
/// runtime on top; without one the suite still runs under the stock
/// `integration_test` binding.
IntegrationTestWidgetsFlutterBinding bootstrapPushDeliveryBinding() {
  return IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Pump until either no frame is scheduled or [budget] elapses.
/// Cribbed verbatim from the Q-2b harness so the cold-boot path
/// behaves identically across the two soaks.
Future<void> _pumpUntilSettledOrBudget(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  Duration budget = kPushDeliveryPathBudget,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < budget) {
    await tester.pump(step);
    if (!tester.binding.hasScheduledFrame) return;
  }
}

/// Drives a push delivery the same way the production FCM
/// foreground/background/terminated handlers would: via
/// `AppNotificationService.emitPushDelivery`. HP #2 — the inbox
/// writer is the only seam; demo seed + production push converge
/// here, and Test Lab exercises the convergent path.
///
/// Returns the seeded [AppNotification] so the test can assert on
/// the title / body it just wrote (avoids drift between catalog copy
/// and asserted copy).
Future<AppNotification> seedPushDelivery({
  required String type,
  required String eventKey,
  required String title,
  required String body,
  String? restaurantId,
  String? businessDate,
}) async {
  final scopedRestaurantId = restaurantId ?? DemoScope.restaurantId;
  final scopedBusinessDate = businessDate ?? _todayBusinessDate();
  await AppNotificationService.instance.emitPushDelivery(
    restaurantId: scopedRestaurantId,
    type: type,
    eventKey: eventKey,
    title: title,
    body: body,
    businessDate: scopedBusinessDate,
  );
  return AppNotification(
    notificationId: '${scopedRestaurantId}_$eventKey',
    restaurantId: scopedRestaurantId,
    type: type,
    eventKey: eventKey,
    title: title,
    body: body,
    businessDate: scopedBusinessDate,
    createdAt: nowIsoUtc(),
  );
}

String _todayBusinessDate() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '${now.year}-$m-$d';
}

/// Navigate to the notifications screen by pushing the named route.
/// Mirrors the equivalent helper in the Q-2b harness — side-steps
/// the bell-icon hit-test (icon position varies by shell variant).
Future<void> openNotificationsScreen(WidgetTester tester) async {
  final navigatorState =
      tester.state<NavigatorState>(find.byType(Navigator));
  await navigatorState.pushNamed(NotificationsScreen.routeName);
  await tester.pump();
  await _pumpUntilSettledOrBudget(tester, budget: kPushTileRenderBudget);
}

/// Asserts the active widget tree contains an [AppShell].
Future<void> expectAppShellMounted(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < budget) {
    if (find.byType(AppShell).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    find.byType(AppShell),
    findsOneWidget,
    reason:
        'AppShell never mounted within $budget — the demo seed or auth '
        'gate likely failed. Check the SQLite seed log and '
        '`bootstrapAndRunApp` for thrown exceptions.',
  );
}

/// Confirms the [NotificationsScreen] is the top route. Used after
/// [openNotificationsScreen] to verify the tap-handler routed to the
/// expected destination.
void expectNotificationsScreenMounted() {
  expect(
    find.byType(NotificationsScreen),
    findsOneWidget,
    reason:
        'NotificationsScreen never mounted — the named-route push '
        'likely failed. Confirm `forge_flow_app.dart` registers the '
        '/notifications route.',
  );
}

/// Asserts no `RenderFlex` overflow exceptions accumulated during
/// the scenario. Identical to the Q-2b helper of the same name.
class FlutterErrorTap {
  FlutterErrorTap._();

  final List<FlutterErrorDetails> _errors = <FlutterErrorDetails>[];
  FlutterExceptionHandler? _previous;

  static FlutterErrorTap install() {
    final tap = FlutterErrorTap._();
    tap._previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      tap._errors.add(details);
      tap._previous?.call(details);
    };
    return tap;
  }

  void restore() {
    FlutterError.onError = _previous;
  }

  List<FlutterErrorDetails> get overflowErrors {
    return _errors
        .where(
          (e) =>
              e.exception.toString().contains('RenderFlex') ||
              (e.context?.toString().toLowerCase().contains('overflow') ??
                  false),
        )
        .toList(growable: false);
  }

  List<FlutterErrorDetails> get all => List.unmodifiable(_errors);
}

/// Reset the in-memory [AppNotificationService] state between tests
/// so a previous run's seed cannot leak into this run's assertions.
@visibleForTesting
void resetNotificationServiceForTest() {
  AppNotificationService.instance.resetForTest();
}
