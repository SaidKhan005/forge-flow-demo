// Per-Daypart Targets V1 — Slice 4 closed-state + honest empty-state
// parity fix.
//
// Operator instruction (2026-05-16): the daypart header is plain — it
// carries ONLY the operator-configured clock window and the
// primary-driver chip. The tri-state status line ("Period closed" /
// "Active now" / "Opens at …") was REMOVED. This test now pins:
//
//   1a. Closed/past-period state. A past, already-closed period (e.g.
//       demo Lunch 11:00–15:00 viewed at 16:00) must render the full
//       3-section card with honest "—" actuals and its real locked
//       per-period targets — and NO status verbiage of any kind
//       ("Period closed" / "Active now" / "Opens at …" / the old
//       "until this period opens." catch-all all absent). The
//       operator-configured clock window still renders.
//
//   1b. Honest empty-state parity. Labor-unconnected (POS sales
//       present, no labor punches) must render Labor % and Blended
//       Wage as "—", never a phantom `0.0%` / `$0.00` (Design Rule 2 +
//       Metric Honesty Doctrine).
//
//   + The authoritative whole-day half stays byte-untouched (Promise 3
//     / Layer 9 — daypart is adjacent, never replaces).

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
import 'package:forge_and_flow/widgets/zone_status_card.dart';

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

  group('Per-Daypart V1 Slice 4 — closed-state + honest empty parity', () {
    testWidgets(
      'past/closed period renders the full 3-section card with "—" '
      'actuals and its real locked targets, the clock window, and NO '
      'status verbiage',
      (tester) async {
        // Tuesday 2026-03-31 16:00 — Lunch (11:00–15:00) already closed.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 16, 0);

        await tester.pumpWidget(_build(
          // Lunch bucket is empty (no actuals captured for the period).
          buckets: _emptyBuckets(),
          // …but the period closed with a stamped per-period target
          // (Promise 2 — closed truth keeps its own stamp).
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

        // Plain header (operator instruction 2026-05-16): NO status
        // verbiage of any kind — not the old catch-all, not the
        // tri-state line.
        expect(
          find.text('Period closed', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text(
            'Projected / unavailable until this period opens.',
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.text('Opens at 11:00', skipOffstage: false),
          findsNothing,
        );
        expect(find.text('Active now', skipOffstage: false), findsNothing);

        // …but the operator-configured clock window for the selected
        // period still renders (the one element the plain header keeps).
        expect(
          find.text('11:00 – 15:00', skipOffstage: false),
          findsOneWidget,
        );

        // Full card — never collapses to a one-liner.
        expect(find.text('OUTPUTS', skipOffstage: false), findsOneWidget);
        expect(find.text('INPUTS', skipOffstage: false), findsOneWidget);
        expect(
          find.text('FOH PRODUCTIVITY', skipOffstage: false),
          findsWidgets,
        );

        // True 1:1: the locked stamp drives the SHARED ZoneStatusCard
        // band (Whole Day uses the same widget) even with zero actuals —
        // a closed-with-no-data period still renders its standard's band,
        // never the bespoke "Target 13.00" sub-lines (retired) and never
        // the honest "no zone" line (the band IS present).
        expect(find.byType(ZoneStatusCard, skipOffstage: false),
            findsOneWidget);
        expect(
          find.text(
            'No locked productivity zone for this period yet.',
            skipOffstage: false,
          ),
          findsNothing,
        );

        // No phantom zeros for the missing actuals (Design Rule 2).
        expect(find.text('0.0%', skipOffstage: false), findsNothing);
        expect(find.text(r'$0.00', skipOffstage: false), findsNothing);
        expect(find.text('Target 0.00', skipOffstage: false), findsNothing);
        expect(find.text(r'Target $0.00', skipOffstage: false), findsNothing);
      },
    );

    testWidgets(
      'labor not connected (POS sales present, no labor punches) renders '
      'Labor % / Blended Wage as "—", never a phantom 0.0% / \$0.00',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch active.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        final buckets = {
          ..._emptyBuckets(),
          // POS connected (covers + sales) but labor NOT connected:
          // zero in-period minutes / wage dollars.
          'lunch': const ServicePeriodAccumulator(
            servicePeriodId: 'lunch',
            covers: 100,
            sales: 4200.00,
          ),
        };

        await tester.pumpWidget(_build(buckets: buckets));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Active period — full card renders, but the plain header shows
        // NO "Active now" verbiage (operator instruction 2026-05-16),
        // only the operator-configured clock window.
        expect(find.text('Active now', skipOffstage: false), findsNothing);
        expect(
          find.text('11:00 – 15:00', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('OUTPUTS', skipOffstage: false), findsOneWidget);

        // POS actuals still surface honestly.
        expect(find.text('100', skipOffstage: false), findsOneWidget);
        expect(find.text(r'$42.00', skipOffstage: false), findsOneWidget);

        // The defect: labor-derived metrics must be "—", NOT phantom
        // zeros computed off `$0 ÷ sales` / zero minutes.
        expect(find.text('0.0%', skipOffstage: false), findsNothing);
        expect(find.textContaining('0.0%', skipOffstage: false), findsNothing);
        expect(find.text(r'$0.00', skipOffstage: false), findsNothing);
        // At least one honest em dash renders (Labor %, CPLH, SPLH,
        // Blended Wage all unavailable without labor).
        expect(find.text('—', skipOffstage: false), findsWidgets);
      },
    );

    testWidgets(
      'genuinely future period shows NO status verbiage — only the '
      'operator-configured clock window + the full card',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Dinner (17:00) has not opened yet.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(buckets: _emptyBuckets()));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Dinner', skipOffstage: false));
        await tester.pump();

        expect(
          find.text('Opens at 17:00', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('Period closed', skipOffstage: false),
          findsNothing,
        );
        expect(find.text('Active now', skipOffstage: false), findsNothing);
        // The one element the plain header keeps.
        expect(
          find.text('17:00 – 23:00', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('OUTPUTS', skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets(
      'whole-day half is byte-untouched — additive only (Promise 3 / '
      'Layer 9)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 16, 0);

        await tester.pumpWidget(_build(buckets: _emptyBuckets()));
        await tester.pump();
        await tester.pump();

        // Whole-day authoritative sections render before any toggle and
        // none of the daypart status copy leaks into that path.
        expect(
          find.text('SHIFT OUTPUTS', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('SHIFT INPUTS', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('Period closed', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('SERVICE PERIOD', skipOffstage: false),
          findsNothing,
        );
      },
    );
  });
}
