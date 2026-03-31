// Prompt 7.12 â€” Shift Visual Widget Tests
//
// Verifies that the polished Shift screen still exposes the required
// structure and key visible labels after the visual pass.
// Now proves rendering from provider-backed read model, not demo constants.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
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

Widget _buildShiftDashboard({String? restaurantName}) {
  final rm = _fixtureReadModel();
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
      ChangeNotifierProvider<WeekDataNotifier>(
        create: (_) => WeekDataNotifier(const StaticShiftDataSource()),
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
      expect(
          find.text('Dinner \u00b7 Friday', skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('time and service elapsed are present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(
              '${ShiftSnapshot.time} \u00b7 ${ShiftSnapshot.serviceElapsed}',
              skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('LABOR % VARIANCE header is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('LABOR % VARIANCE', skipOffstage: false),
          findsOneWidget);
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

  group('D â€” teaching container', () {
    testWidgets('active lever whatHappened text is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      final rm = _fixtureReadModel();
      expect(
          find.text(rm.primaryLeverCard.whatHappened, skipOffstage: false),
          findsOneWidget);
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
}
