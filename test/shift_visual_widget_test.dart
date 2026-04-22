// Prompt 7.12 + 7.55m.3 â€” Shift Visual Widget Tests
//
// Verifies that the polished Shift screen still exposes the required
// structure and key visible labels after the visual pass.
// Now proves rendering from provider-backed read model, not demo constants.
// 7.55m.3: header time is now a live clock, not static snapshot text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

// Build a read model from the same fixture values ShiftSnapshot used to carry.
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

ShiftDashboardReadModel _fixtureReadModelWithReservation() {
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
  return ShiftDashboardReadModel.build(snapshot, profile, inTheBooksCovers: 72);
}

Widget _buildShiftDashboard({String? restaurantName, ShiftDashboardReadModel? readModel}) {
  final rm = readModel ?? _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: restaurantName ?? MeridianConfig.restaurantName,
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
  // Clear clock override between tests.
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  // â”€â”€ A: core sections render â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” core sections', () {
    testWidgets('restaurant name is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text(MeridianConfig.restaurantName, skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('restaurant name prefers persisted scope when provided',
        (tester) async {
      await tester.pumpWidget(
        _buildShiftDashboard(restaurantName: 'Forge & Flow Halifax'),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Forge & Flow Halifax', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('daypart and day are present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      // Shift header trailing slot now renders day · daypart on a single
      // line under the live clock, matching the variance-style header.
      expect(
          find.text('Friday \u00b7 Mar 27', skipOffstage: false),
          findsOneWidget);
    });

    // 7.55m.3: header time is now a live wall clock, not static snapshot text.
    testWidgets('header renders live clock via test seam', (tester) async {
      // Inject a deterministic time: 8:30 PM
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 27, 20, 30);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      // Clock now splits the time and AM/PM into separate Text widgets so
      // the digits can be larger than the meridiem suffix.
      expect(find.text('8:30', skipOffstage: false), findsOneWidget);
      expect(find.text('PM', skipOffstage: false), findsOneWidget);
    });

    testWidgets('header does NOT render old service-elapsed text', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      // The old static “into service” text must not appear.
      expect(find.textContaining('into service', skipOffstage: false),
          findsNothing);
    });

    testWidgets('header does NOT render old static time text', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      // The old combined “timeLabel · serviceElapsedLabel” must not appear.
      expect(
          find.text(
              '${ShiftSnapshot.time} \u00b7 ${ShiftSnapshot.serviceElapsed}',
              skipOffstage: false),
          findsNothing);
    });

    testWidgets('LABOR % label is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('LABOR %', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // â”€â”€ B: OPZ widget key pieces â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” OPZ widget', () {
    testWidgets('OPZ status label exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      final rm = _fixtureReadModel();
      expect(find.text(rm.opzLabel, skipOffstage: false), findsOneWidget);
    });

    testWidgets('CPLH label exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('CPLH', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('target value exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      final rm = _fixtureReadModel();
      expect(
          find.text(rm.targetCPLH.toStringAsFixed(2), skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('ceiling value exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      final rm = _fixtureReadModel();
      expect(
          find.text(rm.opzCeilingCPLH.toStringAsFixed(2), skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // â”€â”€ C: metric cards render â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” metric cards', () {
    testWidgets('COVERS card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('COVERS', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('PPA card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('PPA', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('CPLH card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('CPLH', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('CPLH metric card renders at 2dp (7.55h)', (tester) async {
      final rm = _fixtureReadModel();
      await tester.pumpWidget(_buildShiftDashboard(readModel: rm));
      await tester.pump();
      await tester.pump();

      final cplhCard = rm.metricCards.firstWhere((c) => c.name == 'CPLH');
      // Current value must be 2dp
      expect(cplhCard.currentFormatted, contains('.'));
      expect(cplhCard.currentFormatted.split('.').last.length, 2);
      expect(
        find.text(cplhCard.currentFormatted, skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      // Target line must be 2dp
      expect(cplhCard.targetFormatted, contains('.'));
      expect(
        find.text(cplhCard.targetFormatted, skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('SPLH card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('SPLH', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('BLENDED WAGE card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('BLENDED WAGE', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // â”€â”€ D: teaching container â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  // Teaching section hidden on Shift screen — Phase 10.5.
  group('D â€” teaching container', () {
    testWidgets('PRIMARY DRIVER section label is NOT rendered (Phase 10.5)',
        (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      // The full teaching section is commented out — deferred until Shift
      // is daypart-live in Phase 10.5. The section label must not appear.
      expect(find.text('PRIMARY DRIVER', skipOffstage: false), findsNothing);
    });
  });

  // â”€â”€ E: hero truth intact â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” hero truth', () {
    test('exactly one hero card in read model', () {
      final rm = _fixtureReadModel();
      final heroes = rm.metricCards.where((c) => c.isHero).toList();
      expect(heroes.length, equals(1));
    });

    testWidgets('DRIVER badge renders for hero card', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('DRIVER', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // ── G: LABOR % card reads from ShiftDashboardReadModel ────────────────────

  group('G — LABOR % from read model, not WTD', () {
    testWidgets('LABOR % card shows read-model actualLaborPct, not WTD value',
        (tester) async {
      final rm = _fixtureReadModel();
      await tester.pumpWidget(_buildShiftDashboard(readModel: rm));
      await tester.pump();
      await tester.pump();

      // The read model's actualLaborPct should appear as the displayed value.
      // StaticShiftDataSource WTD actualLaborPct is different from the
      // read model's whole-day labor %. This proves the card reads the read model.
      final expectedText = '${rm.actualLaborPct.toStringAsFixed(1)}%';
      expect(find.text(expectedText, skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('LABOR % card shows read-model theoretical target',
        (tester) async {
      final rm = _fixtureReadModel();
      await tester.pumpWidget(_buildShiftDashboard(readModel: rm));
      await tester.pump();
      await tester.pump();

      final expectedTarget =
          'Theoretical ${rm.targetLaborPct.toStringAsFixed(1)}%';
      expect(find.text(expectedTarget, skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    test('7.55q.6: ShiftDashboardReadModel.targetLaborPct sources from '
        'profile.theoreticalLaborPct, NOT from the killed planned-labor '
        'package formula', () {
      // Build a read model with a profile whose theoreticalLaborPct is
      // intentionally distinct from what the old planned-package formula
      // (planFohHours × fohWage + planBohHours × bohWage) / forecastSales
      // would have produced.
      const distinctTheoreticalPct = 33.3;
      final profile = ActiveTargetProfile(
        targetProfileId: 'q6-test',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetSPLH: BaselineData.derivedTargetSPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
        opzFloorCPLH: BaselineData.opzFloorCPLH,
        opzCeilingCPLH: BaselineData.opzCeilingCPLH,
        theoreticalFohLaborPct: 13.3,
        theoreticalBohLaborPct: 20.0,
        theoreticalLaborPct: distinctTheoreticalPct,
        builtAt: '2026-04-14T00:00:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        status: 'open',
        businessDate: '2026-03-27',
        forecastCovers: 100,
        currentCovers: 50,
        scheduledFohHours: 20,
        scheduledBohHours: 22,
        currentPPA: 42.0,
        currentCPLH: 5.0,
        currentSPLH: 200.0,
        blendedWage: 18.0,
        updatedAt: '2026-03-27T19:42:00',
      );
      final rm = ShiftDashboardReadModel.build(snapshot, profile);

      // 7.55q.6 contract: targetLaborPct equals the profile's
      // theoreticalLaborPct exactly. The old planned-package formula
      // would have produced a different number derived from
      // (planFohHours × fohWage + planBohHours × bohWage) / forecastSales.
      expect(rm.targetLaborPct, equals(distinctTheoreticalPct));
    });
  });

  // â”€â”€ F: reservation book signal â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” reservation book signal', () {
    testWidgets('COVERS card renders “In the books 72” when reservation exists',
        (tester) async {
      final rm = _fixtureReadModelWithReservation();
      await tester.pumpWidget(_buildShiftDashboard(readModel: rm));
      await tester.pump();
      await tester.pump();
      expect(find.text('In the books 72', skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('COVERS card hides “In the books” when no reservation exists',
        (tester) async {
      final rm = _fixtureReadModel();
      await tester.pumpWidget(_buildShiftDashboard(readModel: rm));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('In the books', skipOffstage: false),
          findsNothing);
    });
  });
}
