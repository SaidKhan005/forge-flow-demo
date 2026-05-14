// Wave 2 Q-2b — Patrol harness for the in-app notification surface.
//
// Shared bootstrap + assertion helpers for the per-path Patrol tests
// under `integration_test/in_app_notifications/`. Each path file owns
// its own `void main()` so the suite can be run as a single
// invocation:
//
//     flutter test integration_test/in_app_notifications/ \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// Or as a single path:
//
//     flutter test integration_test/in_app_notifications/invite_claimed_transition_test.dart \
//       --flavor forgeflow \
//       --dart-define=kDemoMode=true
//
// Contract pins (mirror the Q-1 / Phase 4 emulator click-path harness
// pattern intentionally so the orchestrator review can compare apples
// to apples):
//
// 1. HP #2 (CLAUDE.md → Demo Mode) — `kDemoMode` is a writer-side
//    switch. We boot the production `main_forgeflow.main()` with
//    `--dart-define=kDemoMode=true` and seed the notification rows
//    through the existing `AppNotificationService.emit*` surface
//    (same code path that production push delivery uses). No demo-only
//    reader fork, no `demo_*` SQLite table.
// 2. HP #4 — every seed scopes to the active operator's
//    `DemoScope.restaurantId`. Cross-operator reads are out of scope
//    for this harness; the bell badge is operator-scoped by design.
// 3. No network. The Patrol tests run against the local SQLite seed +
//    in-app dispatcher. The Patrol native side is only exercised
//    when an emulator / device is attached. Without one the suite
//    falls back to `flutter_test`-style assertions (still meaningful
//    for the widget-tree contract; native gesture coverage requires
//    `patrol test`).
// 4. UX writing standard. Strings asserted by these tests are the
//    operator-visible copy from `notification_event_catalog.dart` —
//    plain English, no jargon.
//
// Why Patrol vs the existing Phase 4 harness:
//
// The in-app notification bell is intentionally cross-cutting. A path
// that fires from a push delivery handler (FCM foreground/background)
// needs native-side gesture support that the stock `WidgetTester`
// cannot drive — Patrol's `$()` finder + `nativeAutomator` round-trip
// through the host gesture pipeline so the lockscreen-shade /
// notification-shade interaction is exercisable. The Q-2c slice will
// extend this same harness with Firebase Test Lab matrix runs.
//
// File layout intentionally mirrors `tool/pressure/p4_soak_orchestrator.dart`'s
// per-path approach: one file per surface, one orchestrator that
// fans them out and emits a Markdown report.

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
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

/// Compile-time guard. Phase 4's emulator click-path pins this same
/// constant, and the Q-2b harness inherits the rule: refuse to run
/// against a non-demo binary so we never assert against production
/// data shape.
const bool kDemoMode = bool.fromEnvironment('kDemoMode');

/// Hard ceiling for a single in-app notification path: from "seed
/// the notification row" through "AppShell mounted, bell badge
/// reflects the unread count, notifications screen renders the tile
/// with the expected plain-English copy". 30s is the same cold-boot
/// envelope Phase 4 pins; the per-path budget is conservatively the
/// same so a slow emulator does not flake the suite.
const Duration kNotificationPathBudget = Duration(seconds: 30);

/// Latency budget for the in-tree assertion that the seeded tile
/// surfaces in the notifications list AFTER navigation. 5s is a soft
/// SLO — anything slower indicates a notifier-refresh hang, not a
/// network delay (the harness has no network).
const Duration kTileRenderBudget = Duration(seconds: 5);

/// Boots the demo F&F app via the standard `main_forgeflow.main()`.
/// Mirrors `integration_test/phase_4_emulator/_harness.dart` so a
/// single behavior change to either harness lives in one place at
/// refactor time.
Future<void> launchDemoApp(WidgetTester tester) async {
  if (!kDemoMode) {
    throw StateError(
      'Q-2b in-app notification Patrol harness requires '
      '--dart-define=kDemoMode=true. The harness asserts against the '
      'demo seed; running against production-flavor data would tag '
      'rows the live writer owns. Re-invoke flutter test with the '
      'demo flag, or refer to integration_test/in_app_notifications/'
      'README.md for the full command.',
    );
  }
  await ff_app.main();
  await tester.pump();
  await _pumpUntilSettledOrBudget(tester);
}

/// Initialises the Flutter integration_test binding and returns it.
/// Each path file calls this in its own `main()`. Patrol layers its
/// own binding on top via `patrolTest`; when Patrol's runtime is not
/// available (no emulator attached) the test still runs under the
/// stock integration_test binding.
IntegrationTestWidgetsFlutterBinding bootstrapInAppNotificationBinding() {
  return IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Pump until either no frame is scheduled or [budget] elapses.
/// Cribbed from the Phase 4 harness verbatim so the cold-boot path
/// behaves identically; the in-app notifier writes off a wall-clock
/// stream (`AppNotificationService.unreadCountNotifier`) and
/// `tester.pumpAndSettle` would hang otherwise.
Future<void> _pumpUntilSettledOrBudget(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  Duration budget = kNotificationPathBudget,
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < budget) {
    await tester.pump(step);
    if (!tester.binding.hasScheduledFrame) return;
  }
}

/// Seeds a single notification row through the same code path the
/// FCM foreground/background/terminated handlers use
/// (`AppNotificationService.emitPushDelivery`). HP #2 — the inbox
/// writer is the only seam; production push delivery and demo seed
/// converge here.
///
/// Returns the seeded [AppNotification] so the test can assert on the
/// title/body it just wrote (avoids drift between the catalog copy
/// and the asserted copy).
Future<AppNotification> seedNotification({
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

/// Today as the `business_date` SQLite column expects. Local-time
/// anchor on purpose — the time-guardrails contract pins
/// "business_date is the anchor". Matches the `AppNotificationService`
/// convention used by the production push handlers.
String _todayBusinessDate() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '${now.year}-$m-$d';
}

/// Navigate to the notifications screen by pushing the named route.
/// Side-steps the bell-icon hit-test (icon position varies by shell
/// variant — operator-web admin vs the mobile-shell) and exercises
/// the same route the bell tap handler uses.
Future<void> openNotificationsScreen(WidgetTester tester) async {
  final navigatorState = tester.state<NavigatorState>(find.byType(Navigator));
  await navigatorState.pushNamed(NotificationsScreen.routeName);
  await tester.pump();
  await _pumpUntilSettledOrBudget(tester, budget: kTileRenderBudget);
}

/// Asserts the active widget tree contains an [AppShell] (i.e. the
/// app reached the post-login destination). Mirrors the Phase 4
/// helper of the same name so a regression that strips AppShell
/// surfaces in both harnesses.
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
/// [openNotificationsScreen].
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

/// Confirms the [DemoModeBanner] widget is part of the tree. The
/// banner only renders runtime chrome when `demo_mode_state` rows
/// exist for the active scope, so we assert mount rather than
/// visibility — mount is the contract the Phase 8 surface pins.
void expectDemoModeBannerMounted() {
  expect(find.byType(DemoModeBanner), findsWidgets);
}

/// Asserts no `RenderFlex` overflow exceptions accumulated during the
/// scenario. Identical to the Phase 4 tap so a regression that breaks
/// the notification tile's layout surfaces here too.
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

/// Reset the in-memory [AppNotificationService] state between tests so
/// path N's seed cannot leak into path N+1's assertions. The DAO
/// itself is process-singleton SQLite, so the harness does NOT wipe
/// the table — it just re-points the in-process service back at the
/// production repo. Tests that share an isolate intentionally
/// double-write through `insertIfAbsent` (UNIQUE dedup).
@visibleForTesting
void resetNotificationServiceForTest() {
  AppNotificationService.instance.resetForTest();
}
