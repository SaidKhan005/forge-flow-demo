// Shift UX — whole-day primary-driver chip + daypart header de-dup.
//
// Operator walkthrough 2026-05-16, two binding findings, ONE file
// (`lib/screens/shift_dashboard.dart`):
//
//   Item 2 — Whole-day Shift was missing the primary-driver chip the
//   daypart lens has. The whole-day read model already resolves the
//   lever through `LeverCards.lookup` (`ShiftDashboardReadModel
//   .buildWholeDay` → `primaryLeverCard`); the chip is additive chrome
//   that displays that already-computed value with the SAME
//   `_DaypartDriverChip` widget, positioned above SHIFT OUTPUTS to
//   mirror where the daypart chip sits relative to its sections (true
//   1:1). It reuses the widget's existing null → "NO PATTERN YET"
//   degraded state (7.58 F-1 / F-6) — no new chip, no phantom.
//
//   Item 1 — The daypart header announced the selected period twice:
//   once via the `_ShiftPeriodSelector` pill (canonical switcher) and
//   again via the in-header shortLabel pill + duplicated full label.
//   The duplicate identity block is removed; the plain header keeps
//   ONLY the clock window (time range) and the driver chip — the
//   things the selector does NOT convey. The tri-state status line was
//   removed (operator instruction 2026-05-16).
//
// Pins:
//   1. Whole-day lens renders the primary-driver chip with the
//      read-model-resolved lever label (no toggle).
//   2. Whole-day always determines a lever → a real driver, never the
//      "NO PATTERN YET" phantom (Metric Honesty / Design Rule 2).
//   3. The SAME `_DaypartDriverChip` degraded state ("NO PATTERN YET",
//      no phantom number/real lever) renders when its card is null —
//      exercised via the daypart empty-bucket path, the same widget
//      whole-day reuses.
//   4. Whole-day chip sits ABOVE the SHIFT OUTPUTS section (mirrors the
//      daypart chip's structural position).
//   5. Daypart header announces the period EXACTLY once — the duplicate
//      shortLabel pill + full label are gone; the plain header keeps
//      only the time range + driver chip (no status verbiage).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
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

ServicePeriodAccumulator _lunchBucket() => const ServicePeriodAccumulator(
      servicePeriodId: 'lunch',
      covers: 100,
      sales: 4200.00,
      fohMinutes: 240,
      bohMinutes: 240,
      fohWageDollars: 80.00,
      bohWageDollars: 100.00,
    );

Map<String, ServicePeriodAccumulator> _bucketsWithLunch() => {
      for (final d in ServicePeriodDefinitionResolver.demoDefinitions)
        d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
      'lunch': _lunchBucket(),
    };

Map<String, ServicePeriodAccumulator> _emptyBuckets() => {
      for (final d in ServicePeriodDefinitionResolver.demoDefinitions)
        d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
    };

Widget _build({
  required ShiftDashboardReadModel readModel,
  required Map<String, ServicePeriodAccumulator> buckets,
  Map<String, DaypartTargetContext> daypartTargets = const {},
}) {
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
        create: (_) => ShiftDashboardNotifier.fromReadModel(readModel),
      ),
      ChangeNotifierProvider<ShiftServicePeriodNotifier>(
        create: (_) => ShiftServicePeriodNotifier.fromBuckets(
          buckets: buckets,
          iana: 'America/St_Johns',
          daypartTargets: daypartTargets,
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

  group('Shift UX — whole-day primary-driver chip (Item 2)', () {
    testWidgets(
      'whole-day lens renders the primary-driver chip with the '
      'read-model-resolved lever label (no toggle)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);
        final rm = _fixtureReadModel();
        // The chip displays the value the read model already resolved
        // through `LeverCards.lookup` — assert that exact label, proving
        // the chip is fed from the whole-day primary lever (not a new
        // computation).
        final short = rm.primaryLeverCard.shortLabel;

        await tester.pumpWidget(
          _build(readModel: rm, buckets: _bucketsWithLunch()),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.textContaining('PRIMARY DRIVER · $short',
              skipOffstage: false),
          findsWidgets,
        );
        // Sanity: whole-day sections still render (chip is additive).
        expect(
          find.text('SHIFT OUTPUTS', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'whole-day always determines a lever → a real driver, never the '
      '"NO PATTERN YET" phantom (Metric Honesty / Design Rule 2)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);
        final rm = _fixtureReadModel();

        await tester.pumpWidget(
          _build(readModel: rm, buckets: _bucketsWithLunch()),
        );
        await tester.pump();
        await tester.pump();

        // Whole-day's `primaryLeverCard` is non-nullable by the
        // `ShiftDashboardReadModel` contract (`LeverCards.lookup(id)!`),
        // so the chip shows a real resolved driver — never the degraded
        // phantom on the authoritative whole-day lens.
        expect(
          find.textContaining('NO PATTERN YET', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'whole-day chip sits ABOVE the SHIFT OUTPUTS section (mirrors the '
      'daypart chip structural position — true 1:1)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);
        final rm = _fixtureReadModel();
        final short = rm.primaryLeverCard.shortLabel;

        await tester.pumpWidget(
          _build(readModel: rm, buckets: _bucketsWithLunch()),
        );
        await tester.pump();
        await tester.pump();

        final chip = find
            .textContaining('PRIMARY DRIVER · $short')
            .first;
        final outputs = find.text('SHIFT OUTPUTS');
        expect(chip, findsOneWidget);
        expect(outputs, findsOneWidget);
        expect(
          tester.getTopLeft(chip).dy,
          lessThan(tester.getTopLeft(outputs).dy),
        );
      },
    );
  });

  group('Shift UX — daypart header de-dup (Item 1)', () {
    testWidgets(
      'daypart header announces the period EXACTLY once — duplicate '
      'shortLabel pill + full label gone; plain header keeps only the '
      'time range + driver chip, no status verbiage',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch active.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);
        final rm = _fixtureReadModel();

        await tester.pumpWidget(
          _build(readModel: rm, buckets: _bucketsWithLunch()),
        );
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // The period identity is announced ONCE — by the selector pill.
        // The retired in-header duplicate (full label 'Lunch' + the
        // 'L' shortLabel pill) must NOT come back.
        expect(
          find.text('Lunch', skipOffstage: false),
          findsOneWidget,
        );

        // The things the selector does NOT convey are preserved — and
        // ONLY these (operator instruction 2026-05-16: plain header):
        //  - the clock window (time range)
        //  - the primary-driver chip
        // The tri-state status line ("Active now" etc.) was removed.
        expect(
          find.text('Active now', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('11:00 – 15:00', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.textContaining('PRIMARY DRIVER ·', skipOffstage: false),
          findsWidgets,
        );
      },
    );

    testWidgets(
      'daypart null lever → SAME `_DaypartDriverChip` degraded "NO '
      'PATTERN YET" state, no phantom (7.58 F-1 / F-6) — the widget '
      'whole-day reuses',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);
        final rm = _fixtureReadModel();

        // Empty buckets → no in-period evidence → `primaryLeverCardFor`
        // returns null → the SAME chip degrades honestly.
        await tester.pumpWidget(
          _build(readModel: rm, buckets: _emptyBuckets()),
        );
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        expect(
          find.text('PRIMARY DRIVER · NO PATTERN YET',
              skipOffstage: false),
          findsOneWidget,
        );
        // No phantom: the degraded chip never fabricates a $0 driver
        // value or silently falls through to a real lever.
        expect(
          find.textContaining(r'PRIMARY DRIVER · $',
              skipOffstage: false),
          findsNothing,
        );
      },
    );
  });
}
