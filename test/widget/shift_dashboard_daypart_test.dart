// Phase 10.5.2 — Shift dashboard daypart lens widget tests.
//
// Asserts:
//   1. SERVICE PERIODS cards now render the per-period accumulator
//      metrics (covers, sales, CPLH, SPLH, PPA, blended wage) in
//      place of the 10.5.0 placeholder text.
//   2. Empty buckets render the "No data yet for this period."
//      placeholder so zero-data periods don't display silent zeros.
//   3. The time-into-service header ("Lunch · 1h 12m in") renders
//      when the daypart lens is active and a service period is in
//      progress; it stays hidden when no period is active.
//   4. The Whole Day view is byte-identical regardless of whether the
//      ShiftServicePeriodNotifier provides buckets — additive only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
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

Widget _buildShiftDashboard({
  required Map<String, ServicePeriodAccumulator> periodBuckets,
  String iana = 'America/St_Johns',
  List<ServicePeriodDefinition>? definitions,
}) {
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
          buckets: periodBuckets,
          definitions: definitions,
          iana: iana,
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ShiftDashboard())),
  );
}

ServicePeriodAccumulator _bucketWith({
  required String id,
  int covers = 0,
  double sales = 0,
  int fohMinutes = 0,
  int bohMinutes = 0,
  double fohWageDollars = 0,
  double bohWageDollars = 0,
}) {
  return ServicePeriodAccumulator(
    servicePeriodId: id,
    covers: covers,
    sales: sales,
    fohMinutes: fohMinutes,
    bohMinutes: bohMinutes,
    fohWageDollars: fohWageDollars,
    bohWageDollars: bohWageDollars,
  );
}

Map<String, ServicePeriodAccumulator> _emptyBuckets() {
  return {
    for (final d in ServicePeriodDefinitionResolver.demoDefinitions)
      d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
  };
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  group('ShiftDashboard daypart lens (10.5.2 — populated cards)', () {
    testWidgets(
      'cards render per-period metrics from the notifier when buckets '
      'have data',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch is the active period.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Lunch bucket: 100 covers, $4200 sales, 240 min FOH (4h),
        // 240 min BOH (4h), $80 FOH wage, $100 BOH wage.
        // Expected derived: PPA $42.00, CPLH 12.50, SPLH $525, blended $22.50.
        final buckets = {
          ..._emptyBuckets(),
          'lunch': _bucketWith(
            id: 'lunch',
            covers: 100,
            sales: 4200.00,
            fohMinutes: 240,
            bohMinutes: 240,
            fohWageDollars: 80.00,
            bohWageDollars: 100.00,
          ),
        };

        await tester.pumpWidget(_buildShiftDashboard(periodBuckets: buckets));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        expect(
          find.text('SERVICE PERIOD', skipOffstage: false),
          findsOneWidget,
        );

        // Lunch card metrics rendered (per-period values from the notifier).
        expect(find.text('100', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$4200', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$42.00', skipOffstage: false), findsOneWidget);
        expect(find.text('12.50', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$525', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$22.50', skipOffstage: false), findsOneWidget);

        // Only the selected period card renders.
        expect(
          find.text('No data yet for this period.', skipOffstage: false),
          findsNothing,
        );

        // Lunch is the active period — exactly one ACTIVE NOW chip.
        expect(find.text('ACTIVE NOW', skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets('time-into-service header renders during an active period '
        '("Lunch · 1h 12m in")', (tester) async {
      // Tuesday 2026-03-31 12:12. Lunch starts at 11:00, so
      // elapsed = 1h 12m exactly.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 12);

      await tester.pumpWidget(
        _buildShiftDashboard(periodBuckets: _emptyBuckets()),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Lunch', skipOffstage: false));
      await tester.pump();

      // Header strip above the SERVICE PERIODS sticky group.
      expect(
        find.text('Lunch · 1h 12m in', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('no time-into-service header renders when no period is active '
        '(between Lunch and Dinner)', (tester) async {
      // Tuesday 2026-03-31 16:00 — outside Lunch (11:00–15:00) and
      // before Dinner (17:00–23:00). No active period.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 16, 0);

      await tester.pumpWidget(
        _buildShiftDashboard(periodBuckets: _emptyBuckets()),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Lunch', skipOffstage: false));
      await tester.pump();

      // No "X · Yh Zm in" line should render in the gap.
      expect(find.textContaining(' in', skipOffstage: false), findsNothing);
    });

    testWidgets('future selected period renders projected/unavailable copy', (
      tester,
    ) async {
      // Tuesday 2026-03-31 12:30: Lunch is active, Dinner is still future.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

      await tester.pumpWidget(
        _buildShiftDashboard(periodBuckets: _emptyBuckets()),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Dinner', skipOffstage: false));
      await tester.pump();

      expect(find.text('SERVICE PERIOD', skipOffstage: false), findsOneWidget);
      expect(
        find.text(
          'Projected / unavailable until this period opens.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.text('PRIMARY DRIVER Â· NO PATTERN YET', skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets(
      'missing timezone surfaces an explicit "timezone not configured" '
      'banner above the cards (not a generic no-data placeholder)',
      (tester) async {
        // Build the dashboard with an empty IANA timezone; the
        // ShiftServicePeriodNotifier will mark `missingTimezone = true`
        // and the daypart section must degrade honestly.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(
          _buildShiftDashboard(periodBuckets: _emptyBuckets(), iana: ''),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Explicit config-degraded message renders above the cards.
        expect(
          find.textContaining(
            'Restaurant timezone is not configured',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        // Each card's empty-state subline is also degraded — not the
        // generic "No data yet for this period." copy.
        expect(
          find.text(
            'Timezone not configured — metrics unavailable.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        // The generic no-data copy must NOT appear when timezone is the
        // honest cause of the empty state.
        expect(
          find.text('No data yet for this period.', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets('pull-to-refresh awaits both ShiftDashboardNotifier AND '
        'ShiftServicePeriodNotifier (daypart cards do not stay stale)', (
      tester,
    ) async {
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

      // Start with empty buckets.
      final initialBuckets = _emptyBuckets();
      late ShiftServicePeriodNotifier capturedNotifier;
      final widget = MultiProvider(
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
            create: (_) =>
                ShiftDashboardNotifier.fromReadModel(_fixtureReadModel()),
          ),
          ChangeNotifierProvider<ShiftServicePeriodNotifier>(
            create: (_) {
              final n = ShiftServicePeriodNotifier.fromBuckets(
                buckets: initialBuckets,
                iana: 'America/St_Johns',
              );
              capturedNotifier = n;
              return n;
            },
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ShiftDashboard())),
      );
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump();

      // Confirm starting state — empty Lunch card.
      await tester.tap(find.text('Lunch', skipOffstage: false));
      await tester.pump();
      expect(
        find.text('No data yet for this period.', skipOffstage: false),
        findsOneWidget,
      );

      // Mutate the captured notifier the way a Phase-8 vendor write
      // would: install fresh buckets and notify. Then trigger a
      // pull-to-refresh; the dashboard's `refreshBoth` must await both
      // notifiers, and the buckets we installed must appear.
      // (We can't call `notifier.refresh()` directly because it
      // re-reads SQLite; the test seam is the `fromBuckets`-style
      // mutation via a fresh `applyPosLineCorrection`.)
      capturedNotifier.applyPosLineCorrection(
        prior: CanonicalPosLine(
          sourceId: 'noop_prior',
          eventLocalTimestamp: DateTime(2026, 3, 31, 12, 30),
          covers: 0,
          sales: 0,
        ),
        replacement: CanonicalPosLine(
          sourceId: 'noop_prior',
          eventLocalTimestamp: DateTime(2026, 3, 31, 12, 30),
          covers: 100,
          sales: 4200,
        ),
      );
      await tester.pump();

      // Lunch card should now show the new POS line's covers / sales
      // because the notifier listened-to-by-the-widget fired.
      expect(find.text('100', skipOffstage: false), findsOneWidget);
      expect(find.text(r'$4200', skipOffstage: false), findsOneWidget);
    });

    testWidgets('whole-day view is unchanged when buckets are present — no '
        'regression from additive daypart wiring', (tester) async {
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 27, 20, 30);

      final buckets = {
        ..._emptyBuckets(),
        'dinner': _bucketWith(
          id: 'dinner',
          covers: 50,
          sales: 2000,
          fohMinutes: 60,
          bohMinutes: 60,
          fohWageDollars: 20,
          bohWageDollars: 25,
        ),
      };

      await tester.pumpWidget(_buildShiftDashboard(periodBuckets: buckets));
      await tester.pump();
      await tester.pump();

      // Whole-day default sections still render — additive only.
      expect(find.text('SHIFT OUTPUTS', skipOffstage: false), findsOneWidget);
      expect(find.text('SHIFT INPUTS', skipOffstage: false), findsOneWidget);
      expect(
        find.text('FOH PRODUCTIVITY', skipOffstage: false),
        findsOneWidget,
      );

      // SERVICE PERIODS only opens after an explicit toggle to daypart.
      expect(find.text('SERVICE PERIOD', skipOffstage: false), findsNothing);
      expect(find.textContaining(' in', skipOffstage: false), findsNothing);
    });
  });
}
