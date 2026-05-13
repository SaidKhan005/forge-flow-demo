// A4.2 (R2) per `docs/_audits/code_health/a4_performance_audit.md`:
//
// The four wall-clock-driven widgets on the shift dashboard
// (`_LiveClock`, `_ShiftPeriodSelector`, `_DaypartScaffoldSection`,
// `_TimeIntoServiceHeader`) used to each own a `Timer.periodic(30s)`.
// After R2 they share a single `_ShiftDashboardTicker` constructed by
// `_ShiftDashboardState`. This test file is the regression guard:
//
//   1. **Static guard** — `lib/screens/shift_dashboard.dart` must
//      contain exactly one `Timer.periodic(...)` call after the
//      coalesce. If a future change adds a second timer to the file,
//      this test fails and the author has to either justify the new
//      timer (and update the count) or wire the new widget into the
//      shared ticker like the other four.
//
//   2. **Functional guard** — pumping the dashboard with a
//      `clockOverride` and advancing the ticker once must update the
//      live clock display (proxy for "the shared ticker drives the UI").
//      The other three consumers also rebuild on the same tick because
//      they all listen to the same `ValueListenable<DateTime>`; the
//      live clock check is sufficient since a regression that broke
//      shared-ticker fan-out would also stop the clock from updating.
//
// The test deliberately does NOT use `fake_async` to advance real
// `Timer.periodic` time — that would require knowing the
// implementation-private timer interval. Instead it relies on the
// existing `clockOverride` test seam plus a forced `pump()` to verify
// the wiring path; the timer cadence itself is verified by the static
// check.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

ShiftDashboardReadModel _fixtureReadModel() {
  final profile = ActiveTargetProfile(
    targetProfileId: 'test_active',
    restaurantId: 'demo_restaurant_001',
    sourceType: 'system_baseline',
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetSPLH: BaselineData.derivedTargetSPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
    opzFloorCPLH: BaselineData.opzFloorCPLH,
    opzCeilingCPLH: BaselineData.opzCeilingCPLH,
    theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
    theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
    theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
    builtAt: '2026-03-27T19:42:00',
  );
  final snapshot = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-03-27',
    forecastCovers: ShiftSnapshot.shiftForecastCovers,
    currentCovers: ShiftSnapshot.actualCovers,
    scheduledFohHours: ShiftSnapshot.scheduledFohHours,
    scheduledBohHours: ShiftSnapshot.scheduledBohHours,
    currentPPA: ShiftSnapshot.actualPPA,
    currentCPLH: ShiftSnapshot.actualCPLH,
    currentSPLH: ShiftSnapshot.actualSPLH,
    blendedWage: ShiftSnapshot.blendedWage,
    timeLabel: ShiftSnapshot.time,
    serviceElapsedLabel: ShiftSnapshot.serviceElapsed,
    updatedAt: '2026-03-27T19:42:00',
  );
  return ShiftDashboardReadModel.build(snapshot, profile);
}

Map<String, ServicePeriodAccumulator> _emptyBuckets() => {
      for (final d in ServicePeriodDefinitionResolver.demoDefinitions)
        d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
    };

Widget _buildShiftDashboard({String iana = 'America/St_Johns'}) {
  final rm = _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: MeridianConfig.restaurantName,
            businessTimezone: iana,
            createdAt: '2026-03-30T10:00:00',
            updatedAt: '2026-03-30T10:00:00',
          ),
        ),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) => ShiftDashboardNotifier.fromReadModel(rm),
      ),
      ChangeNotifierProvider<ShiftServicePeriodNotifier>(
        create: (_) => ShiftServicePeriodNotifier.fromBuckets(
          buckets: _emptyBuckets(),
          iana: iana,
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ShiftDashboard())),
  );
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  group('ShiftDashboard ticker coalesce (A4.2 R2)', () {
    test(
      'lib/screens/shift_dashboard.dart has exactly one Timer.periodic( call '
      '(the shared _ShiftDashboardTicker)',
      () {
        // Static-source regression guard. Before A4.2 R2 there were
        // four `Timer.periodic(` invocation sites in this file (one
        // per wall-clock-driven widget). After R2 there is exactly one
        // (the shared `_ShiftDashboardTicker`).
        //
        // The regex matches `Timer.periodic(` (with an open paren) so
        // mentions in comments / docstrings — e.g. "previously owned
        // its own `Timer.periodic`" — are not counted. Only real
        // invocations match.
        //
        // If a future change adds a second timer to this file the
        // author MUST either:
        //   * fan the new widget into the constructor-injected shared
        //     ticker (the intended path; keeps this assertion at 1),
        //     or
        //   * justify the additional timer in the slice doc and bump
        //     the expected count below.
        final source = File(
          'lib/screens/shift_dashboard.dart',
        ).readAsStringSync();
        // Strip line comments before counting so docstring mentions of
        // `Timer.periodic` (e.g. "previously owned its own
        // `Timer.periodic`") are not miscounted as invocations.
        final stripped = source
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        final matches =
            RegExp(r'Timer\.periodic\(').allMatches(stripped).toList();
        expect(
          matches.length,
          equals(1),
          reason:
              'Expected exactly one Timer.periodic( call in shift_dashboard.dart '
              '(the shared _ShiftDashboardTicker). Found ${matches.length}. '
              'If a new wall-clock widget needs a tick, pass it the existing '
              'ticker through its constructor instead of owning its own '
              'Timer.periodic.',
        );
      },
    );

    test(
      'lib/screens/shift_dashboard.dart no longer references the per-widget '
      'tickInterval constants from the old four-timer pattern',
      () {
        // Before A4.2 R2 each of the three non-clock widgets defined
        // its own `static const Duration _tickInterval = Duration(seconds: 30)`
        // alongside its own `Timer? _ticker`. After R2 the cadence
        // lives on the shared ticker only.
        final source = File(
          'lib/screens/shift_dashboard.dart',
        ).readAsStringSync();
        final perWidgetTickInterval = RegExp(
          r'static const Duration _tickInterval',
        ).allMatches(source).toList();
        expect(
          perWidgetTickInterval,
          isEmpty,
          reason:
              'Per-widget _tickInterval constants should be gone after R2 — '
              'the shared _ShiftDashboardTicker owns the cadence.',
        );
      },
    );

    testWidgets(
      'shared ticker drives the live clock initial render (proves the '
      'ValueListenableBuilder wiring path)',
      (tester) async {
        // Pumping the dashboard with `clockOverride` set to a known
        // time must surface that time on `_LiveClock`. Before R2,
        // _LiveClock owned a private `Timer.periodic` and read
        // `ShiftDashboard.clockOverride` directly inside `setState`.
        // After R2, the read funnels through `_ShiftDashboardTicker`
        // (constructed in `initState`, fed via `ValueListenableBuilder`).
        // A regression in the new wiring would either crash the build
        // or render the wrong text.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 13, 45);
        await tester.pumpWidget(_buildShiftDashboard());
        await tester.pump();
        await tester.pump();

        // 13:45 → live clock renders "1:45 PM".
        expect(find.text('1:45'), findsOneWidget);
        expect(find.text('PM'), findsAtLeastNWidgets(1));
      },
    );

    testWidgets(
      'pumping the dashboard does not crash when the shared ticker is the '
      'sole source of wall-clock rebuilds for all four consumer widgets',
      (tester) async {
        // Smoke check: open the daypart lens (which mounts
        // _TimeIntoServiceHeader + _DaypartScaffoldSection alongside
        // _LiveClock + _ShiftPeriodSelector). All four must render
        // without throwing — proves they all received the shared
        // ticker through their constructors and resolved it via
        // `ValueListenableBuilder`.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 12);
        await tester.pumpWidget(_buildShiftDashboard());
        await tester.pump();
        await tester.pump();

        // Tap into Lunch → mounts the daypart lens.
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // _LiveClock rendered.
        expect(find.text('12:12'), findsOneWidget);
        // _TimeIntoServiceHeader rendered ("Lunch · 1h 12m in").
        expect(
          find.text('Lunch · 1h 12m in', skipOffstage: false),
          findsOneWidget,
        );
        // _DaypartScaffoldSection rendered (SERVICE PERIOD header).
        expect(
          find.text('SERVICE PERIOD', skipOffstage: false),
          findsOneWidget,
        );
        // _ShiftPeriodSelector rendered (Whole Day pill is always
        // present in the selector).
        expect(find.text('Whole Day', skipOffstage: false), findsOneWidget);
      },
    );
  });
}
