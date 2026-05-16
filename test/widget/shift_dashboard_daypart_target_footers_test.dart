// Per-Daypart Targets V1 — Shift daypart target/benchmark footer parity.
//
// Operator finding (live walkthrough 2026-05-16): "The whole day tiles
// have the targets and benchmarks on each widget/tile at the bottom of
// the live metric but the day part ones don't." Core app logic: the
// benchmark + locked plan FORM the targets/benchmarks Shift compares to;
// this must apply to dayparts, shown on the daypart tiles, true 1:1 with
// whole-day — and degrade honestly (Design Rule 2 / Metric Honesty) when
// a per-daypart target genuinely does not exist.
//
// Pins:
//   1. A selected daypart that HAS a locked per-daypart plan reference
//      renders the SALES "Forecast $X" + COVERS "Forecast N" footers with
//      the PER-DAYPART values (sourced from the in-force WeeklyPlanSnapshot
//      via `DaypartTargetContext.forecastSales` / `.forecastCovers`) — NOT
//      the whole-day numbers. The COVERS pin guards the open/not-yet-started
//      branch fix (`_resolveDaypartTargets` now passes `forecastCovers` on
//      the `open_profile` / `none` branches, true 1:1 with `forecastSales`):
//      previously every not-yet-started daypart fell back to the
//      "service period hasn't started yet" tooltip instead of its locked
//      plan covers.
//   2. The same daypart renders the FOH/BOH HRS "Target N hrs" footer +
//      delta pill from the locked per-daypart `required_*_hours`.
//   3. A daypart with NO locked per-daypart plan reference degrades
//      honestly: SALES shows "No forecast available", COVERS/FOH/BOH show
//      the value alone — never a fabricated "Forecast $0" / "Forecast 0" /
//      "Target 0 hrs".
//   4. Whole-day SALES + FOH footers are byte-unchanged (Promise/Layer 9).

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
      fohMinutes: 240, // 4.0 hrs
      bohMinutes: 240, // 4.0 hrs
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

  group('Shift daypart target/benchmark footers — true 1:1 with whole-day',
      () {
    testWidgets(
      'period WITH a locked per-daypart plan reference shows the '
      'per-daypart SALES forecast + FOH/BOH "Target N hrs" footers '
      '(not the pooled whole-day numbers)',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch active.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        const lunchTarget = DaypartTargetContext(
          source: 'open_profile',
          targetCPLH: 12.00,
          targetSPLH: 500.00,
          targetPPA: 40.00,
          opzFloorCPLH: 10.00,
          opzCeilingCPLH: 13.00,
          theoreticalLaborPct: 30.0,
          // Locked plan-side per-daypart references (WeeklyPlanSnapshot
          // child row). Distinct, non-round values so a collision with
          // the whole-day fixture is vanishingly unlikely.
          forecastCovers: 4321,
          forecastSales: 4567.0,
          requiredFohHours: 23.0,
          requiredBohHours: 17.0,
        );

        await tester.pumpWidget(_build(
          buckets: _bucketsWithLunch(),
          daypartTargets: const {'lunch': lunchTarget},
        ));
        await tester.pump();
        await tester.pump();

        // Pre-toggle (whole-day): the per-daypart numbers must NOT be
        // on screen — proves the daypart footer is the per-daypart
        // value, not a pooled whole-day stand-in.
        expect(
          find.text(r'Forecast $4,567', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('Forecast 4321', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('Target 23 hrs', skipOffstage: false),
          findsNothing,
        );

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // 1. SALES "Forecast $X" footer = locked per-daypart forecast.
        expect(
          find.text(r'Forecast $4,567', skipOffstage: false),
          findsOneWidget,
        );
        // 1b. COVERS "Forecast N" footer = locked per-daypart forecast
        //     covers (open/not-yet-started branch parity — guards the
        //     `_resolveDaypartTargets` open-branch `forecastCovers` fix).
        expect(
          find.text('Forecast 4321', skipOffstage: false),
          findsOneWidget,
        );
        // 2. FOH/BOH "Target N hrs" footer = locked per-daypart
        //    required hours; delta pill = actual − target (lunch bucket
        //    is 4.0 FOH / 4.0 BOH hrs).
        expect(
          find.text('Target 23 hrs', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('Target 17 hrs', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('-19 hrs', skipOffstage: false), findsOneWidget);
        expect(find.text('-13 hrs', skipOffstage: false), findsOneWidget);

        // No phantom zeros anywhere (Design Rule 2 / Metric Honesty).
        expect(
          find.text(r'Forecast $0', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('Target 0 hrs', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'period with NO locked per-daypart plan reference degrades '
      'honestly — "No forecast available", no fabricated "Target N hrs"',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Only a theoretical labor % is known — no forecastSales, no
        // targetPPA, no required FOH/BOH hours.
        const lunchTarget = DaypartTargetContext(
          source: 'none',
          theoreticalLaborPct: 28.5,
        );

        await tester.pumpWidget(_build(
          buckets: _bucketsWithLunch(),
          daypartTargets: const {'lunch': lunchTarget},
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // SALES degrades to the honest empty footer, never "$0".
        expect(
          find.text('No forecast available', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.textContaining(r'Forecast $', skipOffstage: false),
          findsNothing,
        );
        // COVERS also degrades honestly — null `forecastCovers` must NOT
        // fabricate a "Forecast N" footer (no per-daypart plan covers).
        expect(
          find.textContaining('Forecast ', skipOffstage: false),
          findsNothing,
        );
        // FOH/BOH show the value alone — no "Target N hrs" line and no
        // delta pill computed off a phantom zero.
        expect(
          find.textContaining('Target ', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining(' hrs', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'whole-day SALES + FOH footers are byte-unchanged '
      '(Promise/Layer 9 — only the per-period projection changes)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(buckets: _bucketsWithLunch()));
        await tester.pump();
        await tester.pump();

        // Whole-day (no toggle): SALES still shows a "Forecast $…"
        // footer and FOH/BOH still show a "Target … hrs" footer.
        expect(
          find.textContaining(r'Forecast $', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining('Target ', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining(' hrs', skipOffstage: false),
          findsWidgets,
        );
      },
    );
  });
}
