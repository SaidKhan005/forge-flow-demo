// Prompt 7.11 â€” Shift Dynamic Truth Tests
//
// Verifies that the Shift screen's highlighted metric card and bottom
// teaching line follow the real active lever from LaborModel.determineLever.
// Now validates through the read model rather than static demo wiring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/services/labor_model.dart';

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

void main() {
  // â”€â”€ A: primary lever matches LaborModel.determineLever â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” read model primaryLeverId', () {
    test('matches LaborModel.determineLever with same inputs', () {
      final rm = _fixtureReadModel();
      final expected = LaborModel.determineLever(
        actualCovers: ShiftSnapshot.actualCovers,
        forecastCovers: ShiftSnapshot.shiftForecastCovers,
        avgCPLH: ShiftSnapshot.actualCPLH,
        avgPPA: ShiftSnapshot.actualPPA,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        avgSPLH: ShiftSnapshot.actualSPLH,
        targetSPLH: BaselineData.derivedTargetSPLH,
      );
      expect(rm.primaryLeverId, equals(expected));
    });
  });

  // â”€â”€ B: primary lever card resolves from the id â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” read model primaryLeverCard', () {
    test('card id matches primaryLeverId', () {
      final rm = _fixtureReadModel();
      expect(rm.primaryLeverCard.id, equals(rm.primaryLeverId));
    });
  });

  // â”€â”€ C: hero mapping helper works for all lever families â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” heroMetricNameForLever', () {
    // These test the static utility that still lives on ShiftMetrics for compat
    test('covers_down â†’ COVERS', () {
      expect(ShiftMetrics.heroMetricNameForLever('covers_down'), 'COVERS');
    });
    test('covers_up â†’ COVERS', () {
      expect(ShiftMetrics.heroMetricNameForLever('covers_up'), 'COVERS');
    });
    test('ppa_down â†’ PPA', () {
      expect(ShiftMetrics.heroMetricNameForLever('ppa_down'), 'PPA');
    });
    test('ppa_up â†’ PPA', () {
      expect(ShiftMetrics.heroMetricNameForLever('ppa_up'), 'PPA');
    });
    test('cplh_down â†’ CPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('cplh_down'), 'CPLH');
    });
    test('cplh_up â†’ CPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('cplh_up'), 'CPLH');
    });
    test('splh_down â†’ SPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('splh_down'), 'SPLH');
    });
    test('splh_up â†’ SPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('splh_up'), 'SPLH');
    });
    test('foh_wage_up â†’ BLENDED WAGE', () {
      expect(
          ShiftMetrics.heroMetricNameForLever('foh_wage_up'), 'BLENDED WAGE');
    });
    test('boh_wage_down â†’ BLENDED WAGE', () {
      expect(ShiftMetrics.heroMetricNameForLever('boh_wage_down'),
          'BLENDED WAGE');
    });
  });

  // â”€â”€ D: runtime read model card set contains exactly one hero â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” exactly one hero card', () {
    test('exactly one card has isHero == true', () {
      final rm = _fixtureReadModel();
      final heroes = rm.metricCards.where((c) => c.isHero).toList();
      expect(heroes.length, equals(1));
    });
  });

  // â”€â”€ E: hero card name matches active lever family â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” hero card matches lever family', () {
    test('hero name matches heroMetricNameForLever(primaryLeverId)', () {
      final rm = _fixtureReadModel();
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name,
          equals(ShiftMetrics.heroMetricNameForLever(rm.primaryLeverId)));
    });
  });

  // â”€â”€ F: Shift teaching line is aligned to active lever â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” teaching line alignment', () {
    test('primaryLeverCard.whatHappened is non-empty', () {
      final rm = _fixtureReadModel();
      expect(rm.primaryLeverCard.whatHappened, isNotEmpty);
    });

    testWidgets('bottom teaching line shows active lever whatHappened',
        (tester) async {
      final rm = _fixtureReadModel();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
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
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text(rm.primaryLeverCard.whatHappened, skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}
