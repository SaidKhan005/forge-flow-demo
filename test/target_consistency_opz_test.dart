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
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/active_target_profile_notifier.dart';
import 'package:forge_and_flow/data/benchmark_tracker_read_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/widgets/zone_status_card.dart';

void main() {
  setUpAll(() {
    BenchmarkTrackerReadService.enableBridgeOnly();
  });

  tearDownAll(() {
    BenchmarkTrackerReadService.disableBridgeOnly();
  });

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

    const testCPLH = 6.25;
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
        historicalWeeklyAvgCovers: 1200,
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
      final expectedTheoreticalPct = LaborModel.theoreticalLaborPct(
        testCPLH,
        testSPLH,
        testPPA,
        testFohWage,
        testBohWage,
      );
      expect(notifier.theoreticalLaborPct,
          closeTo(expectedTheoreticalPct, 0.0001));
      expect(notifier.theoreticalLaborPct,
          isNot(closeTo(notifier.plan!.theoreticalLaborPct, 0.0001)),
          reason: '7.55q.8: weekly theoretical % is benchmark-owned, not '
              'the rounded plan-carried projection');

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
        find.text(BaselineData.derivedTargetCPLH.toStringAsFixed(2)),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.text(BaselineData.opzCeilingCPLH.toStringAsFixed(2)),
        findsAtLeastNWidgets(1),
      );
      expect(find.text(skipOffstage: false, label), findsOneWidget);
    });
  });

  // ── E. BaselineTracker widget ————————————————————————————————————————————

  // BaselineTracker now uses CustomScrollView with slivers. Pump extra
  // frames so all slivers (including below-fold content like OPZ FLOOR,
  // _BaselineTargetsCard, etc.) are built by the layout pipeline.
  Future<void> pumpBaseline(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('E. BaselineTracker widget', () {
    testWidgets(
        'paints from rangeGraphModel — correct labels, range, target, and CTA (no override)',
        (tester) async {
      BaselineData.clearManagerOverride();

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      // Graph title (7.55p.5: renamed to CPLH RANGE & TARGET)
      expect(find.text('CPLH RANGE & TARGET', skipOffstage: false),
          findsOneWidget);
      // CPLH TARGET tick label on the graph
      expect(find.text(skipOffstage: false, 'CPLH TARGET'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'TOTAL COVERS LAST 60 DAYS:'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'WEEKLY AVG COVERS'), findsNothing);
      expect(find.text(skipOffstage: false, BaselineData.historicalTotalCoversTracked.toString()), findsOneWidget);

      expect(find.text(skipOffstage: false, 'BEST CPLH'), findsNothing);
      expect(find.text(skipOffstage: false, 'WORST CPLH'), findsNothing);

      expect(find.text(skipOffstage: false, 'LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'BENCHMARK RANGE'), findsOneWidget);

      expect(find.text(skipOffstage: false, BaselineData.rangeGraphModel.displayRangeStartCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(skipOffstage: false, BaselineData.rangeGraphModel.displayRangeEndCPLH.toStringAsFixed(2)), findsWidgets);

      expect(find.text(skipOffstage: false, BaselineData.rangeGraphModel.targetCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(skipOffstage: false, BaselineData.baselineRangeValidation.statusLabel), findsWidgets);
      expect(find.text(skipOffstage: false, BaselineData.rangeGraphModel.recommendedExplanation), findsOneWidget);
      expect(find.text(skipOffstage: false, 'CHOOSE STAR SHIFTS'), findsOneWidget);

      expect(find.text(skipOffstage: false, 'OPZ FLOOR'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'OPZ CEILING'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'HEADROOM'), findsOneWidget);

      // Wage rows added in 7.55h
      expect(find.text(skipOffstage: false, 'FOH WAGE'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'BOH WAGE'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'BLENDED WAGE'), findsOneWidget);

      // 7.55p.5a: theoretical output uses explicit "THEORETICAL" labels
      // to avoid confusion with Shift's whole-day labor card reference line
      expect(find.text(skipOffstage: false, 'FOH THEORETICAL %'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'BOH THEORETICAL %'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'TOTAL THEORETICAL %'), findsOneWidget);

      // 2dp precision on targets card (7.55h)
      expect(find.text(skipOffstage: false, BaselineData.derivedTargetCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(skipOffstage: false, '\$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}'), findsOneWidget);
      // OPZ floor/ceiling at 2dp may match range bar endpoints (same data, no override)
      expect(find.text(skipOffstage: false, BaselineData.opzFloorCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(skipOffstage: false, BaselineData.opzCeilingCPLH.toStringAsFixed(2)), findsWidgets);

      // Old titles must be gone
      expect(find.text(skipOffstage: false, 'RECOMMENDED TARGET — 60 DAY RANGE'), findsNothing);
      expect(find.text(skipOffstage: false, 'CPLH RANGE — LAST 60 DAYS'), findsNothing);
      expect(find.text(skipOffstage: false, 'OPZ BAND — TARGET POSITION'), findsNothing);
      expect(find.text(skipOffstage: false, 'WORST'), findsNothing);
      expect(find.text(skipOffstage: false, 'BEST'), findsNothing);
      expect(find.text(skipOffstage: false, 'Below OPZ'), findsNothing);
      expect(find.text(skipOffstage: false, 'Above OPZ'), findsNothing);
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

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      expect(find.text(skipOffstage: false, 'LOWEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'HIGHEST CPLH LAST 60 DAYS'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'STAR SHIFT RANGE'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'BENCHMARK RANGE'), findsNothing);

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

      expect(m.title, equals('CPLH RANGE & TARGET'));
      expect(m.recommendedExplanation, isNotEmpty);
      expect(m.overrideLabel, equals('CHOOSE STAR SHIFTS'));
    });
  });

  // ── G. Profile-precedence on _BaselineTargetsCard (7.55p.5a) ──────────────

  group('G. _BaselineTargetsCard prefers ActiveTargetProfile', () {
    // Intentionally different from BaselineData values to prove precedence.
    const testProfile = ActiveTargetProfile(
      targetProfileId: 'test_profile',
      restaurantId: 'test',
      sourceType: 'system_baseline',
      targetCPLH: 5.55,
      targetSPLH: 199.0,
      targetPPA: 38.50,
      fohWage: 19.00,
      bohWage: 24.00,
      opzFloorCPLH: 4.80,
      opzCeilingCPLH: 6.30,
      theoreticalFohLaborPct: 9.2,
      theoreticalBohLaborPct: 12.1,
      theoreticalLaborPct: 21.3,
      builtAt: '2026-04-13T00:00:00Z',
    );

    testWidgets('with profile: targets card shows profile values, not BaselineData',
        (tester) async {
      final notifier = ActiveTargetProfileNotifier.fromProfile(testProfile);

      await tester.pumpWidget(
        ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(
          value: notifier,
          child: const MaterialApp(home: BaselineTracker()),
        ),
      );

      // Profile target CPLH (5.55) should appear; BaselineData's should not
      // dominate the targets card.
      expect(find.text(skipOffstage: false, '5.55'), findsWidgets,
          reason: 'profile targetCPLH should be displayed');

      // Profile OPZ bounds
      expect(find.text(skipOffstage: false, '4.80'), findsWidgets,
          reason: 'profile opzFloorCPLH should be displayed');
      expect(find.text(skipOffstage: false, '6.30'), findsWidgets,
          reason: 'profile opzCeilingCPLH should be displayed');

      // Profile wages
      expect(find.text(skipOffstage: false, '\$19.00'), findsOneWidget,
          reason: 'profile fohWage should be displayed');
      expect(find.text(skipOffstage: false, '\$24.00'), findsOneWidget,
          reason: 'profile bohWage should be displayed');

      // Profile theoretical output — FOH / BOH / total
      expect(find.text(skipOffstage: false, '9.2%'), findsOneWidget,
          reason: 'profile FOH theoretical % should be displayed');
      expect(find.text(skipOffstage: false, '12.1%'), findsOneWidget,
          reason: 'profile BOH theoretical % should be displayed');
      expect(find.text(skipOffstage: false, '21.3%'), findsOneWidget,
          reason: 'profile TOTAL theoretical % should be displayed');

      // Profile target PPA
      expect(find.text(skipOffstage: false, '\$38.50'), findsOneWidget,
          reason: 'profile targetPPA should be displayed');

      notifier.dispose();
    });

    testWidgets('without profile: targets card falls back to BaselineData safely',
        (tester) async {
      // Mount without any provider — the card uses BaselineData fallbacks.
      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      // Card renders without error.
      expect(find.text(skipOffstage: false, 'OPZ FLOOR'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'OPZ CEILING'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'TOTAL THEORETICAL %'), findsOneWidget);

      // Values come from BaselineData fallbacks.
      expect(find.text(skipOffstage: false, BaselineData.opzFloorCPLH.toStringAsFixed(2)), findsWidgets);
      expect(find.text(skipOffstage: false, BaselineData.opzCeilingCPLH.toStringAsFixed(2)), findsWidgets);
    });
  });

  // ── H. Benchmark graph degenerate-state rendering (7.55p.5h) ──────────────
  //
  // The `_CplhRangeBar` widget should surface the honest fallback badge
  // and copy when the recommendation service flags the cohort as
  // insufficient or weak/wide. Healthy state should keep the existing
  // GOOD OPZ RANGE badge.

  group('H. Benchmark graph degenerate-state rendering (7.55p.5h)', () {
    tearDown(() {
      BaselineData.clearManagerOverride();
      BaselineData.clearRecommendationSignals();
    });

    testWidgets(
        'insufficient signals → RANGE UNCONFIRMED badge + honest fallback copy',
        (tester) async {
      BaselineData.clearManagerOverride();
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      expect(find.text(skipOffstage: false, 'RANGE UNCONFIRMED'), findsOneWidget);
      expect(
          find.textContaining('Not enough recent shifts yet'),
          findsOneWidget);
      expect(
          find.textContaining('placeholder range until more shift history builds'),
          findsOneWidget);
      // The legacy GOOD OPZ RANGE badge must not leak through when
      // recommendation signals say insufficient.
      expect(find.text(skipOffstage: false, 'GOOD OPZ RANGE'), findsNothing);

      // 7.55p.5h-review-fix: the drawn target tick reflects the
      // signal's Config Default placeholder (4.5), not the legacy
      // seed-selected derivation (~4.58).
      expect(find.text(skipOffstage: false, '4.50'), findsWidgets);
    });

    testWidgets(
        'weak + wide union band → RANGE TOO WIDE TO TEACH badge + copy',
        (tester) async {
      BaselineData.clearManagerOverride();
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 1.40,
          selectedShiftCount: 12,
          rangeFloorCPLH: 3.8,
          rangeCeilingCPLH: 5.2,
          targetCPLH: 4.5,
        ),
      );

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      expect(find.text(skipOffstage: false, 'RANGE TOO WIDE TO TEACH'), findsOneWidget);
      expect(
          find.textContaining('Lunch, dinner, and late night'),
          findsOneWidget);
      expect(
          find.textContaining('Use this as a broad guide for now'),
          findsOneWidget);
      // Stale manager-override copy must not leak through.
      expect(
          find.textContaining('Tighten to one clean standard'),
          findsNothing);
    });

    testWidgets('weak + narrow union band → RANGE UNCERTAIN badge + copy',
        (tester) async {
      BaselineData.clearManagerOverride();
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'weak',
          unionBandWidth: 0.40,
          selectedShiftCount: 4,
          rangeFloorCPLH: 4.4,
          rangeCeilingCPLH: 4.8,
          targetCPLH: 4.6,
        ),
      );

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      expect(find.text(skipOffstage: false, 'RANGE UNCERTAIN'), findsOneWidget);
      expect(
          find.textContaining('clean operating range yet'),
          findsOneWidget);
      expect(
          find.textContaining('benchmark will settle into a clearer working range'),
          findsOneWidget);
    });

    testWidgets('strong signals → existing GOOD OPZ RANGE badge, no fallback',
        (tester) async {
      BaselineData.clearManagerOverride();
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'strong',
          unionBandWidth: 0.60,
          selectedShiftCount: 10,
          rangeFloorCPLH: 4.30,
          rangeCeilingCPLH: 4.90,
          targetCPLH: 4.58,
        ),
      );

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      expect(find.text(skipOffstage: false, 'GOOD OPZ RANGE'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'RANGE UNCONFIRMED'), findsNothing);
      expect(find.text(skipOffstage: false, 'RANGE UNCERTAIN'), findsNothing);
      expect(find.text(skipOffstage: false, 'RANGE TOO WIDE TO TEACH'), findsNothing);
    });

    testWidgets('manager override wins — graph shows STAR SHIFT RANGE '
        'and legacy badge even when insufficient signals linger',
        (tester) async {
      BaselineData.applyRecommendationSignals(
        const BaselineRecommendationSignals(
          sourceType: 'cycle_recommended_insufficient',
          overallQuality: 'insufficient',
          unionBandWidth: 0,
          selectedShiftCount: 0,
          rangeFloorCPLH: 3.5,
          rangeCeilingCPLH: 5.8,
          targetCPLH: 4.5,
        ),
      );
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

      await pumpBaseline(
          tester, const MaterialApp(home: BaselineTracker()));

      // Manager-override copy / STAR SHIFT RANGE inner label remain.
      expect(find.text(skipOffstage: false, 'STAR SHIFT RANGE'), findsOneWidget);
      expect(find.text(skipOffstage: false, 'GOOD OPZ RANGE'), findsOneWidget);
      // Recommendation-signal badges must not fire in manager-override mode.
      expect(find.text(skipOffstage: false, 'RANGE UNCONFIRMED'), findsNothing);
      expect(find.text(skipOffstage: false, 'RANGE UNCERTAIN'), findsNothing);
      expect(find.text(skipOffstage: false, 'RANGE TOO WIDE TO TEACH'), findsNothing);
    });
  });

  // ── D. Shared blended-wage seam (7.55q.3) ────────────────────────────────
  //
  // Drift 2 + Drift 3 fix from 7.55q.1: blended wage is a Benchmark-owned
  // target metric. There must be ONE shared seam at the active-target
  // boundary; Benchmark and Variance WTD must read that same seam and
  // produce the same number for the same active target state.
  //
  //   D1. The static seam is cover-independent (matches the cancellation
  //       proof in the phase doc).
  //   D2. The profile getter wraps the static seam.
  //   D3. WeekData.theoreticalBlendedWage delegates to the same seam
  //       (no per-surface drift for the same target inputs).
  //   D4. Same active target state → Benchmark and WTD blended wage
  //       agree numerically.
  //   D5. Honest zero-input boundary returns 0.0 (no NaN / divide-by-zero).

  group('D. 7.55q.3 — shared benchmark blended-wage seam', () {
    const fohWage = 16.50;
    const bohWage = 21.35;
    const cplh = 4.5;
    const splh = 180.0;
    const ppa = 42.0;

    test('D1: static seam is cover-independent — pure function of '
        'CPLH/SPLH/PPA/wages, no demand input', () {
      final fohHourBasis = 1.0 / cplh;
      final bohHourBasis = ppa / splh;
      final expected = (fohHourBasis * fohWage + bohHourBasis * bohWage) /
          (fohHourBasis + bohHourBasis);

      final seam = ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        fohWage: fohWage,
        bohWage: bohWage,
      );
      expect(seam, closeTo(expected, 0.001));
    });

    test('D2: profile.targetBlendedWage wraps the static seam', () {
      const profile = ActiveTargetProfile(
        targetProfileId: 'q3-test',
        restaurantId: 'q3-test-r',
        sourceType: 'system_baseline',
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCPLH: 0,
        opzCeilingCPLH: 0,
        theoreticalFohLaborPct: 0,
        theoreticalBohLaborPct: 0,
        theoreticalLaborPct: 0,
        builtAt: '',
      );
      final fromGetter = profile.targetBlendedWage;
      final fromStatic = ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        fohWage: fohWage,
        bohWage: bohWage,
      );
      expect(fromGetter, equals(fromStatic));
    });

    test('D3: WeekData.theoreticalBlendedWage delegates to the same seam '
        '(plan hours and actual covers do NOT affect it)', () {
      // Build a WeekData with pathological plan hours: 250 FOH / 25 BOH
      // (10:1 mix). If WeekData were still computing its own hour-weighted
      // value, the result would be ~ ((250*16.5 + 25*21.35) / 275) ≈ 16.94
      // — quite different from the canonical seam. The new code must NOT
      // produce that.
      final data = WeekData(
        weekId: 'q3-test',
        weekLabel: 'Q3 Test',
        totalCovers: 500,
        totalSales: 500 * 41.79,
        totalFohHours: 110,
        totalBohHours: 115,
        shiftsCompleted: 7,
        shiftsTotal: 14,
        wtdForecastCovers: 500,
        totalWeekForecastCovers: 1000,
        primaryLeverId: 'covers_down',
        planFohHoursWtd: 250,
        planBohHoursWtd: 25,
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        targetFohWage: fohWage,
        targetBohWage: bohWage,
        theoreticalFohLaborPct: 9.2,
        theoreticalBohLaborPct: 12.1,
        theoreticalLaborPct: 21.3,
      );
      final canonical = ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        fohWage: fohWage,
        bohWage: bohWage,
      );
      expect(data.theoreticalBlendedWage, closeTo(canonical, 0.001));

      // Sanity: the OLD plan-hour-weighted value would have been ~16.94,
      // distinctly different from the canonical ~18.95. Asserting
      // closeTo(canonical) guarantees the old behaviour is gone.
      final oldStylePlanWeighted = (250 * fohWage + 25 * bohWage) / 275;
      expect(data.theoreticalBlendedWage,
          isNot(closeTo(oldStylePlanWeighted, 0.5)),
          reason:
              'WeekData must NOT route through the old plan-hour-weighted '
              'derivation — the new shared seam is plan-hour-independent');
    });

    test('D4: Benchmark and Variance WTD show the same blended wage for '
        'the same active target state — no per-surface drift', () {
      const profile = ActiveTargetProfile(
        targetProfileId: 'q3-cross-surface',
        restaurantId: 'q3-cross-r',
        sourceType: 'system_baseline',
        targetCPLH: cplh,
        targetSPLH: splh,
        targetPPA: ppa,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCPLH: 0,
        opzCeilingCPLH: 0,
        theoreticalFohLaborPct: 0,
        theoreticalBohLaborPct: 0,
        theoreticalLaborPct: 0,
        builtAt: '',
      );
      // Benchmark reads the profile getter directly.
      final benchmarkBlendedWage = profile.targetBlendedWage;

      // Variance WTD reads via WeekData with profile-derived target inputs
      // — same path ShiftService uses to construct WeekData at runtime.
      final wtd = WeekData(
        weekId: 'q3-cross', weekLabel: 'X',
        totalCovers: 800, totalSales: 800 * 41.79,
        totalFohHours: 120, totalBohHours: 130,
        shiftsCompleted: 5, shiftsTotal: 14,
        wtdForecastCovers: 800, totalWeekForecastCovers: 1200,
        primaryLeverId: 'covers_down',
        targetCPLH: profile.targetCPLH,
        targetSPLH: profile.targetSPLH,
        targetPPA: profile.targetPPA,
        targetFohWage: profile.fohWage,
        targetBohWage: profile.bohWage,
        theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
        theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
        theoreticalLaborPct: profile.theoreticalLaborPct,
      );
      final wtdBlendedWage = wtd.theoreticalBlendedWage;

      expect(benchmarkBlendedWage, closeTo(wtdBlendedWage, 0.001),
          reason: '7.55q.3 conformance: Benchmark and WTD must read the '
              'same shared seam and show the same number');
    });

    test('D5: zero-input safety — returns 0.0 when targetCPLH or '
        'targetSPLH is non-positive (no NaN / divide-by-zero)', () {
      expect(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: 0,
            targetSPLH: splh,
            targetPPA: ppa,
            fohWage: fohWage,
            bohWage: bohWage,
          ),
          0.0);
      expect(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: cplh,
            targetSPLH: 0,
            targetPPA: ppa,
            fohWage: fohWage,
            bohWage: bohWage,
          ),
          0.0);
      expect(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: -1,
            targetSPLH: splh,
            targetPPA: ppa,
            fohWage: fohWage,
            bohWage: bohWage,
          ),
          0.0);
    });
  });
}


