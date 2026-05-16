// Per-Daypart Targets V1 — Slice 4: Shift daypart card full parity.
//
// Pins Decision 7 (full 1:1 mirror of the whole-day card) + Promise 2
// (closed truth keeps its own per-shift stamp) + Design Rule 2 (missing
// = "—", never a 0 sentinel):
//
//   1. Three-section parity render — OUTPUTS / INPUTS / FOH PRODUCTIVITY
//      all present, scoped to the selected period.
//   2. Closed-shift stamp read-back — the locked per-period target
//      sub-lines + OPZ band come from the injected closed-shift stamp
//      context (`source: 'closed_stamp'`).
//   3. Open-shift profile fallback — when the period has not closed,
//      the active profile's per-period row drives the target sub-lines.
//   4. Null / empty honest state — no per-period target context renders
//      "Target —" and the "no locked productivity zone" line, never a
//      zero-anchored gauge or a $0.00 target.
//   5. Whole-day half is untouched (Promise 3 / Layer 9) — the
//      authoritative top-half sections still render when daypart is
//      open (additive only).

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

Widget _build({
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
        create: (_) =>
            ShiftDashboardNotifier.fromReadModel(_fixtureReadModel()),
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

  group('Per-Daypart V1 Slice 4 — Shift daypart card full parity', () {
    testWidgets(
      'three-section parity render — OUTPUTS / INPUTS / FOH PRODUCTIVITY '
      'all scoped to the selected period',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch active.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(buckets: _bucketsWithLunch()));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        expect(
          find.text('OUTPUTS', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('INPUTS', skipOffstage: false),
          findsOneWidget,
        );
        // 'FOH PRODUCTIVITY' also appears as the whole-day sticky
        // delegate offstage, so allow >= 1.
        expect(
          find.text('FOH PRODUCTIVITY', skipOffstage: false),
          findsWidgets,
        );

        // Outputs section actuals.
        expect(find.text('100', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$22.50', skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets(
      'closed-shift stamp read-back — locked per-period target + OPZ band '
      "come from the closed shift's own stamp (Promise 2)",
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(
          buckets: _bucketsWithLunch(),
          daypartTargets: const {
            'lunch': DaypartTargetContext(
              source: 'closed_stamp',
              targetCPLH: 13.00,
              targetSPLH: 540.00,
              targetPPA: 41.50,
              opzFloorCPLH: 11.50,
              opzCeilingCPLH: 14.50,
            ),
          },
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Locked target sub-lines reflect the closed-shift stamp, NOT
        // the live whole-day profile (Promise 2 — closed truth keeps
        // its own stamp).
        expect(
          find.text('Target 13.00', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $540', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $41.50', skipOffstage: false),
          findsOneWidget,
        );

        // The OPZ band renders (locked floor/ceiling present) — the
        // honest "no locked productivity zone" line must NOT show.
        expect(
          find.text(
            'No locked productivity zone for this period yet.',
            skipOffstage: false,
          ),
          findsNothing,
        );
        // Lunch bucket CPLH = 100*60 / 480 = 12.50, below the stamped
        // floor of 11.50? No — 12.50 is inside [11.50, 14.50] → IN OPZ.
        expect(find.text('IN OPZ', skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets(
      'open-shift profile fallback — active profile per-period row drives '
      'the target sub-lines when the period has not closed',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(
          buckets: _bucketsWithLunch(),
          daypartTargets: const {
            'lunch': DaypartTargetContext(
              source: 'open_profile',
              targetCPLH: 12.00,
              targetSPLH: 500.00,
              targetPPA: 40.00,
              opzFloorCPLH: 10.00,
              opzCeilingCPLH: 13.00,
            ),
          },
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        expect(
          find.text('Target 12.00', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $500', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $40.00', skipOffstage: false),
          findsOneWidget,
        );
        // CPLH 12.50 is inside [10.00, 13.00] → IN OPZ.
        expect(find.text('IN OPZ', skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets(
      'null / empty honest state — no per-period target context renders '
      '"Target —" + the no-zone line, never a 0 sentinel',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // No daypartTargets injected → daypartTargetFor returns
        // DaypartTargetContext.none (all fields null).
        await tester.pumpWidget(_build(buckets: _bucketsWithLunch()));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Every target sub-line is the honest em dash — never $0.00 /
        // 0.00 (Design Rule 2).
        expect(find.text('Target —', skipOffstage: false), findsWidgets);
        expect(find.text(r'Target $0.00', skipOffstage: false), findsNothing);
        expect(find.text('Target 0.00', skipOffstage: false), findsNothing);

        // FOH Productivity degrades to the honest empty state, not a
        // zero-anchored OPZ gauge.
        expect(
          find.text(
            'No locked productivity zone for this period yet.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(find.text('IN OPZ', skipOffstage: false), findsNothing);
        expect(find.text('BELOW OPZ', skipOffstage: false), findsNothing);
      },
    );

    testWidgets(
      'whole-day half is untouched when the daypart lens is open '
      '(Promise 3 / Layer 9 — additive only)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(buckets: _bucketsWithLunch()));
        await tester.pump();
        await tester.pump();

        // Whole-day sticky sections still render before the toggle.
        expect(
          find.text('SHIFT OUTPUTS', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('SHIFT INPUTS', skipOffstage: false),
          findsOneWidget,
        );

        // Toggle to the period — the whole-day half is replaced in the
        // viewport by the daypart half but the authoritative whole-day
        // sliver tree is still mounted (additive, not destructive): the
        // daypart card's own OUTPUTS section header appears.
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();
        expect(
          find.text('SERVICE PERIOD', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('OUTPUTS', skipOffstage: false), findsOneWidget);
      },
    );

    // Daypart LABOR % true 1:1 parity fix — Theoretical sub-line +
    // delta pill mirror the whole-day `_LaborVarianceSection`, with
    // honest degrade (Design Rule 2 / Metric Honesty Doctrine).

    testWidgets(
      'daypart LABOR tile shows Theoretical sub-line + delta pill '
      'matching the whole-day structure for a period with a target',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(
          buckets: _bucketsWithLunch(),
          daypartTargets: const {
            'lunch': DaypartTargetContext(
              source: 'open_profile',
              targetCPLH: 12.00,
              targetSPLH: 500.00,
              targetPPA: 40.00,
              opzFloorCPLH: 10.00,
              opzCeilingCPLH: 13.00,
              theoreticalLaborPct: 30.0,
            ),
          },
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Lunch bucket: (80 + 100) / 4200 × 100 = 4.2857… → "4.3%".
        expect(find.text('4.3%', skipOffstage: false), findsOneWidget);
        // Per-period theoretical reference (distinct from the whole-day
        // fixture's derived theoretical, so findsOneWidget is safe).
        expect(
          find.text('Theoretical 30.0%', skipOffstage: false),
          findsOneWidget,
        );
        // Delta pill: 4.2857 − 30.0 = −25.7 pts (under → U+2212 sign,
        // mirroring the whole-day pill's exact format).
        expect(
          find.text('−25.7 pts', skipOffstage: false),
          findsOneWidget,
        );
        // No phantom zero anywhere on the card (Metric Honesty).
        expect(
          find.text('Theoretical 0.0%', skipOffstage: false),
          findsNothing,
        );
        expect(find.text('0.0 pts', skipOffstage: false), findsNothing);
      },
    );

    testWidgets(
      'labor-unconnected period → actual "—", Theoretical still shown '
      'when known, NO phantom delta pill (Design Rule 2)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Every bucket empty → lunch has no in-period minutes/sales →
        // actual labor % is honestly unknown ("—"), never $0 ÷ sales.
        final emptyBuckets = <String, ServicePeriodAccumulator>{
          for (final d in ServicePeriodDefinitionResolver.demoDefinitions)
            d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
        };

        await tester.pumpWidget(_build(
          buckets: emptyBuckets,
          daypartTargets: const {
            'lunch': DaypartTargetContext(
              source: 'open_profile',
              targetCPLH: 12.00,
              targetSPLH: 500.00,
              targetPPA: 40.00,
              opzFloorCPLH: 10.00,
              opzCeilingCPLH: 13.00,
              theoreticalLaborPct: 28.5,
            ),
          },
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Theoretical line still renders (period theoretical is known)…
        expect(
          find.text('Theoretical 28.5%', skipOffstage: false),
          findsOneWidget,
        );
        // …but the actual is the honest em dash, and there is NO
        // phantom `0.0%` / `0.0 pts` and no delta pill computed off a
        // null actual (mirrors how the whole-day card degrades).
        expect(find.text('—', skipOffstage: false), findsWidgets);
        expect(
          find.text('Theoretical 0.0%', skipOffstage: false),
          findsNothing,
        );
        expect(find.text('0.0 pts', skipOffstage: false), findsNothing);
        expect(
          find.text('−0.0 pts', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'whole-day LABOR card render is unchanged — Theoretical sub-line '
      '+ delta pill still present (Promise 3 / Layer 9, byte-untouched)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(buckets: _bucketsWithLunch()));
        await tester.pump();
        await tester.pump();

        // Before any daypart toggle the authoritative whole-day labor
        // card renders its label, a Theoretical reference, and a pts
        // delta pill exactly as it did pre-fix.
        expect(
          find.text('LABOR %', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining('Theoretical ', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining(' pts', skipOffstage: false),
          findsWidgets,
        );
      },
    );
  });
}
