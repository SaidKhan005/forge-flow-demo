// integration_test/mobile_pressure/regression/scenario_reg_01_crashreporter_no_freeze.dart
//
// Lane A — Scenario Reg-01: CrashReporter recursive-freeze regression (PR #754).
//
// SYMPTOM (pre-fix): CrashReporter.initialize() wired FlutterError.onError
// to FirebaseCrashlytics.instance. When Firebase is not initialized (demo mode),
// any Flutter error caused recursive re-entry into CrashReporter's handler,
// which called FirebaseCrashlytics.instance again, froze the engine. Bottom-nav
// taps and hamburger taps silently failed; the clock advanced but the app body
// never updated.
//
// FIX (PR #754): CrashReporter.initialize() is now gated on
// FORGE_FLOW_USE_FIREBASE_AUTH=true (see main_forgeflow.dart:47). In demo mode
// builds (kDemoMode=true, no Firebase app), CrashReporter.initialize() is never
// called, so the handler is never wired. The engine cannot recursively freeze.
//
// This test verifies the fix is still in place by:
//   1. Booting in demo mode with FlutterErrorTap installed.
//   2. Asserting that bottom-nav taps are responsive (no freeze).
//   3. Asserting that no error whose toString includes 'no-app' or
//      'FirebaseCrashlytics' was captured (would indicate the Firebase
//      path was unexpectedly executed).
//
// If the regression returns, tapTab() calls will time out and the test
// will fail with "timed out waiting for BottomNavigationBar tap to settle".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Reg-01: CrashReporter freeze regression — bottom-nav taps responsive in demo mode',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Tap tab 1 (Variance) and assert VarianceReport found.
      // If the CrashReporter freeze is back, this tap silently fails
      // and the tap handler never delivers — the widget tree stays
      // on ShiftDashboard and the assertion fires.
      await tapTab(tester, 1);
      expect(
        find.byType(VarianceReport),
        findsOneWidget,
        reason:
            'Tab 1 (Variance) tap did not result in VarianceReport mounting. '
            'If the CrashReporter freeze regression has returned, bottom-nav '
            'taps silently fail in demo mode.',
      );

      // Tap tab 2 (Plan) and assert ScheduleBuilder found.
      await tapTab(tester, 2);
      expect(
        find.byType(ScheduleBuilder),
        findsOneWidget,
        reason:
            'Tab 2 (Plan) tap did not result in ScheduleBuilder mounting. '
            'CrashReporter freeze regression candidate.',
      );

      // Return to tab 0 (Shift) and assert ShiftDashboard found.
      await tapTab(tester, 0);
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason:
            'Tab 0 (Shift) tap did not result in ShiftDashboard mounting after '
            'round-trip. CrashReporter freeze regression candidate.',
      );

      // Assert no errors include Firebase-related strings.
      // The presence of 'no-app' or 'FirebaseCrashlytics' in any error
      // message would indicate the Firebase path was executed in demo mode,
      // which is the root cause of the PR #754 regression.
      final firebaseErrors = errorTap.all.where((e) {
        final msg = e.exception.toString().toLowerCase();
        return msg.contains('no-app') || msg.contains('firebasecrashlytics');
      }).toList();

      expect(
        firebaseErrors,
        isEmpty,
        reason:
            'Firebase-related error detected in demo mode build: '
            '${firebaseErrors.map((e) => e.exception).join(', ')}. '
            'This suggests CrashReporter.initialize() was called without '
            'FORGE_FLOW_USE_FIREBASE_AUTH=true — see main_forgeflow.dart:30.',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
