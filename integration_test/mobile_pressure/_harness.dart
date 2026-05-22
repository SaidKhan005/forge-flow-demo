// integration_test/mobile_pressure/_harness.dart
//
// Full-surface mobile pressure test harness — 2026-05-22.
// Supersedes integration_test/phase_4_emulator/_harness.dart.
//
// Key fix: main_forgeflow.dart boots with requireAuth: true even when
// kDemoMode=true (DemoAuthLoginService source-swap). This harness taps
// 'login_demo_operator_button' to complete the sign-in before asserting
// AppShell.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/main_forgeflow.dart' as ff_app;
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

const bool kDemoMode = bool.fromEnvironment('kDemoMode');

const Duration kBootBudget = Duration(seconds: 45);
const Duration kTabBudget = Duration(seconds: 15);
const Duration kLoginBudget = Duration(seconds: 15);

Future<void> pumpUntil(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  Duration budget = kBootBudget,
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < budget) {
    await tester.pump(step);
    if (!tester.binding.hasScheduledFrame) return;
  }
}

IntegrationTestWidgetsFlutterBinding bootstrapBinding() =>
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

Future<void> launchDemoApp(WidgetTester tester) async {
  if (!kDemoMode) {
    throw StateError(
      'Mobile pressure suite requires --dart-define=kDemoMode=true.',
    );
  }
  await ff_app.main();
  await tester.pump();
  await pumpUntil(tester, budget: const Duration(seconds: 20));

  const demoKey = Key('login_demo_operator_button');
  final sw = Stopwatch()..start();
  while (sw.elapsed < kLoginBudget) {
    if (find.byKey(demoKey).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(demoKey));
      await tester.pump();
      await pumpUntil(tester, budget: kLoginBudget);
      break;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> expectAppShellMounted(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 15),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < budget) {
    if (find.byType(AppShell).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    find.byType(AppShell),
    findsOneWidget,
    reason: 'AppShell never mounted — demo login or SQLite seed failed.',
  );
}

Future<void> tapTab(WidgetTester tester, int index) async {
  final bars = find.byType(BottomNavigationBar);
  expect(bars, findsAtLeast(1), reason: 'BottomNavigationBar not mounted.');
  final bar = tester.widget<BottomNavigationBar>(bars.first);
  bar.onTap?.call(index);
  await tester.pump();
  await pumpUntil(tester, budget: kTabBudget);
}

/// Pumps until the Shift dashboard has resolved out of its loading state —
/// either section headers are visible (data), one of the recognised
/// empty-state headline strings is present, or the body text appears.
///
/// Use this after [tapTab](0) in shift-specific scenarios.
/// Rationale: `_navigateTo(0)` short-circuits when tab 0 is already
/// selected (no `setState` → no Flutter frame), so `pumpUntil` exits
/// after one 100 ms pump — before [ShiftDashboardNotifier._load()]'s
/// async SQLite chain completes.  This helper pumps until the notifier
/// has actually finished regardless of frame scheduling.
Future<void> pumpUntilShiftSettled(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 20),
}) async {
  const kEmptyHeadlines = <String>[
    'NO LIVE SHIFT',
    'LOCKED PLAN UNAVAILABLE',
    'NO DATA',
    'FIRST SYNC PENDING',
    'BACKFILL PENDING',
    'BACKFILL FAILED',
    'BACKFILL DEAD-LETTERED',
    'HISTORICAL ONLY',
    'IMPORT FAILED',
    'STALE',
    'CURRENT',
    'DEMO',
  ];
  const kBodyStrings = <String>[
    'No open or projected shift is available.',
    'No locked weekly plan is available for the current week.',
  ];

  final sw = Stopwatch()..start();
  while (sw.elapsed < budget) {
    if (find.text('SHIFT OUTPUTS').evaluate().isNotEmpty) return;
    if (kEmptyHeadlines.any((h) => find.text(h).evaluate().isNotEmpty)) return;
    if (kBodyStrings.any((b) => find.text(b).evaluate().isNotEmpty)) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> tapSettingsTab(WidgetTester tester, int index) async {
  final bars = find.byType(BottomNavigationBar);
  expect(bars, findsAtLeast(1));
  final bar = tester.widget<BottomNavigationBar>(bars.last);
  bar.onTap?.call(index);
  await tester.pump();
  await pumpUntil(tester, budget: kTabBudget);
}

/// Navigates back from a pushed screen.
///
/// Forge & Flow screens use [Icons.close] (not a standard [BackButton]) as
/// their [AppBar.leading] widget, so [WidgetTester.pageBack] (which looks
/// for [BackButton] / [CupertinoNavigationBarBackButton]) always fails.
/// This helper taps [Icons.close] first, then falls back to [Icons.arrow_back],
/// then calls [Navigator.pop] programmatically.
Future<void> navigateBack(WidgetTester tester) async {
  final closeBtn = find.byIcon(Icons.close);
  if (closeBtn.evaluate().isNotEmpty) {
    await tester.tap(closeBtn.first, warnIfMissed: false);
  } else {
    final backBtn = find.byIcon(Icons.arrow_back);
    if (backBtn.evaluate().isNotEmpty) {
      await tester.tap(backBtn.first, warnIfMissed: false);
    } else {
      // Last resort: programmatic pop.
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
    }
  }
  await tester.pump();
  await pumpUntil(tester, budget: kTabBudget);
}

Future<void> openSettings(WidgetTester tester) async {
  final icon = find.byIcon(Icons.settings_outlined);
  expect(icon, findsAtLeast(1), reason: 'Settings icon not in AppBar.');
  await tester.tap(icon.first);
  await tester.pump();
  await pumpUntil(tester, budget: kTabBudget);
}

void expectShiftDashboard() =>
    expect(find.byType(ShiftDashboard), findsOneWidget);

void expectSettings() =>
    expect(find.byType(SettingsScreen), findsOneWidget);

void expectDemoBanner() =>
    expect(find.byType(DemoModeBanner), findsWidgets);

class FlutterErrorTap {
  FlutterErrorTap._();
  final List<FlutterErrorDetails> _errors = [];
  FlutterExceptionHandler? _prev;

  static FlutterErrorTap install() {
    final t = FlutterErrorTap._();
    t._prev = FlutterError.onError;
    FlutterError.onError = (d) {
      t._errors.add(d);
      t._prev?.call(d);
    };
    return t;
  }

  void restore() => FlutterError.onError = _prev;

  List<FlutterErrorDetails> get overflowErrors => _errors
      .where((e) =>
          e.exception.toString().contains('RenderFlex') ||
          (e.context?.toString().toLowerCase().contains('overflow') ?? false))
      .toList();

  List<FlutterErrorDetails> get all => List.unmodifiable(_errors);
}
