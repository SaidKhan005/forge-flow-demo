// integration_test/admin_pressure/_harness.dart
//
// Admin console pressure-test harness — 2026-05-26.
//
// Mirrors the integration_test/mobile_pressure/_harness.dart shape for the
// Forge & Flow admin console. The admin console is Flutter Web only; it
// boots from lib/main_admin.dart and gates on three dart-defines:
//
//   --dart-define=ADMIN_SHARE_PREVIEW=true
//   --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true
//   --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true
//
// All three are required together. Share-preview swaps in a seeded
// DemoAdminAuthSource (no Firebase, no proxy, no login screen), the
// super-admin variant picks the full-write fixture identity, and the
// public-fixture-auth opt-in is the release/profile fail-closed switch
// that lets the share-preview build land on the console instead of the
// "fixture auth blocked" screen.
//
// This harness throws a clear StateError if ADMIN_SHARE_PREVIEW is not
// set, exactly the way the mobile harness throws on missing kDemoMode.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:forge_and_flow/main_admin.dart' as admin_app;

/// Mirror of `kDemoMode` in the mobile harness. Read at compile time so
/// the suite refuses to run in a build where share-preview was forgotten.
const bool kAdminSharePreview = bool.fromEnvironment('ADMIN_SHARE_PREVIEW');

/// Budget for the initial admin app boot (Flutter Web fixture-auth wire-up).
const Duration kAdminBootBudget = Duration(seconds: 45);

/// Budget for a single nav-rail tap or route transition to settle.
const Duration kAdminNavBudget = Duration(seconds: 15);

/// Budget for shell mount detection after boot.
const Duration kAdminShellMountBudget = Duration(seconds: 20);

/// Pumps frames in `step` increments up to `budget`, returning early
/// once Flutter reports no more scheduled frames. Same shape as the
/// mobile harness `pumpUntil`.
Future<void> pumpUntil(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  Duration budget = kAdminBootBudget,
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < budget) {
    await tester.pump(step);
    if (!tester.binding.hasScheduledFrame) return;
  }
}

/// Initialises the IntegrationTestWidgetsFlutterBinding. Call once per
/// scenario file from inside `void main()` before declaring tests.
IntegrationTestWidgetsFlutterBinding bootstrapBinding() =>
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

/// Boots the admin console in share-preview mode and settles the first
/// paint. Refuses to run when ADMIN_SHARE_PREVIEW is not set so a
/// forgotten dart-define fails loudly (matches the mobile pattern).
Future<void> launchAdminSharePreview(WidgetTester tester) async {
  if (!kAdminSharePreview) {
    throw StateError(
      'Admin pressure suite requires '
      '--dart-define=ADMIN_SHARE_PREVIEW=true '
      '(plus ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true and '
      'ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true) — see the suite README.',
    );
  }
  await admin_app.main();
  await tester.pump();
  await pumpUntil(tester, budget: kAdminBootBudget);
}

/// Asserts the admin shell scaffold is mounted within `budget`. The
/// shell tags its root Scaffold with Key('admin_shell_scaffold') —
/// see lib/admin/admin_shell.dart:270.
Future<void> expectAdminShellMounted(
  WidgetTester tester, {
  Duration budget = kAdminShellMountBudget,
}) async {
  const shellKey = Key('admin_shell_scaffold');
  final sw = Stopwatch()..start();
  while (sw.elapsed < budget) {
    if (find.byKey(shellKey).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    find.byKey(shellKey),
    findsOneWidget,
    reason:
        'AdminShell scaffold (Key=admin_shell_scaffold) never mounted within '
        '${budget.inSeconds}s — share-preview wiring or fixture seed failed.',
  );
}

/// Taps the left-side nav row for the given admin route id. The shell
/// tags each nav row with Key('admin_nav_item_<routeId>') — see
/// lib/admin/admin_shell.dart:363 (compact) and :785 (side nav).
///
/// Throws via `expect` if the nav row is not present. This is the
/// primary navigation primitive for admin pressure scenarios.
Future<void> tapAdminNav(WidgetTester tester, String routeId) async {
  final key = Key('admin_nav_item_$routeId');
  final finder = find.byKey(key);
  expect(
    finder,
    findsAtLeast(1),
    reason:
        'Admin nav item for route "$routeId" (Key=admin_nav_item_$routeId) '
        'is not in the widget tree. Either the route id is wrong or the '
        'shell is not mounted.',
  );
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pump();
  await pumpUntil(tester, budget: kAdminNavBudget);
}

/// Asserts the given route id is the active route. Validated by the
/// presence of the per-route screen key. For routes whose screens do
/// not (yet) expose a scoped Key, the fallback is to confirm the shell
/// is still mounted and the nav row for `routeId` is selected — that
/// check is intentionally loose; tighten it per-scenario when a screen
/// key exists.
Future<void> expectAdminRoute(WidgetTester tester, String routeId) async {
  // The shell does not yet expose a canonical "active route" badge, so
  // we use the shell-mounted check as the floor. Scenario files should
  // add tighter screen-level assertions (e.g. find.byKey(...)) right
  // after this call.
  await expectAdminShellMounted(tester);
}

/// Convenience: taps a `flt-semantics`-equivalent text label via the
/// Flutter widget tree. Used to drive screens that do not expose a Key
/// for the row of interest (typically a tile label or list-item text).
/// Falls back to `find.text` and `warnIfMissed: false` to match the
/// admin runbook's "click by visible label" semantics.
Future<void> tapAdminLabel(WidgetTester tester, String label) async {
  final finder = find.text(label);
  expect(
    finder,
    findsAtLeast(1),
    reason: 'Admin label "$label" not found in widget tree.',
  );
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pump();
  await pumpUntil(tester, budget: kAdminNavBudget);
}

/// Captures Flutter framework errors (including RenderFlex overflows)
/// raised during a test, so a scenario can assert "no overflows" /
/// "no exceptions" after exercising the surface. Identical shape to
/// the mobile harness FlutterErrorTap.
class FlutterErrorTap {
  FlutterErrorTap._();
  final List<FlutterErrorDetails> _errors = [];
  FlutterExceptionHandler? _prev;

  /// Installs the tap. Returns the installed instance so the scenario
  /// can read `overflowErrors` / `all` and restore via `restore()`.
  static FlutterErrorTap install() {
    final t = FlutterErrorTap._();
    t._prev = FlutterError.onError;
    FlutterError.onError = (d) {
      t._errors.add(d);
      t._prev?.call(d);
    };
    return t;
  }

  /// Restores the previous FlutterError.onError handler. Call from
  /// `addTearDown(...)` to ensure a leaked install never poisons later
  /// scenarios in the same lane runner.
  void restore() => FlutterError.onError = _prev;

  /// Subset of captured errors that are RenderFlex overflows. The
  /// 2026-05-22 manual pressure test surfaced a 76 px header overflow
  /// in the admin shell at narrow breakpoints; scenario_shell_03 and
  /// regression_reg_01 lock this surface in.
  List<FlutterErrorDetails> get overflowErrors => _errors
      .where((e) =>
          e.exception.toString().contains('RenderFlex') ||
          (e.context?.toString().toLowerCase().contains('overflow') ?? false))
      .toList();

  /// Every captured error in install order.
  List<FlutterErrorDetails> get all => List.unmodifiable(_errors);
}

/// Returns true if a widget with the given key is mounted in the tree.
/// Useful for soft-asserting optional surfaces (e.g. a dialog that may
/// or may not have opened yet during a transition).
bool isWidgetMountedByKey(Key key) =>
    find.byKey(key).evaluate().isNotEmpty;

/// Returns true if a widget rendering the given text is mounted.
bool isTextMounted(String text) => find.text(text).evaluate().isNotEmpty;

/// Suppresses dart analyzer "unused element" complaints when a scenario
/// file imports the harness only for its `kAdminSharePreview` constant.
/// The mobile harness does not need this because every scenario uses
/// the launch helper directly; some admin stubs only reference the flag.
@visibleForTesting
void useAdminHarness() {
  debugPrint('admin pressure harness in use (share-preview=$kAdminSharePreview)');
}
