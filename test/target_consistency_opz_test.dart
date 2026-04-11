// ——— Target Consistency + OPZ Tests ——————————————————————————————————————————
// Prompt 4.1 verification:
//   - OPZ gauge inputs are fully centralized through BaselineData
//   - Baseline-derived targets flow through Schedule and Shift
//   - OPZ helpers behave correctly against the currently configured band
//   - ZoneStatusCard and BaselineTracker render OPZ content from the same source
// Prompt 4.5 addition:
//   - BaselineRangeGraphModel uses true min/max CPLH (not averages)
//   - Positions are normalized within the true lived range
//   - Target-inside-OPZ truth is correctly derived
// Prompt 4.6c addition:
//   - OPZ is historically derived from the same selected record set as the target
//   - MeridianConfig OPZ constants are legacy-only; BaselineData is runtime truth

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/widgets/zone_status_card.dart';

void main() {
  // ── A. BaselineData OPZ validation ————————————————————————————————————————

  group('A. BaselineData OPZ validation', () {
    test('opzValidation exposes correct floor, ceiling, target, headroom, status', () {
      final v = BaselineData.opzValidation;
      expect(v.floorCPLH, equals(BaselineData.opzFloorCPLH));
      expect(v.ceilingCPLH, equals(BaselineData.opzCeilingCPLH));
      expect(v.targetCPLH, closeTo(BaselineData.derivedTargetCPLH, 0.001));
      expect(v.headroomCPLH,
          closeTo(BaselineData.opzCeilingCPLH - BaselineData.derivedTargetCPLH, 0.001));
      expect(v.usedPct, greaterThanOrEqualTo(0));
      expect(v.usedPct, lessThanOrEqualTo(100));
      expect(v.statusLabel, isNotEmpty);
      expect(v.message, isNotEmpty);
      if (v.status == 'in_zone') {
        expect(v.showWarning, isFalse);
      } else {
        expect(v.showWarning, isTrue);
      }
    });

    test('headroom and OPZ bounds are historically derived from selected records', () {
      expect(BaselineData.opzHeadroomCPLH,
          closeTo(BaselineData.opzCeilingCPLH - BaselineData.derivedTargetCPLH, 0.001));

      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMin = selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
      final selectedMax = selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
      expect(BaselineData.opzFloorCPLH, equals(selectedMin));
      expect(BaselineData.opzCeilingCPLH, equals(selectedMax));

      expect(BaselineData.derivedTargetCPLH, greaterThanOrEqualTo(BaselineData.opzFloorCPLH));
      expect(BaselineData.derivedTargetCPLH, lessThanOrEqualTo(BaselineData.opzCeilingCPLH));
    });

    test('opzStatusForCplh returns correct zone classification', () {
      for (final entry in <double, String>{
        BaselineData.opzFloorCPLH - 0.1: 'below',
        (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2: 'in',
        BaselineData.opzCeilingCPLH + 0.1: 'above',
      }.entries) {
        expect(BaselineData.opzStatusForCplh(entry.key), equals(entry.value),
            reason: 'CPLH ${entry.key} should be ${entry.value}');
      }
    });
  });

  // ── B. ScheduleForecastNotifier target consistency ————————————————————————

  group('B. ScheduleForecastNotifier uses injected active-target values', () {
    late ScheduleForecastNotifier notifier;

    const testCPLH = 4.75;
    const testPPA = 43.0;
    const testSPLH = 185.0;
    const testFohWage = 17.00;
    const testBohWage = 22.00;
    setUp(() {
      notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
      );
    });

    tearDown(() {
      notifier.dispose();
    });

    test('hours and labor outputs use injected targets, not BaselineData', () {
      // FOH hours
      final expectedFoh = LaborModel.modelFohHours(notifier.weeklyCovers, testCPLH);
      expect(notifier.requiredFohHours, equals(expectedFoh));
      expect(notifier.requiredFohHours,
          isNot(equals(LaborModel.modelFohHours(notifier.weeklyCovers, MeridianConfig.targetCPLH))));

      // BOH hours
      final expectedBoh = LaborModel.modelBohHours(notifier.weeklyCovers, testPPA, testSPLH);
      expect(notifier.requiredBohHours, equals(expectedBoh));

      // Labor %
      expect(notifier.plan, isNotNull);
      expect(notifier.theoreticalLaborPct,
          closeTo(notifier.plan!.theoreticalLaborPct, 0.0001));

      // FOH labor dollars
      expect(notifier.forecastedFohLaborDollar,
          closeTo(notifier.requiredFohHours * testFohWage, 0.01));
    });

  });

  // ── C. OPZ zone label helpers ——————————————————————————————————————————————

  group('C. opzStatusLabelForCplh returns correct labels', () {
    test('below/in/above zone labels and sub-labels', () {
      for (final entry in <double, String>{
        BaselineData.opzFloorCPLH - 0.1: 'BELOW OPZ',
        (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2: 'IN OPZ',
        BaselineData.opzCeilingCPLH + 0.1: 'ABOVE OPZ',
      }.entries) {
        expect(BaselineData.opzStatusLabelForCplh(entry.key), equals(entry.value),
            reason: 'Label for CPLH ${entry.key}');
      }
      final mid = (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2;
      expect(BaselineData.opzSubLabelForCplh(mid).toLowerCase(), contains('opz'));
    });
  });

  // ── D. ZoneStatusCard widget ——————————————————————————————————————————————

  group('E. ZoneStatusCard widget', () {
    testWidgets('shows target, ceiling, and status label from centralized OPZ logic',
        (tester) async {
      final testCPLH = ShiftSnapshot.actualCPLH;
      final status = BaselineData.opzStatusForCplh(testCPLH);
      final label = BaselineData.opzStatusLabelForCplh(testCPLH);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ZoneStatusCard(
          currentCPLH: testCPLH,
          opzFloorCPLH: BaselineData.opzFloorCPLH,
          opzCeilingCPLH: BaselineData.opzCeilingCPLH,
          targetCPLH: BaselineData.derivedTargetCPLH,
          opzStatus: status,
          opzLabel: label,
          opzSubLabel: BaselineData.opzSubLabelForCplh(testCPLH),
        ))),
      );

      expect(
        find.text(BaselineData.derivedTargetCPLH.toStringAsFixed(1)),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.text(BaselineData.opzCeilingCPLH.toStringAsFixed(1)),
        findsAtLeastNWidgets(1),
      );
      expect(find.text(label), findsOneWidget);
    });
  });

  // ── E. BaselineTracker widget ————————————————————————————————————————————

  group('E. BaselineTracker widget', () {
    testWidgets(
        'paints from rangeGraphModel — correct labels, range, target, and CTA (no override)',
        (tester) async {
      BaselineData.clearManagerOverride();

      await tester.pumpWidget(
        const MaterialApp(home: BaselineTracker()),
      );

      // CPLH TARGET appears twice: range bar title + target tick label
      expect(find.text('CPLH TARGET'), findsWidgets);
      expect(find.text('TOTAL COVERS LAST 60 DAYS'), findsOneWidget);
      expect(find.text('WEEKLY AVG COVERS'), findsNothing);
      expect(find.text(BaselineData.historicalTotalCoversTracked.toString()), findsOneWidget);

      expect(find.text('BEST CPLH'), findsNothing);
      expect(find.text('WORST CPLH'), findsNothing);

      expect(find.text('LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('BENCHMARK RANGE'), findsOneWidget);

      expect(find.text(BaselineData.rangeGraphModel.displayRangeStartCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(BaselineData.rangeGraphModel.displayRangeEndCPLH.toStringAsFixed(2)), findsWidgets);

      // CPLH TARGET appears twice: range bar title + target tick label
      expect(find.text('CPLH TARGET'), findsWidgets);
      expect(find.text(BaselineData.rangeGraphModel.targetCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(BaselineData.baselineRangeValidation.statusLabel), findsWidgets);
      expect(find.text(BaselineData.rangeGraphModel.recommendedExplanation), findsOneWidget);
      expect(find.text('CHOOSE STAR SHIFTS'), findsOneWidget);

      expect(find.text('OPZ FLOOR'), findsOneWidget);
      expect(find.text('OPZ CEILING'), findsOneWidget);
      expect(find.text('HEADROOM'), findsOneWidget);

      // Wage rows added in 7.55h
      expect(find.text('FOH WAGE'), findsOneWidget);
      expect(find.text('BOH WAGE'), findsOneWidget);
      expect(find.text('BLENDED WAGE'), findsOneWidget);

      // 2dp precision on targets card (7.55h)
      expect(find.text(BaselineData.derivedTargetCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text('\$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}'), findsOneWidget);
      // OPZ floor/ceiling at 2dp may match range bar endpoints (same data, no override)
      expect(find.text(BaselineData.opzFloorCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(BaselineData.opzCeilingCPLH.toStringAsFixed(2)), findsWidgets);

      // Old titles must be gone
      expect(find.text('RECOMMENDED TARGET — 60 DAY RANGE'), findsNothing);
      expect(find.text('CPLH RANGE — LAST 60 DAYS'), findsNothing);
      expect(find.text('OPZ BAND — TARGET POSITION'), findsNothing);
      expect(find.text('OPZ RANGE'), findsNothing);
      expect(find.text('WORST'), findsNothing);
      expect(find.text('BEST'), findsNothing);
      expect(find.text('Below OPZ'), findsNothing);
      expect(find.text('Above OPZ'), findsNothing);
    });

    testWidgets(
        'after override, graph keeps historical outer labels and shows STAR SHIFT RANGE inner label',
        (tester) async {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 44, covers: 240,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.9, splh: 183, ppa: 45, covers: 250,
            isSelected: true),
      ]);

      await tester.pumpWidget(
        const MaterialApp(home: BaselineTracker()),
      );

      expect(find.text('LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('STAR SHIFT RANGE'), findsOneWidget);
      expect(find.text('BENCHMARK RANGE'), findsNothing);

      BaselineData.clearManagerOverride();
    });
  });

  // ── F. BaselineRangeGraphModel semantics ——————————————————————————————————

  group('F. BaselineRangeGraphModel uses historical and active range', () {
    setUp(() {
      BaselineData.clearManagerOverride();
    });

    test('historical range bounds match true min/max CPLH', () {
      final m = BaselineData.rangeGraphModel;
      final histCplh = BaselineData.historicalContextRecords.map((r) => r.cplh).toList();
      expect(m.historicalRangeStartCPLH, equals(histCplh.reduce((a, b) => a < b ? a : b)));
      expect(m.historicalRangeEndCPLH, equals(histCplh.reduce((a, b) => a > b ? a : b)));
    });

    test('active range bounds match selected records min/max CPLH', () {
      final m = BaselineData.rangeGraphModel;
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      expect(m.activeRangeStartCPLH, equals(selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b)));
      expect(m.activeRangeEndCPLH, equals(selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b)));
    });

    test('target, positions, and labels are correct', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.targetCPLH, closeTo(BaselineData.derivedTargetCPLH, 0.0001));
      expect(m.displayRangeStartPosition, equals(0.0));
      expect(m.displayRangeEndPosition, equals(1.0));

      for (final pos in [m.activeRangeStartPosition, m.activeRangeEndPosition, m.targetPosition]) {
        expect(pos, greaterThanOrEqualTo(0.0));
        expect(pos, lessThanOrEqualTo(1.0));
      }
      expect(m.activeRangeStartPosition, lessThanOrEqualTo(m.activeRangeEndPosition));

      expect(m.title, equals('CPLH TARGET'));
      expect(m.recommendedExplanation, isNotEmpty);
      expect(m.overrideLabel, equals('CHOOSE STAR SHIFTS'));
    });
  });
}
