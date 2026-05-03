// Phase 10.5.0 — daypart toggle scaffold tests.
//
// Asserts:
//   1. Whole-day Shift remains the default and the source of truth
//      (existing SHIFT OUTPUTS / INPUTS / FOH PRODUCTIVITY sections render).
//   2. The new daypart toggle is exposed alongside whole-day, never
//      replacing it (Hard Promise: Shift's whole-day view is authoritative).
//   3. Switching to the daypart lens opens the SERVICE PERIODS scaffold
//      with one card per restaurant-scoped service-period definition
//      and surfaces an ACTIVE NOW chip for the period containing the
//      live clock.
//   4. Switching back to whole-day restores the authoritative view.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
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

Widget _buildShiftDashboard() {
  final rm = _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: MeridianConfig.restaurantName,
            businessTimezone: 'America/St_Johns',
            createdAt: '2026-03-30T10:00:00',
            updatedAt: '2026-03-30T10:00:00',
          ),
        ),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) => ShiftDashboardNotifier.fromReadModel(rm),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  group('ShiftDashboard daypart toggle (10.5.0)', () {
    testWidgets('defaults to whole-day; both pills render', (tester) async {
      // Friday 2026-03-27 8:30 PM (Dinner window is open) so the
      // ACTIVE NOW chip would surface IF the daypart lens were active.
      // It must not, because whole-day is the default.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 27, 20, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      // Authoritative whole-day sections are present.
      expect(find.text('SHIFT OUTPUTS', skipOffstage: false),
          findsOneWidget);
      expect(find.text('SHIFT INPUTS', skipOffstage: false),
          findsOneWidget);
      expect(find.text('FOH PRODUCTIVITY', skipOffstage: false),
          findsOneWidget);

      // Both scope pills render (toggle is alongside, not a replacement).
      expect(find.text('Whole Day', skipOffstage: false), findsOneWidget);
      expect(find.text('Daypart', skipOffstage: false), findsOneWidget);

      // Daypart scaffold is NOT visible by default.
      expect(find.text('SERVICE PERIODS', skipOffstage: false),
          findsNothing);
      expect(find.text('Lunch', skipOffstage: false), findsNothing);
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsNothing);
    });

    testWidgets('tapping Daypart opens the SERVICE PERIODS scaffold',
        (tester) async {
      // Tuesday 2026-03-31 12:30 — Lunch is the active period
      // (Lunch 11:00–15:00, applicable Mon–Fri).
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      // Whole-day sections are gone — daypart lens is the active view.
      expect(find.text('SHIFT OUTPUTS', skipOffstage: false), findsNothing);
      expect(find.text('SHIFT INPUTS', skipOffstage: false), findsNothing);
      expect(
          find.text('FOH PRODUCTIVITY', skipOffstage: false), findsNothing);

      // Daypart scaffold is visible.
      expect(find.text('SERVICE PERIODS', skipOffstage: false),
          findsOneWidget);

      // All three demo definitions render with their clock windows.
      expect(find.text('Lunch', skipOffstage: false), findsOneWidget);
      expect(find.text('Dinner', skipOffstage: false), findsOneWidget);
      expect(find.text('Late Night', skipOffstage: false), findsOneWidget);
      expect(find.text('11:00 – 15:00', skipOffstage: false),
          findsOneWidget);
      expect(find.text('17:00 – 23:00', skipOffstage: false),
          findsOneWidget);
      expect(find.text('23:00 – 02:00', skipOffstage: false),
          findsOneWidget);

      // 10.5.2 replaces the 10.5.0 "build out in upcoming 10.5 slices"
      // banner with live per-period accumulator metrics on each card.
      // The banner is intentionally gone — the per-period read service
      // is the deliverable. The empty-state placeholder
      // ("No data yet for this period.") replaces it for buckets the
      // notifier hasn't filled yet.

      // Active period chip surfaces exactly once — Lunch is live.
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);
    });

    testWidgets('tapping Whole Day restores the authoritative sections',
        (tester) async {
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      // Open daypart lens.
      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();
      expect(find.text('SERVICE PERIODS', skipOffstage: false),
          findsOneWidget);

      // Tap Whole Day to restore the authoritative view.
      await tester.tap(find.text('Whole Day', skipOffstage: false));
      await tester.pump();

      expect(find.text('SHIFT OUTPUTS', skipOffstage: false),
          findsOneWidget);
      expect(find.text('SHIFT INPUTS', skipOffstage: false),
          findsOneWidget);
      expect(find.text('FOH PRODUCTIVITY', skipOffstage: false),
          findsOneWidget);
      expect(find.text('SERVICE PERIODS', skipOffstage: false),
          findsNothing);
    });

    testWidgets('no ACTIVE NOW chip when the clock is between periods',
        (tester) async {
      // Tuesday 2026-03-31 16:00 — outside Lunch (11:00–15:00) and
      // before Dinner (17:00–23:00). No period is active.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 16, 0);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      expect(find.text('SERVICE PERIODS', skipOffstage: false),
          findsOneWidget);
      expect(find.text('Lunch', skipOffstage: false), findsOneWidget);
      expect(find.text('Dinner', skipOffstage: false), findsOneWidget);
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsNothing);
    });

    testWidgets(
        'Late Night ACTIVE NOW surfaces post-midnight on rolls-past-midnight days',
        (tester) async {
      // Saturday 2026-03-28 01:30 calendar — with the 04:00 business-day
      // cutoff this is still Friday's business day (weekday 5 = Fri),
      // and Late Night is applicable Fri/Sat. The post-midnight portion
      // belongs to the prior business date per the time-boundary contract.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 28, 1, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      // Late Night is the only active period.
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);
      // Sanity: the Late Night card is present.
      expect(find.text('Late Night', skipOffstage: false), findsOneWidget);
    });

    testWidgets(
        'ACTIVE chip uses business-date weekday, not wall-clock weekday '
        '(Sun 01:30 calendar = Sat business day)',
        (tester) async {
      // Sunday 2026-03-29 01:30 calendar. Wall weekday is 7 (Sun) and
      // Late Night's applicableDays = [5, 6] (Fri, Sat) — under the
      // previous device-clock implementation the chip would have
      // silently disappeared at the calendar rollover. With the
      // BusinessDateResolver wiring in place, the 04:00 cutoff makes
      // this Saturday's business day (weekday 6), so Late Night is
      // still active. This is the regression test for P2 #1.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 29, 1, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);
      expect(find.text('Late Night', skipOffstage: false), findsOneWidget);
    });

    testWidgets(
        'ACTIVE chip refreshes on the periodic ticker when the clock '
        'crosses a service-period boundary',
        (tester) async {
      // Tuesday 2026-03-31. Start at 14:55 (Lunch active 11:00–15:00),
      // advance the source-of-truth clock past Lunch end to 15:01
      // (no period applies), then pump > 30 s of virtual time to fire
      // the scaffold's Timer.periodic. This is the regression test for
      // P2 #2 — the chip must follow the live clock without an
      // external rebuild.
      var simulatedNow = DateTime(2026, 3, 31, 14, 55);
      ShiftDashboard.clockOverride = () => simulatedNow;

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      // 14:55 — Lunch is the active period.
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);

      // Advance the simulated clock past the Lunch boundary; do NOT
      // toggle scope, refresh, or otherwise force an external rebuild.
      simulatedNow = DateTime(2026, 3, 31, 15, 1);
      await tester.pump(const Duration(seconds: 31));

      // 15:01 — between Lunch and Dinner; the ticker must have fired
      // and re-evaluated the active period. No chip should remain.
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsNothing);

      // Advance into Dinner (17:00 start) on the same business day.
      simulatedNow = DateTime(2026, 3, 31, 17, 5);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);
    });

    testWidgets(
        'no ACTIVE chip when restaurant scope has no usable IANA '
        'timezone and clockOverride is unset',
        (tester) async {
      // Build a dashboard with a restaurant that has an empty IANA
      // timezone string. With clockOverride deliberately null, the
      // scaffold has no honest source-of-truth clock, so per the
      // boundary-monitor contract no ACTIVE chip surfaces.
      ShiftDashboard.clockOverride = null;
      final rm = _fixtureReadModel();
      final widget = MultiProvider(
        providers: [
          ChangeNotifierProvider<RestaurantScopeNotifier>(
            create: (_) => RestaurantScopeNotifier.fromRestaurant(
              RestaurantLocation(
                restaurantId: 'demo_restaurant_001',
                displayName: MeridianConfig.restaurantName,
                businessTimezone: '', // intentionally missing
                createdAt: '2026-03-30T10:00:00',
                updatedAt: '2026-03-30T10:00:00',
              ),
            ),
          ),
          ChangeNotifierProvider<ShiftDashboardNotifier>(
            create: (_) => ShiftDashboardNotifier.fromReadModel(rm),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ShiftDashboard()),
        ),
      );

      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Daypart', skipOffstage: false));
      await tester.pump();

      // The cards still render; no ACTIVE chip surfaces because the
      // scaffold refuses to fall back to the device clock.
      expect(find.text('Lunch', skipOffstage: false), findsOneWidget);
      expect(find.text('Dinner', skipOffstage: false), findsOneWidget);
      expect(find.text('Late Night', skipOffstage: false), findsOneWidget);
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsNothing);
    });
  });
}
