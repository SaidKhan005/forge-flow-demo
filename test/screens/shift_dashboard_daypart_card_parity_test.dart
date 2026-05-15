// Per-Daypart V1 / Slice 4 — Shift daypart card full parity tests.
//
// Asserts the per-period card mirrors the whole-day card structure
// (Outputs · Inputs · FOH Productivity) per Decision 7, and honors
// the honest-fallback rule (`metric_card_honesty_contract.md`) when
// per-period targets are not yet locked.
//
// Three load-bearing scenarios per the Slice 4 brief:
//   1. Closed-shift bucket with full data + per-period target row →
//      every section renders live values, OPZ band reads as a range.
//   2. Open-shift bucket with `ActiveTargetProfile.daypartFor` returning
//      a value → per-period targets surface from the active profile.
//   3. Open-shift bucket with `daypartFor` returning null → target
//      pills render the honest-fallback "Target not yet locked" line
//      and the OPZ section degrades to "OPZ band not yet available"
//      — never silent fall-back to whole-day pool values.
//
// Wages stay whole-day per Decisions 11 + 13: the per-period card
// reuses the restaurant-wide blended wage; per-period blended wage
// is not a real metric in Jim Taylor's framework. The pill is
// labeled "RESTAURANT BLENDED WAGE" to make the scope explicit.

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
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

ActiveTargetProfile _wholeDayProfile({
  List<ActiveTargetProfileDaypart> dayparts = const [],
}) {
  return ActiveTargetProfile(
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
    dayparts: dayparts,
  );
}

ShiftDashboardReadModel _wholeDayReadModel({
  ActiveTargetProfile? profile,
  String? laborSourceVendorId = 'toast',
}) {
  final p = profile ?? _wholeDayProfile();
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
  return ShiftDashboardReadModel.build(
    snapshot,
    p,
    posSourceVendorId: 'toast',
    laborSourceVendorId: laborSourceVendorId,
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

Widget _build({
  required Map<String, ServicePeriodAccumulator> periodBuckets,
  required ActiveTargetProfile profile,
  String iana = 'America/St_Johns',
  List<ServicePeriodDefinition>? definitions,
  String? laborSourceVendorId = 'toast',
}) {
  final rm = _wholeDayReadModel(
    profile: profile,
    laborSourceVendorId: laborSourceVendorId,
  );
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
          profile: profile,
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

  group('Slice 4: Shift daypart card full parity (Decision 7)', () {
    testWidgets(
      'Test 1 — closed-shift bucket with per-period target row renders '
      'Outputs + Inputs + FOH Productivity per period; OPZ band reads as '
      'a range string',
      (tester) async {
        // Tuesday 2026-03-31 12:30 — Lunch is the active period.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Profile carries a Lunch per-period target row distinct from
        // the whole-day pool values so we can prove the read seam
        // pulls the per-period row, not the parent profile.
        final profile = _wholeDayProfile(
          dayparts: [
            ActiveTargetProfileDaypart(
              servicePeriodId: 'lunch',
              daypartTargetCPLH: 13.50,
              daypartTargetSPLH: 540.0,
              daypartTargetPPA: 41.00,
              daypartOpzFloorCPLH: 12.00,
              daypartOpzCeilingCPLH: 15.00,
            ),
          ],
        );

        // Lunch bucket: 100 covers, $4200 sales, 240 min FOH, 240 min
        // BOH. Expected derived: PPA $42.00, CPLH 12.50, SPLH $525.
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

        await tester.pumpWidget(
          _build(periodBuckets: buckets, profile: profile),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // SERVICE PERIOD section is open.
        expect(
          find.text('SERVICE PERIOD', skipOffstage: false),
          findsOneWidget,
        );

        // Outputs section — per-period covers + sales render as live
        // values via MetricPill (label + value).
        expect(find.text('SALES', skipOffstage: false), findsWidgets);
        expect(find.text('COVERS', skipOffstage: false), findsWidgets);
        expect(find.text(r'$4200', skipOffstage: false), findsOneWidget);
        expect(find.text('100', skipOffstage: false), findsOneWidget);

        // Wages stay whole-day (Decisions 11 + 13) — pill label is
        // "RESTAURANT BLENDED WAGE", not a per-period label.
        expect(
          find.text('RESTAURANT BLENDED WAGE', skipOffstage: false),
          findsOneWidget,
        );

        // Inputs section — per-period actuals via MetricPill.
        expect(find.text('PPA', skipOffstage: false), findsWidgets);
        expect(find.text('CPLH', skipOffstage: false), findsWidgets);
        expect(find.text('SPLH', skipOffstage: false), findsWidgets);
        // Per-period actual values (the bucket's derived numbers).
        // CPLH 12.50 appears twice: once in the Inputs section pill
        // and once as the big PERIOD CPLH header in FOH Productivity.
        expect(find.text(r'$42.00', skipOffstage: false), findsOneWidget);
        expect(find.text('12.50', skipOffstage: false), findsNWidgets(2));
        expect(find.text(r'$525', skipOffstage: false), findsOneWidget);

        // Per-period locked targets surface beneath each input pill —
        // these are the daypart row values (13.50 CPLH, $540 SPLH,
        // $41.00 PPA), distinct from the whole-day pool.
        expect(
          find.text('Target 13.50', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $540', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $41.00', skipOffstage: false),
          findsOneWidget,
        );

        // FOH Productivity section — period CPLH header + OPZ band as
        // a range string. CPLH 12.50 sits in [12.00, 15.00] → IN OPZ.
        expect(find.text('PERIOD CPLH', skipOffstage: false), findsOneWidget);
        expect(find.text('IN OPZ', skipOffstage: false), findsOneWidget);
        expect(
          find.text('OPZ 12.00 – 15.00', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Test 2 — open shift with `daypartFor` returning a value renders the '
      'per-period targets pulled from the active profile (not whole-day pool)',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Distinct per-period values vs whole-day pool so the
        // assertion proves the daypart row is consulted, not the
        // parent profile.
        final profile = _wholeDayProfile(
          dayparts: [
            ActiveTargetProfileDaypart(
              servicePeriodId: 'lunch',
              daypartTargetCPLH: 9.99, // distinct sentinel
              daypartTargetSPLH: 333.0, // distinct sentinel
              daypartTargetPPA: 21.21, // distinct sentinel
              daypartOpzFloorCPLH: 8.00,
              daypartOpzCeilingCPLH: 11.00,
            ),
          ],
        );

        final buckets = {
          ..._emptyBuckets(),
          'lunch': _bucketWith(
            id: 'lunch',
            covers: 50,
            sales: 1000.00,
            fohMinutes: 120,
            bohMinutes: 120,
            fohWageDollars: 40.00,
            bohWageDollars: 50.00,
          ),
        };

        await tester.pumpWidget(
          _build(periodBuckets: buckets, profile: profile),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // The per-period targets are the daypart row's distinct
        // values, not the whole-day pool from BaselineData.
        expect(
          find.text('Target 9.99', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $333', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(r'Target $21.21', skipOffstage: false),
          findsOneWidget,
        );

        // OPZ band reads from the daypart row (8.00 - 11.00), not the
        // whole-day pool's wider band.
        expect(
          find.text('OPZ 8.00 – 11.00', skipOffstage: false),
          findsOneWidget,
        );

        // The whole-day pool target (BaselineData.derivedTargetCPLH)
        // must NOT leak through as the per-period target.
        final poolCplh = BaselineData.derivedTargetCPLH.toStringAsFixed(2);
        expect(
          find.text('Target $poolCplh', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Test 3 — open shift with `daypartFor` returning null AND no row '
      'stamp renders honest-fallback unavailable copy for the affected '
      'fields — does NOT silently fall back to whole-day values',
      (tester) async {
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 12, 30);

        // Profile with NO per-period rows — `daypartFor('lunch')` returns
        // null. Per Slice 4 brief + Design Rule 2 + metric_card_honesty_contract.md,
        // the per-period card MUST render the honest-fallback state and
        // MUST NOT substitute the whole-day pool values.
        final profile = _wholeDayProfile(); // empty dayparts

        final buckets = {
          ..._emptyBuckets(),
          'lunch': _bucketWith(
            id: 'lunch',
            covers: 50,
            sales: 1000.00,
            fohMinutes: 120,
            bohMinutes: 120,
            fohWageDollars: 40.00,
            bohWageDollars: 50.00,
          ),
        };

        await tester.pumpWidget(
          _build(periodBuckets: buckets, profile: profile),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Lunch', skipOffstage: false));
        await tester.pump();

        // Three input pills (PPA / CPLH / SPLH) each render the
        // "Target not yet locked" honest-fallback string.
        expect(
          find.text('Target not yet locked', skipOffstage: false),
          findsNWidgets(3),
        );

        // FOH Productivity section degrades to the honest "OPZ band
        // not yet available" copy instead of fabricating a band.
        expect(
          find.text(
            'OPZ band not yet available for this period.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        // Whole-day pool target values must NOT appear as per-period
        // target lines (silent-substitution check).
        final poolCplh = BaselineData.derivedTargetCPLH.toStringAsFixed(2);
        final poolPpa = BaselineData.derivedTargetPPA.toStringAsFixed(2);
        final poolSplh = BaselineData.derivedTargetSPLH.toStringAsFixed(0);
        expect(
          find.text('Target $poolCplh', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text(r'Target $' + poolPpa, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text(r'Target $' + poolSplh, skipOffstage: false),
          findsNothing,
        );
        // The whole-day pool's OPZ floor/ceiling must NOT render in
        // the per-period FOH Productivity section.
        final poolFloor = BaselineData.opzFloorCPLH.toStringAsFixed(2);
        final poolCeil = BaselineData.opzCeilingCPLH.toStringAsFixed(2);
        expect(
          find.text('OPZ $poolFloor – $poolCeil', skipOffstage: false),
          findsNothing,
        );
      },
    );
  });
}
