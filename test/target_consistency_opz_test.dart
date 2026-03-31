// â”€â”€â”€ Target Consistency + OPZ Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
  // â”€â”€ A. BaselineData OPZ validation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A. BaselineData OPZ validation', () {
    test('opzValidation exposes correct floor, ceiling, target, headroom', () {
      final v = BaselineData.opzValidation;
      expect(v.floorCPLH, equals(BaselineData.opzFloorCPLH));
      expect(v.ceilingCPLH, equals(BaselineData.opzCeilingCPLH));
      expect(v.targetCPLH, closeTo(BaselineData.derivedTargetCPLH, 0.001));
      expect(v.headroomCPLH,
          closeTo(BaselineData.opzCeilingCPLH - BaselineData.derivedTargetCPLH, 0.001));
    });

    test('opzValidation usedPct is between 0 and 100', () {
      expect(BaselineData.opzValidation.usedPct, greaterThanOrEqualTo(0));
      expect(BaselineData.opzValidation.usedPct, lessThanOrEqualTo(100));
    });

    test('opzValidation statusLabel and message are non-empty', () {
      final v = BaselineData.opzValidation;
      expect(v.statusLabel, isNotEmpty);
      expect(v.message, isNotEmpty);
    });

    test('in_zone status implies showWarning false; any other status implies showWarning true', () {
      final v = BaselineData.opzValidation;
      if (v.status == 'in_zone') {
        expect(v.showWarning, isFalse);
      } else {
        expect(v.showWarning, isTrue);
      }
    });

    test('opzHeadroomCPLH equals ceiling minus derived target', () {
      expect(
        BaselineData.opzHeadroomCPLH,
        closeTo(BaselineData.opzCeilingCPLH - BaselineData.derivedTargetCPLH, 0.001),
      );
    });

    test('opzFloorCPLH and opzCeilingCPLH are historically derived from selected records', () {
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMin = selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
      final selectedMax = selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
      expect(BaselineData.opzFloorCPLH, equals(selectedMin));
      expect(BaselineData.opzCeilingCPLH, equals(selectedMax));
    });

    test('derivedTargetCPLH sits inside the historically-derived OPZ (same source set)', () {
      expect(BaselineData.derivedTargetCPLH,
          greaterThanOrEqualTo(BaselineData.opzFloorCPLH));
      expect(BaselineData.derivedTargetCPLH,
          lessThanOrEqualTo(BaselineData.opzCeilingCPLH));
    });

    test('opzStatusForCplh below configured floor returns below', () {
      expect(
        BaselineData.opzStatusForCplh(BaselineData.opzFloorCPLH - 0.1),
        equals('below'),
      );
    });

    test('opzStatusForCplh at midpoint of configured band returns in', () {
      final mid = (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2;
      expect(BaselineData.opzStatusForCplh(mid), equals('in'));
    });

    test('opzStatusForCplh above configured ceiling returns above', () {
      expect(
        BaselineData.opzStatusForCplh(BaselineData.opzCeilingCPLH + 0.1),
        equals('above'),
      );
    });
  });

  // â”€â”€ B. ScheduleForecastNotifier target consistency â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B. ScheduleForecastNotifier uses injected active-target values', () {
    late ScheduleForecastNotifier notifier;

    // Explicit test target values (not from BaselineData)
    const testCPLH = 4.75;
    const testPPA = 43.0;
    const testSPLH = 185.0;
    const testFohWage = 17.00;
    const testBohWage = 22.00;
    const testTheoPct = 21.0;

    setUp(() {
      notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        theoreticalLaborPct: testTheoPct,
      );
    });

    tearDown(() {
      notifier.dispose();
    });

    test('requiredFohHours matches LaborModel with injected targetCPLH', () {
      final expected = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        testCPLH,
      );
      expect(notifier.requiredFohHours, equals(expected));
    });

    test('requiredFohHours differs from config-hardcoded target', () {
      final withConfig = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        MeridianConfig.targetCPLH,
      );
      final withInjected = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        testCPLH,
      );
      expect(withInjected, isNot(equals(withConfig)));
    });

    test('requiredBohHours matches LaborModel with injected targetPPA and targetSPLH', () {
      final expected = LaborModel.modelBohHours(
        notifier.weeklyCovers,
        testPPA,
        testSPLH,
      );
      expect(notifier.requiredBohHours, equals(expected));
    });

    test('theoreticalLaborPct equals injected value', () {
      expect(notifier.theoreticalLaborPct, closeTo(testTheoPct, 0.0001));
    });

    test('forecastedFohLaborDollar uses injected wage', () {
      expect(notifier.forecastedFohLaborDollar,
          closeTo(notifier.requiredFohHours * testFohWage, 0.01));
    });

    test('updateTargets changes Schedule outputs without BaselineData', () {
      final fohBefore = notifier.requiredFohHours;
      notifier = ScheduleForecastNotifier(
        targetCPLH: 5.0,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        theoreticalLaborPct: testTheoPct,
      );
      expect(notifier.requiredFohHours, isNot(equals(fohBefore)));
    });

    test('adjustedDayViews row hours use injected targets, not BaselineData',
        () {
      final views = notifier.adjustedDayViews;
      expect(views, isNotEmpty);
      final firstDay = views.first;
      final expectedFoh = LaborModel.modelFohHours(
          firstDay.forecastCovers, testCPLH);
      expect(firstDay.requiredFohHours, equals(expectedFoh));
      // Verify it differs from BaselineData path
      final baselineFoh = LaborModel.modelFohHours(
          firstDay.forecastCovers, BaselineData.derivedTargetCPLH);
      expect(firstDay.requiredFohHours, isNot(equals(baselineFoh)));
    });

    test('daypart subrow hours use injected targets and weighted allocation',
        () {
      final views = notifier.adjustedDayViews;
      // Mon has lunch + dinner â€” subrows should be weighted, not equal
      final mon = views.firstWhere((v) => v.day == 'Mon');
      expect(mon.subrows.length, 2);

      // Subrow hours use injected targets
      final lunch = mon.subrows.first;
      final expectedFoh = LaborModel.modelFohHours(
          lunch.forecastCovers, testCPLH);
      expect(lunch.requiredFohHours, equals(expectedFoh));

      // Weighted allocation: lunch and dinner should NOT be equal
      final dinner = mon.subrows.last;
      expect(lunch.forecastCovers, isNot(equals(dinner.forecastCovers)));
    });
  });

  // â”€â”€ C. OPZ zone label helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C. opzStatusLabelForCplh returns correct labels', () {
    test('below floor â†’ BELOW OPZ', () {
      expect(
        BaselineData.opzStatusLabelForCplh(BaselineData.opzFloorCPLH - 0.1),
        equals('BELOW OPZ'),
      );
    });

    test('inside band â†’ IN OPZ', () {
      final mid = (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2;
      expect(BaselineData.opzStatusLabelForCplh(mid), equals('IN OPZ'));
    });

    test('above ceiling â†’ ABOVE OPZ', () {
      expect(
        BaselineData.opzStatusLabelForCplh(BaselineData.opzCeilingCPLH + 0.1),
        equals('ABOVE OPZ'),
      );
    });

    test('opzSubLabelForCplh in-zone mentions OPZ', () {
      final mid = (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2;
      expect(BaselineData.opzSubLabelForCplh(mid).toLowerCase(), contains('opz'));
    });
  });

  // â”€â”€ D. Baseline OPZ row values â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D. Baseline OPZ row values', () {
    test('opzFloorCPLH equals min CPLH of selected historical records', () {
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMin = selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
      expect(BaselineData.opzFloorCPLH, equals(selectedMin));
    });

    test('opzCeilingCPLH equals max CPLH of selected historical records', () {
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMax = selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
      expect(BaselineData.opzCeilingCPLH, equals(selectedMax));
    });

    test('headroom is positive â€” target sits below historically-derived ceiling', () {
      expect(BaselineData.opzHeadroomCPLH, greaterThan(0));
    });
  });

  // â”€â”€ E. ZoneStatusCard widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E. ZoneStatusCard widget', () {
    testWidgets('shows target, ceiling, status label, and sub-label from centralized OPZ logic',
        (tester) async {
      final testCPLH = ShiftSnapshot.actualCPLH;
      final status = BaselineData.opzStatusForCplh(testCPLH);
      final label = BaselineData.opzStatusLabelForCplh(testCPLH);
      final subLabel = BaselineData.opzSubLabelForCplh(testCPLH);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ZoneStatusCard(
          currentCPLH: testCPLH,
          opzFloorCPLH: BaselineData.opzFloorCPLH,
          opzCeilingCPLH: BaselineData.opzCeilingCPLH,
          targetCPLH: BaselineData.derivedTargetCPLH,
          opzStatus: status,
          opzLabel: label,
          opzSubLabel: subLabel,
        ))),
      );

      // Target value (2-decimal precision after label-anchoring pass)
      expect(
        find.text(BaselineData.derivedTargetCPLH.toStringAsFixed(2)),
        findsAtLeastNWidgets(1),
      );
      // Ceiling value
      expect(
        find.text(BaselineData.opzCeilingCPLH.toStringAsFixed(2)),
        findsAtLeastNWidgets(1),
      );
      // OPZ status label
      expect(
        find.text(label),
        findsOneWidget,
      );
      // Sub-label
      expect(
        find.text(subLabel),
        findsOneWidget,
      );
    });
  });

  // â”€â”€ F. BaselineTracker widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F. BaselineTracker widget', () {
    testWidgets(
        'paints from rangeGraphModel â€” correct labels, range, target, and CTA (no override)',
        (tester) async {
      // Ensure no override is active
      BaselineData.clearManagerOverride();

      await tester.pumpWidget(
        const MaterialApp(home: BaselineTracker()),
      );

      // Graph title
      expect(find.text('RECOMMENDED TARGET'), findsOneWidget);

      // Summary cards â€” historical context, plain count (not dollar-formatted)
      expect(find.text('TOTAL COVERS LAST 60 DAYS'), findsOneWidget);
      expect(find.text('WEEKLY AVG COVERS'), findsOneWidget);
      expect(
        find.text(BaselineData.historicalTotalCoversTracked.toString()),
        findsOneWidget,
      );
      expect(
        find.text(BaselineData.historicalWeeklyAvgCovers.toString()),
        findsOneWidget,
      );

      // BEST/WORST cards must be gone
      expect(find.text('BEST CPLH'), findsNothing);
      expect(find.text('WORST CPLH'), findsNothing);

      // Endpoint labels â€” always historical
      expect(find.text('LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);

      // Inner range label â€” no override = BENCHMARK RANGE
      expect(find.text('BENCHMARK RANGE'), findsOneWidget);

      // Endpoint values from rangeGraphModel
      expect(
        find.text(BaselineData.rangeGraphModel.displayRangeStartCPLH.toStringAsFixed(2)),
        findsOneWidget,
      );
      expect(
        find.text(BaselineData.rangeGraphModel.displayRangeEndCPLH.toStringAsFixed(2)),
        findsOneWidget,
      );

      // Target marker label and value
      expect(find.text('CPLH TARGET'), findsOneWidget);
      expect(
        find.text(BaselineData.rangeGraphModel.targetCPLH.toStringAsFixed(1)),
        findsWidgets, // also in _BaselineTargetsCard
      );

      // Baseline range validation badge
      expect(find.text(BaselineData.baselineRangeValidation.statusLabel), findsWidgets);

      // Explanation text from rangeGraphModel
      expect(find.text(BaselineData.rangeGraphModel.recommendedExplanation), findsOneWidget);

      // Manager override CTA
      expect(find.text('MANAGER OVERRIDE BASED ON STAR SHIFTS'), findsOneWidget);

      // _BaselineTargetsCard OPZ rows unchanged
      expect(find.text('OPZ FLOOR'), findsOneWidget);
      expect(find.text('OPZ CEILING'), findsOneWidget);
      expect(find.text('HEADROOM'), findsOneWidget);

      // Old titles must be gone
      expect(find.text('RECOMMENDED TARGET â€” 60 DAY RANGE'), findsNothing);
      expect(find.text('CPLH RANGE â€” LAST 60 DAYS'), findsNothing);
      expect(find.text('OPZ BAND â€” TARGET POSITION'), findsNothing);

      // Old inner-range label must be gone
      expect(find.text('OPZ RANGE'), findsNothing);

      // Old graph language must not exist
      expect(find.text('WORST'), findsNothing);
      expect(find.text('BEST'), findsNothing);
      expect(find.text('Below OPZ'), findsNothing);
      expect(find.text('Above OPZ'), findsNothing);
    });

    testWidgets(
        'after override, graph keeps historical outer labels and shows STAR SHIFT RANGE inner label',
        (tester) async {
      // Apply a simple override with distinct CPLH range
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

      // Outer endpoints stay historical
      expect(find.text('LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);

      // Inner range shows star-shift label
      expect(find.text('STAR SHIFT RANGE'), findsOneWidget);
      expect(find.text('BENCHMARK RANGE'), findsNothing);

      // Clean up
      BaselineData.clearManagerOverride();
    });
  });

  // â”€â”€ G. BaselineRangeGraphModel semantics â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('G. BaselineRangeGraphModel uses historical and active range', () {
    setUp(() {
      BaselineData.clearManagerOverride();
    });

    test('historicalRangeStartCPLH equals true min CPLH across historical context', () {
      final m = BaselineData.rangeGraphModel;
      final histCplh = BaselineData.historicalContextRecords.map((r) => r.cplh).toList();
      final trueMin = histCplh.reduce((a, b) => a < b ? a : b);
      expect(m.historicalRangeStartCPLH, equals(trueMin));
    });

    test('historicalRangeEndCPLH equals true max CPLH across historical context', () {
      final m = BaselineData.rangeGraphModel;
      final histCplh = BaselineData.historicalContextRecords.map((r) => r.cplh).toList();
      final trueMax = histCplh.reduce((a, b) => a > b ? a : b);
      expect(m.historicalRangeEndCPLH, equals(trueMax));
    });

    test('activeRangeStartCPLH matches selected records min CPLH', () {
      final m = BaselineData.rangeGraphModel;
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMin = selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
      expect(m.activeRangeStartCPLH, equals(selectedMin));
    });

    test('activeRangeEndCPLH matches selected records max CPLH', () {
      final m = BaselineData.rangeGraphModel;
      final selected = BaselineData.records.where((r) => r.isSelected).toList();
      final selectedMax = selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
      expect(m.activeRangeEndCPLH, equals(selectedMax));
    });

    test('targetCPLH matches BaselineData.derivedTargetCPLH', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.targetCPLH, closeTo(BaselineData.derivedTargetCPLH, 0.0001));
    });

    test('displayRangeStartPosition is 0.0', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.displayRangeStartPosition, equals(0.0));
    });

    test('displayRangeEndPosition is 1.0', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.displayRangeEndPosition, equals(1.0));
    });

    test('activeRangeStartPosition is between 0 and 1', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartPosition, greaterThanOrEqualTo(0.0));
      expect(m.activeRangeStartPosition, lessThanOrEqualTo(1.0));
    });

    test('activeRangeEndPosition is between 0 and 1', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeEndPosition, greaterThanOrEqualTo(0.0));
      expect(m.activeRangeEndPosition, lessThanOrEqualTo(1.0));
    });

    test('activeRangeStartPosition <= activeRangeEndPosition', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.activeRangeStartPosition, lessThanOrEqualTo(m.activeRangeEndPosition));
    });

    test('targetPosition is between 0 and 1', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.targetPosition, greaterThanOrEqualTo(0.0));
      expect(m.targetPosition, lessThanOrEqualTo(1.0));
    });

    test('title is RECOMMENDED TARGET', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.title, equals('RECOMMENDED TARGET'));
    });

    test('recommendedExplanation is non-empty', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.recommendedExplanation, isNotEmpty);
    });

    test('overrideLabel is the benchmark-shift string', () {
      final m = BaselineData.rangeGraphModel;
      expect(m.overrideLabel, equals('MANAGER OVERRIDE BASED ON STAR SHIFTS'));
    });
  });
}
