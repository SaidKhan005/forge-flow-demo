// Prompt 7.11 — Shift Dynamic Truth Tests
//
// Verifies that the Shift screen's highlighted metric card and bottom
// teaching line follow the real active lever from LaborModel.determineLever
// instead of static demo wiring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/data/shift_data_source.dart';
import 'package:forge_flow_demo/data/week_data_notifier.dart';
import 'package:forge_flow_demo/screens/shift_dashboard.dart';
import 'package:forge_flow_demo/services/labor_model.dart';

void main() {
  // ── A: primary lever matches LaborModel.determineLever ────────────────────

  group('A — ShiftSnapshot.primaryLeverId', () {
    test('matches LaborModel.determineLever with same inputs', () {
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
      expect(ShiftSnapshot.primaryLeverId, equals(expected));
    });
  });

  // ── B: primary lever card resolves from the id ────────────────────────────

  group('B — ShiftSnapshot.primaryLeverCard', () {
    test('card id matches primaryLeverId', () {
      expect(ShiftSnapshot.primaryLeverCard.id,
          equals(ShiftSnapshot.primaryLeverId));
    });
  });

  // ── C: hero mapping helper works for all lever families ───────────────────

  group('C — heroMetricNameForLever', () {
    test('covers_down → COVERS', () {
      expect(ShiftMetrics.heroMetricNameForLever('covers_down'), 'COVERS');
    });
    test('covers_up → COVERS', () {
      expect(ShiftMetrics.heroMetricNameForLever('covers_up'), 'COVERS');
    });
    test('ppa_down → PPA', () {
      expect(ShiftMetrics.heroMetricNameForLever('ppa_down'), 'PPA');
    });
    test('ppa_up → PPA', () {
      expect(ShiftMetrics.heroMetricNameForLever('ppa_up'), 'PPA');
    });
    test('cplh_down → CPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('cplh_down'), 'CPLH');
    });
    test('cplh_up → CPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('cplh_up'), 'CPLH');
    });
    test('splh_down → SPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('splh_down'), 'SPLH');
    });
    test('splh_up → SPLH', () {
      expect(ShiftMetrics.heroMetricNameForLever('splh_up'), 'SPLH');
    });
    test('foh_wage_up → BLENDED WAGE', () {
      expect(
          ShiftMetrics.heroMetricNameForLever('foh_wage_up'), 'BLENDED WAGE');
    });
    test('boh_wage_down → BLENDED WAGE', () {
      expect(ShiftMetrics.heroMetricNameForLever('boh_wage_down'),
          'BLENDED WAGE');
    });
  });

  // ── D: runtime Shift card set contains exactly one hero ───────────────────

  group('D — exactly one hero card', () {
    test('exactly one card has isHero == true', () {
      final cards = ShiftMetrics.cards;
      final heroes = cards.where((c) => c.isHero).toList();
      expect(heroes.length, equals(1));
    });
  });

  // ── E: hero card name matches active lever family ─────────────────────────

  group('E — hero card matches lever family', () {
    test('hero name matches heroMetricNameForLever(primaryLeverId)', () {
      final hero = ShiftMetrics.cards.singleWhere((c) => c.isHero);
      expect(hero.name,
          equals(ShiftMetrics.heroMetricNameForLever(
              ShiftSnapshot.primaryLeverId)));
    });
  });

  // ── F: Shift teaching line is aligned to active lever ─────────────────────

  group('F — teaching line alignment', () {
    test('primaryLeverCard.whatHappened is non-empty', () {
      expect(ShiftSnapshot.primaryLeverCard.whatHappened, isNotEmpty);
    });

    testWidgets('bottom teaching line shows active lever whatHappened',
        (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (_) => WeekDataNotifier(const StaticShiftDataSource()),
          child: const MaterialApp(
            home: Scaffold(body: ShiftDashboard()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The teaching line may overflow the viewport in test, so check via
      // text widget finder which matches the full string regardless of clip.
      final teachingText = ShiftSnapshot.primaryLeverCard.whatHappened;
      expect(
        find.text(teachingText, skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}
