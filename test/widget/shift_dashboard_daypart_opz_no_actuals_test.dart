// Per-Daypart Targets V1 — Shift daypart OPZ honest "actuals not in yet".
//
// Pins the phantom-zero defect this fix closes: a daypart period with a
// locked OPZ band (closed stamp or open-profile per-period row) but NO
// in-period labor punches yet used to score the period off a sentinel
// `0.0` CPLH and render an alarming "BELOW OPZ" verdict + a 0.0 needle.
// Metric Honesty Doctrine / Design Rule 2: missing actuals → an honest
// pending state, never a verdict computed off a phantom zero.
//
//   (a) locked band + zero in-period labor → the band still renders
//       (operator sees the locked standard) but the verdict is
//       "AWAITING ACTUALS", the CURRENT CPLH reads "—", and NONE of the
//       alarming below-floor copy / 0.00 needle value appears.
//   (b) real labor in the period → the exact prior OPZ status / verdict
//       / needle is unchanged (no regression).
//   (c) no locked band → the existing honest "No locked productivity
//       zone…" line, unchanged.
//   (d) the authoritative whole-day OPZ render never shows the pending
//       state (Promise 3 / Layer 9 — daypart is adjacent, never
//       replaces; whole-day always supplies real actuals).

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

// Lunch with real labor punches (240 + 240 min, $80 + $100) →
// CPLH = 100 * 60 / 480 = 12.50.
ServicePeriodAccumulator _lunchWithLabor() => const ServicePeriodAccumulator(
      servicePeriodId: 'lunch',
      covers: 100,
      sales: 4200.00,
      fohMinutes: 240,
      bohMinutes: 240,
      fohWageDollars: 80.00,
      bohWageDollars: 100.00,
    );

const _openProfileBand = DaypartTargetContext(
  source: 'open_profile',
  targetCPLH: 12.00,
  targetSPLH: 500.00,
  targetPPA: 40.00,
  opzFloorCPLH: 10.00,
  opzCeilingCPLH: 13.00,
);

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

  group('Shift daypart OPZ — honest "actuals not in yet"', () {
    testWidgets(
      '(a) locked band + zero in-period labor → AWAITING ACTUALS, NO '
      'phantom BELOW-OPZ verdict / 0.0 needle (band still drawn)',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch active, but no labor punches.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(
          // POS connected (covers + sales) but ZERO labor minutes.
          buckets: {
            ..._emptyBuckets(),
            'lunch': const ServicePeriodAccumulator(
              servicePeriodId: 'lunch',
              covers: 100,
              sales: 4200.00,
            ),
          },
          daypartTargets: const {'lunch': _openProfileBand},
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // The locked band IS still drawn — the operator sees the
        // standard, never a silently-hidden zone.
        expect(find.byType(ZoneStatusCard, skipOffstage: false),
            findsOneWidget);
        expect(
          find.text(
            'No locked productivity zone for this period yet.',
            skipOffstage: false,
          ),
          findsNothing,
        );

        // Honest pending verdict — NOT an alarming below-floor score.
        expect(find.text('AWAITING ACTUALS', skipOffstage: false),
            findsOneWidget);
        expect(find.text('BELOW OPZ', skipOffstage: false), findsNothing);
        expect(find.text('IN OPZ', skipOffstage: false), findsNothing);
        expect(
          find.textContaining(
            'Too many labor hours',
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.text(
            'Locked productivity zone is set. Waiting on labor punches '
            'for this period before scoring.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        // No phantom `0.00` CURRENT CPLH value (it reads "—"); the band
        // labels are 10.00 / 12.00 / 13.00, none of which is 0.00.
        expect(find.text('0.00', skipOffstage: false), findsNothing);
        expect(find.text('—', skipOffstage: false), findsWidgets);

        // No layout overflow at a representative phone width.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '(b) real labor in the period → correct OPZ status / needle / '
      'verdict, unchanged (no regression)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        await tester.pumpWidget(_build(
          buckets: {..._emptyBuckets(), 'lunch': _lunchWithLabor()},
          daypartTargets: const {'lunch': _openProfileBand},
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // CPLH 12.50 ∈ [10.00, 13.00] → IN OPZ, real needle + value.
        expect(find.byType(ZoneStatusCard, skipOffstage: false),
            findsOneWidget);
        expect(find.text('IN OPZ', skipOffstage: false), findsOneWidget);
        expect(find.text('12.50', skipOffstage: false), findsWidgets);
        expect(find.text('AWAITING ACTUALS', skipOffstage: false),
            findsNothing);
      },
    );

    testWidgets(
      '(c) no locked band → the existing honest no-zone line, unchanged',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // No daypartTargets → DaypartTargetContext.none (no band).
        await tester.pumpWidget(_build(
          buckets: {..._emptyBuckets(), 'lunch': _lunchWithLabor()},
        ));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        expect(
          find.text(
            'No locked productivity zone for this period yet.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
            find.byType(ZoneStatusCard, skipOffstage: false), findsNothing);
        expect(find.text('AWAITING ACTUALS', skipOffstage: false),
            findsNothing);
      },
    );

    testWidgets(
      '(d) whole-day OPZ never shows the pending state (Promise 3 / '
      'Layer 9 — whole-day always supplies real actuals)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Default lens (no period toggle) = the authoritative whole day.
        await tester.pumpWidget(_build(buckets: _emptyBuckets()));
        await tester.pump();
        await tester.pump();

        expect(find.byType(ZoneStatusCard, skipOffstage: false),
            findsOneWidget);
        expect(find.text('AWAITING ACTUALS', skipOffstage: false),
            findsNothing);
        expect(
          find.text(
            'Locked productivity zone is set. Waiting on labor punches '
            'for this period before scoring.',
            skipOffstage: false,
          ),
          findsNothing,
        );
      },
    );
  });
}
