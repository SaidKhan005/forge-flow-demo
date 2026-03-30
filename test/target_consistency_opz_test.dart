// ─── Target Consistency + OPZ Tests ──────────────────────────────────────────
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
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/screens/baseline_tracker.dart';
import 'package:forge_flow_demo/screens/schedule_builder.dart';
import 'package:forge_flow_demo/services/labor_model.dart';
import 'package:forge_flow_demo/widgets/zone_status_card.dart';

void main() {
  // ── A. BaselineData OPZ validation ────────────────────────────────────────

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

  // ── B. ScheduleForecastNotifier target consistency ─────────────────────────

  group('B. ScheduleForecastNotifier uses baseline-derived targets', () {
    late ScheduleForecastNotifier notifier;

    setUp(() {
      notifier = ScheduleForecastNotifier();
    });

    tearDown(() {
      notifier.dispose();
    });

    test('requiredFohHours matches LaborModel with derivedTargetCPLH', () {
      final expected = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        BaselineData.derivedTargetCPLH,
      );
      expect(notifier.requiredFohHours, equals(expected));
    });

    test('requiredFohHours differs from config-hardcoded target', () {
      final withConfig = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        MeridianConfig.targetCPLH,
      );
      final withBaseline = LaborModel.modelFohHours(
        notifier.weeklyCovers,
        BaselineData.derivedTargetCPLH,
      );
      expect(withBaseline, isNot(equals(withConfig)));
    });

    test('requiredBohHours matches LaborModel with derivedTargetPPA and derivedTargetSPLH', () {
      final expected = LaborModel.modelBohHours(
        notifier.weeklyCovers,
        BaselineData.derivedTargetPPA,
        BaselineData.derivedTargetSPLH,
      );
      expect(notifier.requiredBohHours, equals(expected));
    });

    test('theoreticalLaborPct equals BaselineData.derivedTheoreticalLaborPct', () {
      expect(
        notifier.theoreticalLaborPct,
        closeTo(BaselineData.derivedTheoreticalLaborPct, 0.0001),
      );
    });

    test('theoreticalLaborPct differs from config-hardcoded computation', () {
      final configPct = LaborModel.theoreticalLaborPct(
        MeridianConfig.targetCPLH,
        MeridianConfig.targetSPLH,
        MeridianConfig.targetPPA,
        MeridianConfig.fohWage,
        MeridianConfig.bohWage,
      );
      expect(notifier.theoreticalLaborPct, isNot(closeTo(configPct, 0.0001)));
    });
  });

  // ── C. OPZ zone label helpers ──────────────────────────────────────────────

  group('C. opzStatusLabelForCplh returns correct labels', () {
    test('below floor → BELOW OPZ', () {
      expect(
        BaselineData.opzStatusLabelForCplh(BaselineData.opzFloorCPLH - 0.1),
        equals('BELOW OPZ'),
      );
    });

    test('inside band → IN OPZ', () {
      final mid = (BaselineData.opzFloorCPLH + BaselineData.opzCeilingCPLH) / 2;
      expect(BaselineData.opzStatusLabelForCplh(mid), equals('IN OPZ'));
    });

    test('above ceiling → ABOVE OPZ', () {
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

  // ── D. Baseline OPZ row values ─────────────────────────────────────────────

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

    test('headroom is positive — target sits below historically-derived ceiling', () {
      expect(BaselineData.opzHeadroomCPLH, greaterThan(0));
    });
  });

  // ── E. ZoneStatusCard widget ───────────────────────────────────────────────

  group('E. ZoneStatusCard widget', () {
    testWidgets('shows target, ceiling, status label, and sub-label from centralized OPZ logic',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ZoneStatusCard())),
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
        find.text(BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH)),
        findsOneWidget,
      );
      // Sub-label
      expect(
        find.text(BaselineData.opzSubLabelForCplh(ShiftSnapshot.actualCPLH)),
        findsOneWidget,
      );
    });
  });

  // ── F. BaselineTracker widget ──────────────────────────────────────────────

  group('F. BaselineTracker widget', () {
    testWidgets(
        'paints from rangeGraphModel — correct labels, range, target, and CTA (no override)',
        (tester) async {
      // Ensure no override is active
      BaselineData.clearManagerOverride();

      await tester.pumpWidget(
        const MaterialApp(home: BaselineTracker()),
      );

      // Graph title
      expect(find.text('RECOMMENDED TARGET'), findsOneWidget);

      // Summary cards — historical context, plain count (not dollar-formatted)
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

      // Endpoint labels — always historical
      expect(find.text('LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text('HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);

      // Inner range label — no override = BENCHMARK RANGE
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
      expect(find.text('RECOMMENDED TARGET — 60 DAY RANGE'), findsNothing);
      expect(find.text('CPLH RANGE — LAST 60 DAYS'), findsNothing);
      expect(find.text('OPZ BAND — TARGET POSITION'), findsNothing);

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

  // ── G. BaselineRangeGraphModel semantics ───────────────────────────────────

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
