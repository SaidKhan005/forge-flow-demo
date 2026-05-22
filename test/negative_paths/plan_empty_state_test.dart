// Negative-path empty-state widget test: ScheduleBuilder screen.
//
// Mounts ScheduleBuilder.testContent with a ScheduleForecastNotifier that
// has no plan data (plan == null, locked mode, loadLockedPlan not called).
// The widget renders '--' values in the header stats and the three section
// labels in an honest degraded state.
//
// Asserts:
//   - Widget mounts without throwing
//   - No RenderFlex overflow
//   - Some content renders (section labels or header text)
//
// Uses ScheduleBuilder.testContent() — the @visibleForTesting factory that
// bypasses the 3-provider proxy and mounts _ScheduleBuilderContent directly.
// No SQLite setup is needed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

import '../_test_helpers/widget_pump_helpers.dart';

// ── Minimal test profile using config-default values ─────────────────────────

const _kTestProfile = ActiveTargetProfile(
  targetProfileId: 'plan-empty-state-test',
  restaurantId: 'test-restaurant',
  sourceType: 'system_baseline',
  targetCPLH: MeridianConfig.targetCPLH,
  targetSPLH: MeridianConfig.targetSPLH,
  targetPPA: 42.0,
  fohWage: MeridianConfig.fohWage,
  bohWage: MeridianConfig.bohWage,
  opzFloorCPLH: MeridianConfig.opzFloorCPLH,
  opzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
  theoreticalFohLaborPct: MeridianConfig.fohTheoreticalLaborPct,
  theoreticalBohLaborPct: MeridianConfig.bohTheoreticalLaborPct,
  theoreticalLaborPct: MeridianConfig.totalTheoreticalLaborPct,
  builtAt: 'test',
);

// ── Helper ────────────────────────────────────────────────────────────────────

Widget _buildSubject(ScheduleForecastNotifier notifier) {
  return MaterialApp(
    home: Scaffold(body: ScheduleBuilder.testContent(notifier)),
  );
}

void main() {
  group('ScheduleBuilder — empty state (plan == null, locked mode)', () {
    late ScheduleForecastNotifier notifier;

    setUp(() {
      // Locked-authority constructor: _plan stays null until loadLockedPlan()
      // is called. We deliberately skip that call so the widget sees an empty
      // plan (lockedPlanLoadState == idle, hasPlan == false).
      notifier = ScheduleForecastNotifier.lockedAuthority(
        profile: _kTestProfile,
        benchmarkResolved: false,
      );
    });

    tearDown(() {
      notifier.dispose();
    });

    testWidgets('mounts without throwing', (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);
      // No exception == pass.
    });

    testWidgets('no RenderFlex overflow error', (tester) async {
      final overflowErrors = <String>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        final msg = details.toString();
        if (msg.contains('RenderFlex overflowed')) {
          overflowErrors.add(msg);
        } else {
          originalOnError?.call(details);
        }
      };

      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);

      FlutterError.onError = originalOnError;
      expect(overflowErrors, isEmpty,
          reason: 'No RenderFlex overflow expected on empty Plan screen');
    });

    testWidgets('section labels or header text renders', (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);

      // When the plan is null the header shows '--' for numeric stats but
      // the section labels are always present (LABOR PLAN, COVER FORECAST
      // ADJUSTED BY DAY, DAY-BY-DAY PLAN) per the existing tests.
      final hasLaborPlan =
          find.text('LABOR PLAN', skipOffstage: false).evaluate().isNotEmpty;
      final hasCoverForecast =
          find.text('COVER FORECAST ADJUSTED BY DAY', skipOffstage: false)
              .evaluate()
              .isNotEmpty;
      final hasDayByDay =
          find.text('DAY-BY-DAY PLAN', skipOffstage: false)
              .evaluate()
              .isNotEmpty;
      final hasDashes = find.text('--').evaluate().isNotEmpty;

      expect(
        hasLaborPlan || hasCoverForecast || hasDayByDay || hasDashes,
        isTrue,
        reason: 'Expected section labels or "--" placeholders on empty Plan screen',
      );
    });
  });
}
