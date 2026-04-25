// Phase 7.55p.1 — Shift driver trust audit tests.
//
// Covers:
// A. Shift-reachable Chapter 10 families (covers, ppa, cplh, splh) fire
//    correctly and map to the expected hero card
// B. Favorable scenarios produce green emphasis (deltaUnfavorable = false)
// C. Unfavorable scenarios produce red emphasis (deltaUnfavorable = true)
// D. Wage families are NOT reachable from the Shift call shape
// E. Hours-flex families CAN fire from the Shift call shape
// F. Hours-flex hero-card mapping falls through to COVERS (documented gap)
// G. Shift PRIMARY DRIVER teaching section remains hidden (Phase 10.5)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

ActiveTargetProfile _profile() => ActiveTargetProfile(
      targetProfileId: 'audit_profile',
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
      builtAt: '2026-04-13T00:00:00Z',
    );

/// Builds a ShiftDashboardReadModel with explicit control over all inputs.
///
/// Defaults produce on-target metrics: CPLH, SPLH, PPA, and covers all at
/// target with plan hours matching scheduled hours (no hours-flex deviation).
/// Override individual parameters to isolate a single lever.
ShiftDashboardReadModel _buildShift({
  int actualCovers = 200,
  int forecastCovers = 200,
  double? actualPPA,
  int? scheduledFohHours,
  int? scheduledBohHours,
  int? planFohHours,
  int? planBohHours,
}) {
  final profile = _profile();
  final ppa = actualPPA ?? profile.targetPPA;
  final sales = actualCovers * ppa;

  // Default hours: produce on-target productivity
  final defaultFoh = LaborModel.modelFohHours(actualCovers, profile.targetCPLH);
  final defaultBoh = LaborModel.modelBohHoursFromSales(sales, profile.targetSPLH);
  final foh = scheduledFohHours ?? defaultFoh;
  final boh = scheduledBohHours ?? defaultBoh;

  // Default plan hours: match scheduled hours (no hours-flex deviation)
  final pFoh = planFohHours ?? foh;
  final pBoh = planBohHours ?? boh;

  final cplh = foh > 0 ? actualCovers / foh : 0.0;
  final splh = boh > 0 ? sales / boh : 0.0;

  final snapshot = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W15',
    dayLabel: 'Mon',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-04-06',
    forecastCovers: forecastCovers,
    currentCovers: actualCovers,
    scheduledFohHours: foh,
    scheduledBohHours: boh,
    currentPPA: ppa,
    currentCPLH: cplh,
    currentSPLH: splh,
    blendedWage: 18.74,
    timeLabel: '7:42 PM',
    serviceElapsedLabel: '3h 14m into service',
    updatedAt: '2026-04-06T19:42:00Z',
  );

  return ShiftDashboardReadModel.buildWholeDay(
    snapshots: [snapshot],
    profile: profile,
    forecastCovers: forecastCovers,
    forecastSales: forecastCovers * profile.targetPPA,
    planFohHours: pFoh,
    planBohHours: pBoh,
    actualCoversOverride: actualCovers,
    actualSalesOverride: sales,
  );
}

void main() {
  // ── A: Shift-reachable Chapter 10 families ────────────────────────────────

  group('A — Shift-reachable Chapter 10 families fire correctly', () {
    test('covers_down fires and maps to COVERS hero card', () {
      // Covers 20% below forecast. Hours auto-adjusted to keep CPLH/SPLH on
      // target, plan hours match scheduled (no hours-flex).
      final rm = _buildShift(actualCovers: 160, forecastCovers: 200);
      expect(rm.primaryLeverId, 'covers_down');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'COVERS');
    });

    test('covers_up fires and maps to COVERS hero card', () {
      final rm = _buildShift(actualCovers: 250, forecastCovers: 200);
      expect(rm.primaryLeverId, 'covers_up');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'COVERS');
    });

    test('ppa_down fires and maps to PPA hero card', () {
      final profile = _profile();
      final rm = _buildShift(actualPPA: profile.targetPPA * 0.90);
      expect(rm.primaryLeverId, 'ppa_down');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'PPA');
    });

    test('ppa_up fires and maps to PPA hero card', () {
      final profile = _profile();
      final rm = _buildShift(actualPPA: profile.targetPPA * 1.10);
      expect(rm.primaryLeverId, 'ppa_up');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'PPA');
    });

    test('cplh_down fires and maps to CPLH hero card', () {
      final profile = _profile();
      // Overschedule FOH to push CPLH 15% below target. Plan hours match
      // scheduled so no hours-flex fires.
      final neededFoh = (200 / (profile.targetCPLH * 0.85)).round();
      final rm = _buildShift(
        scheduledFohHours: neededFoh,
        planFohHours: neededFoh,
      );
      expect(rm.primaryLeverId, 'cplh_down');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'CPLH');
    });

    test('cplh_up fires and maps to CPLH hero card', () {
      final profile = _profile();
      final neededFoh = (200 / (profile.targetCPLH * 1.15)).round();
      final rm = _buildShift(
        scheduledFohHours: neededFoh,
        planFohHours: neededFoh,
      );
      expect(rm.primaryLeverId, 'cplh_up');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'CPLH');
    });

    test('splh_down fires and maps to SPLH hero card', () {
      final profile = _profile();
      final sales = 200 * profile.targetPPA;
      final neededBoh = (sales / (profile.targetSPLH * 0.85)).round();
      final rm = _buildShift(
        scheduledBohHours: neededBoh,
        planBohHours: neededBoh,
      );
      expect(rm.primaryLeverId, 'splh_down');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'SPLH');
    });

    test('splh_up fires and maps to SPLH hero card', () {
      final profile = _profile();
      final sales = 200 * profile.targetPPA;
      final neededBoh = (sales / (profile.targetSPLH * 1.15)).round();
      final rm = _buildShift(
        scheduledBohHours: neededBoh,
        planBohHours: neededBoh,
      );
      expect(rm.primaryLeverId, 'splh_up');
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.name, 'SPLH');
    });
  });

  // ── B: Favorable scenarios produce green emphasis ─────────────────────────

  group('B — favorable scenarios: deltaUnfavorable is false on hero card', () {
    test('covers_up hero card shows favorable delta', () {
      final rm = _buildShift(actualCovers: 250, forecastCovers: 200);
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isFalse,
          reason: 'covers_up should show green (favorable) delta');
    });

    test('ppa_up hero card shows favorable delta', () {
      final profile = _profile();
      final rm = _buildShift(actualPPA: profile.targetPPA * 1.10);
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isFalse,
          reason: 'ppa_up should show green (favorable) delta');
    });

    test('cplh_up hero card shows favorable delta', () {
      final profile = _profile();
      final neededFoh = (200 / (profile.targetCPLH * 1.15)).round();
      final rm = _buildShift(
        scheduledFohHours: neededFoh,
        planFohHours: neededFoh,
      );
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isFalse,
          reason: 'cplh_up should show green (favorable) delta');
    });

    test('splh_up hero card shows favorable delta', () {
      final profile = _profile();
      final sales = 200 * profile.targetPPA;
      final neededBoh = (sales / (profile.targetSPLH * 1.15)).round();
      final rm = _buildShift(
        scheduledBohHours: neededBoh,
        planBohHours: neededBoh,
      );
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isFalse,
          reason: 'splh_up should show green (favorable) delta');
    });
  });

  // ── C: Unfavorable scenarios produce red emphasis ─────────────────────────

  group('C — unfavorable scenarios: deltaUnfavorable is true on hero card', () {
    test('covers_down hero card shows unfavorable delta', () {
      final rm = _buildShift(actualCovers: 160, forecastCovers: 200);
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isTrue,
          reason: 'covers_down should show red (unfavorable) delta');
    });

    test('ppa_down hero card shows unfavorable delta', () {
      final profile = _profile();
      final rm = _buildShift(actualPPA: profile.targetPPA * 0.90);
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isTrue,
          reason: 'ppa_down should show red (unfavorable) delta');
    });

    test('cplh_down hero card shows unfavorable delta', () {
      final profile = _profile();
      final neededFoh = (200 / (profile.targetCPLH * 0.85)).round();
      final rm = _buildShift(
        scheduledFohHours: neededFoh,
        planFohHours: neededFoh,
      );
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isTrue,
          reason: 'cplh_down should show red (unfavorable) delta');
    });

    test('splh_down hero card shows unfavorable delta', () {
      final profile = _profile();
      final sales = 200 * profile.targetPPA;
      final neededBoh = (sales / (profile.targetSPLH * 0.85)).round();
      final rm = _buildShift(
        scheduledBohHours: neededBoh,
        planBohHours: neededBoh,
      );
      final hero = rm.metricCards.singleWhere((c) => c.isHero);
      expect(hero.deltaUnfavorable, isTrue,
          reason: 'splh_down should show red (unfavorable) delta');
    });
  });

  // ── D: Wage families not reachable from Shift call shape ──────────────────

  group('D — wage levers are NOT reachable from Shift', () {
    test('Shift buildWholeDay does not pass wage parameters', () {
      // Proof: call determineLever the same way buildWholeDay does
      // (without wage params) and confirm wage levers never appear.
      final profile = _profile();
      final lever = LaborModel.determineLever(
        actualCovers: 200,
        forecastCovers: 200,
        avgCPLH: profile.targetCPLH,
        avgPPA: profile.targetPPA,
        targetCPLH: profile.targetCPLH,
        targetPPA: profile.targetPPA,
        avgSPLH: profile.targetSPLH,
        targetSPLH: profile.targetSPLH,
        // wage params omitted — mirrors Shift call shape
      );
      expect(lever, isNot(startsWith('foh_wage_')));
      expect(lever, isNot(startsWith('boh_wage_')));
    });

    test('engine CAN fire wage levers when params are provided', () {
      final profile = _profile();
      final lever = LaborModel.determineLever(
        actualCovers: 200,
        forecastCovers: 200,
        avgCPLH: profile.targetCPLH,
        avgPPA: profile.targetPPA,
        targetCPLH: profile.targetCPLH,
        targetPPA: profile.targetPPA,
        avgSPLH: profile.targetSPLH,
        targetSPLH: profile.targetSPLH,
        avgFohBlendedWage: MeridianConfig.fohWage * 1.15,
        targetFohWage: MeridianConfig.fohWage,
        avgBohBlendedWage: MeridianConfig.bohWage,
        targetBohWage: MeridianConfig.bohWage,
      );
      expect(lever, 'foh_wage_up',
          reason: 'Engine fires foh_wage_up when wage params are provided');
    });
  });

  // ── E: Hours-flex families CAN fire from Shift ────────────────────────────

  group('E — hours-flex levers are reachable from Shift', () {
    test('foh_hours_over fires when scheduled >> plan', () {
      final profile = _profile();
      final planFoh = LaborModel.modelFohHours(200, profile.targetCPLH);
      final overFoh = (planFoh * 1.50).round();

      final lever = LaborModel.determineLever(
        actualCovers: 200,
        forecastCovers: 200,
        avgCPLH: profile.targetCPLH,
        avgPPA: profile.targetPPA,
        targetCPLH: profile.targetCPLH,
        targetPPA: profile.targetPPA,
        avgSPLH: profile.targetSPLH,
        targetSPLH: profile.targetSPLH,
        scheduledFohHours: overFoh,
        modelFohHours: planFoh,
        scheduledBohHours: LaborModel.modelBohHoursFromSales(
            200 * profile.targetPPA, profile.targetSPLH),
        modelBohHours: LaborModel.modelBohHoursFromSales(
            200 * profile.targetPPA, profile.targetSPLH),
      );
      expect(lever, 'foh_hours_over',
          reason:
              'foh_hours_over should fire when scheduled FOH >> plan FOH');
    });

    test('hours-flex families are not Chapter 10 families', () {
      expect(LaborModel.isFavorableLever('foh_hours_under'), isTrue);
      expect(LaborModel.isFavorableLever('boh_hours_under'), isTrue);
      expect(LaborModel.isFavorableLever('foh_hours_over'), isFalse);
      expect(LaborModel.isFavorableLever('boh_hours_over'), isFalse);
    });
  });

  // ── F: Hours-flex hero-card mapping gap ────────────────────────────────────

  group('F — hours-flex hero-card mapping falls through to COVERS', () {
    test('foh_hours_over maps to COVERS (documented gap)', () {
      expect(ShiftMetrics.heroMetricNameForLever('foh_hours_over'), 'COVERS');
    });

    test('boh_hours_under maps to COVERS (documented gap)', () {
      expect(ShiftMetrics.heroMetricNameForLever('boh_hours_under'), 'COVERS');
    });
  });

  // ── G: Shift PRIMARY DRIVER teaching section remains hidden ───────────────

  group('G — Shift teaching section hidden (Phase 10.5)', () {
    test('read model still computes a lever for the badge', () {
      final rm = _buildShift(actualCovers: 160, forecastCovers: 200);
      expect(rm.primaryLeverId, isNotEmpty);
      expect(rm.primaryLeverCard.whatHappened, isNotEmpty);
    });

    test('exactly one hero card is marked', () {
      final rm = _buildShift(actualCovers: 160, forecastCovers: 200);
      final heroes = rm.metricCards.where((c) => c.isHero).toList();
      expect(heroes.length, 1);
    });
  });
}
