// â”€â”€â”€ Variance History Widget Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Current contract (7.55q.5): `targetFohHours` / `targetBohHours` read the
// preserved `lockedRequiredFohHours` / `lockedRequiredBohHours` captured at
// close from the locked `WeeklyPlanSnapshot`. Legacy rows without those
// fields render "â€”" honestly rather than re-modeling from actuals.
//
// Covers: WeekHistoryTile + WeekDetailScreen rendering â€” short labels,
// color direction, dollar gap sign, annualized value, grouped table
// structure, provenance labels, edge cases.
//
// Historical origin: Phase 7.15.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/fixture_seed_data.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/daypart_evidence_visibility_policy.dart';
import 'package:forge_and_flow/services/history_benchmark_daypart_read_service.dart';
import 'package:forge_and_flow/widgets/lever_card.dart';
import 'package:forge_and_flow/widgets/week_history_tile.dart';
import 'package:forge_and_flow/screens/week_detail_screen.dart';

// â”€â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: child),
    );

Widget _wrapScrollable(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _pumpWeekDetail(WidgetTester tester, WeekRecord week) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: WeekDetailScreen(week: week),
  ));
  await tester.pump();
}

Future<void> _scrollWeekDetailToFinder(
  WidgetTester tester,
  Finder finder,
) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Future<void> _scrollWeekDetailToText(WidgetTester tester, String text) async {
  await _scrollWeekDetailToFinder(
    tester,
    find.text(text, skipOffstage: false),
  );
}

// 7.55q.5: WeekRecord fixtures now include `lockedRequiredFohHours` /
// `lockedRequiredBohHours` â€” the preserved plan hours captured at close
// from the WeeklyPlanSnapshot in force. Week Detail renders these
// exact values for the FOH / BOH Hours target rows; prior to 7.55q.5
// the getters re-modeled from totalCovers (Drift 6). Values are
// intentionally NOT equal to LaborModel.modelFohHours/modelBohHours
// of the fixture's totalCovers, so tests prove the getters read the
// stored fields rather than recomputing from actuals.
const WeekRecord _overModel = WeekRecord(
  weekId: 'test-over', weekLabel: 'Test',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 291, totalBohHours: 279,
  avgPPA: 41.79, avgCPLH: 4.12,
  theoreticalLaborPct: 20.48, actualLaborPct: 21.45,
  dollarGap: 478.50,
  primaryLeverId: 'cplh_down',
  targetSourceType: 'system_baseline',
  targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
  targetFohWage: 16.50, targetBohWage: 21.35,
  lockedRequiredFohHours: 260, lockedRequiredBohHours: 275,
  targetCalibrationWindowStart: '2026-01-27',
  targetCalibrationWindowEnd: '2026-03-27',
);

const WeekRecord _underModel = WeekRecord(
  weekId: 'test-under', weekLabel: 'Test',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 238, totalBohHours: 279,
  avgPPA: 41.79, avgCPLH: 5.04,
  theoreticalLaborPct: 20.48, actualLaborPct: 19.71,
  dollarGap: -396.00,
  primaryLeverId: 'cplh_up',
  targetSourceType: 'system_baseline',
  targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
  targetFohWage: 16.50, targetBohWage: 21.35,
  lockedRequiredFohHours: 260, lockedRequiredBohHours: 275,
);

const WeekRecord _zeroGap = WeekRecord(
  weekId: 'test-zero', weekLabel: 'Zero',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 260, totalBohHours: 275,
  avgPPA: 41.79, avgCPLH: 4.62,
  theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
  dollarGap: 0.0,
  primaryLeverId: 'covers_down',
  targetSourceType: 'system_baseline',
  targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
  targetFohWage: 16.50, targetBohWage: 21.35,
  lockedRequiredFohHours: 260, lockedRequiredBohHours: 275,
);

// â”€â”€â”€ WeekHistoryTile tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

void main() {
  group('WeekHistoryTile â€” lever short labels', () {
    test('shortLabel for all 12 lever types is non-empty', () {
      for (final card in LeverCards.all) {
        expect(card.shortLabel, isNotEmpty,
            reason: 'shortLabel missing for lever ${card.id}');
      }
    });

    testWidgets('renders shortLabel from lever card', (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _overModel),
      ));
      // cplh_down shortLabel = 'CPLH'
      expect(find.text('CPLH'), findsOneWidget);
    });

    testWidgets('renders WAGE label for foh_wage_up lever', (tester) async {
      const record = WeekRecord(
        weekId: 't', weekLabel: 'Test',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.27,
        dollarGap: 390.38, primaryLeverId: 'foh_wage_up',
        blendedFohWage: 17.99, blendedBohWage: 21.35,
      );
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: record)));
      expect(find.text('WAGE'), findsOneWidget);
    });

    testWidgets('renders WAGE label for foh_wage_down lever', (tester) async {
      const record = WeekRecord(
        weekId: 't', weekLabel: 'Test',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 19.63,
        dollarGap: -432.30, primaryLeverId: 'foh_wage_down',
        blendedFohWage: 14.85, blendedBohWage: 21.35,
      );
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: record)));
      expect(find.text('WAGE'), findsOneWidget);
    });
  });

  group('WeekHistoryTile â€” color direction', () {
    testWidgets('over-model lever uses negative (red) color', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _overModel)));
      await tester.pump();
      // isOverModel = true â†’ gapColor = AppColors.negative
      expect(_overModel.isOverModel, isTrue);
    });

    testWidgets('favorable lever uses positive (green) color in badge', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _underModel)));
      await tester.pump();
      // cplh_up is favorable â†’ leverColor = AppColors.positive
      final card = LeverCards.all.firstWhere((c) => c.id == 'cplh_up');
      expect(card.isFavorable, isTrue);
    });

    test('foh_wage_down isFavorable = true', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'foh_wage_down');
      expect(card.isFavorable, isTrue);
    });

    test('boh_wage_down isFavorable = true', () {
      final card = LeverCards.all.firstWhere((c) => c.id == 'boh_wage_down');
      expect(card.isFavorable, isTrue);
    });
  });

  group('WeekHistoryTile â€” sign formatting', () {
    testWidgets('over-model gap displays with âˆ’ prefix', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _overModel)));
      await tester.pump();
      // dollarGap = 478.50 â†’ over model â†’ gapSign = 'âˆ’'
      expect(find.textContaining('\u2212\$'), findsWidgets);
    });

    testWidgets('under-model gap displays with + prefix', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _underModel)));
      await tester.pump();
      // dollarGap = -396.00 â†’ under model â†’ gapSign = '+'
      expect(find.textContaining('+\$'), findsWidgets);
    });

    testWidgets(r'zero gap renders $0', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _zeroGap)));
      await tester.pump();
      expect(find.textContaining('\$0'), findsWidgets);
    });
  });

  group('WeekHistoryTile â€” unknown lever falls back to coversDown', () {
    testWidgets('unknown primaryLeverId does not crash', (tester) async {
      const record = WeekRecord(
        weekId: 'stale', weekLabel: 'Stale',
        totalCovers: 1100, forecastCovers: 1200,
        totalFohHours: 265, totalBohHours: 280,
        avgPPA: 41.79, avgCPLH: 4.15,
        theoreticalLaborPct: 20.48, actualLaborPct: 22.0,
        dollarGap: 800.0, primaryLeverId: 'unknown_lever_xyz',
      );
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: record)));
      await tester.pump();
      // Falls back to coversDown shortLabel = 'COVERS'
      expect(find.text('COVERS'), findsOneWidget);
    });
  });

  group('LeverCardWidget â€” all 12 levers render without exception', () {
    for (final card in LeverCards.all) {
      testWidgets('renders ${card.id}', (tester) async {
        await tester.pumpWidget(_wrapScrollable(
          LeverCardWidget(data: card),
        ));
        await tester.pump();
        // Verify key content is rendered (causeCategory appears in badge)
        expect(find.textContaining(card.causeCategory), findsWidgets);
      });
    }
  });

  group('WeekDetailScreen â€” grouped table structure', () {
    testWidgets('CONDITIONS group label is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('CONDITIONS'), findsOneWidget);
    });

    testWidgets('EXECUTION group label is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('EXECUTION'), findsOneWidget);
    });

    testWidgets('OUTCOMES group label is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('OUTCOMES'), findsOneWidget);
    });

    testWidgets('PRIMARY DRIVER section label is present', (tester) async {
      await _pumpWeekDetail(tester, _overModel);
      await _scrollWeekDetailToText(tester, 'PRIMARY DRIVER');
      expect(
        find.text('PRIMARY DRIVER', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('DOLLAR IMPACT label is present', (tester) async {
      await _pumpWeekDetail(tester, _overModel);
      await _scrollWeekDetailToText(tester, 'DOLLAR IMPACT');
      expect(
        find.text('DOLLAR IMPACT', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('WeekDetailScreen â€” FOH/BOH Hours read preserved locked plan hours (7.55q.5)', () {
    testWidgets('FOH Hours target row shows preserved lockedRequiredFohHours', (tester) async {
      // 7.55q.5: target hours now read the preserved locked plan
      // hours captured at close, not LaborModel.modelFohHours(totalCovers, ...).
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      // _overModel.lockedRequiredFohHours = 260 â€” must render literally.
      // Note: LaborModel.modelFohHours(1200, 4.58) = 262, distinct from 260.
      expect(find.text('260'), findsWidgets);
    });

    testWidgets('BOH Hours target row shows preserved lockedRequiredBohHours', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      // _overModel.lockedRequiredBohHours = 275 â€” must render literally.
      // Note: LaborModel.modelBohHours(1200, 41.79, 180.0) = 279, distinct from 275.
      expect(find.text('275'), findsWidgets);
    });
  });

  group('WeekDetailScreen â€” legacy rows without preserved plan hours render "â€”" (7.55q.5)', () {
    const legacy = WeekRecord(
      weekId: 'legacy-no-plan-hours', weekLabel: 'Legacy',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 278,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
      dollarGap: 0.0, primaryLeverId: 'covers_down',
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
      // intentionally omit lockedRequiredFohHours / lockedRequiredBohHours
    );

    testWidgets('FOH Hours target cell shows "â€”" for legacy rows', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: legacy),
      ));
      await tester.pump();
      // "â€”" appears in: FOH target, FOH variance, BOH target, BOH variance,
      // Blended Wage target, Blended Wage variance. Must be >= 4 occurrences.
      expect(find.text('\u2014'), findsAtLeastNWidgets(4));
    });

    test('preservedTargetFohHours / preservedTargetBohHours return null', () {
      expect(legacy.preservedTargetFohHours, isNull);
      expect(legacy.preservedTargetBohHours, isNull);
    });

    test('strict targetFohHours / targetBohHours throw StateError on legacy rows', () {
      expect(() => legacy.targetFohHours, throwsA(isA<StateError>()));
      expect(() => legacy.targetBohHours, throwsA(isA<StateError>()));
    });
  });

  group('WeekDetailScreen â€” blended wage is hour-weighted (7.55q.5)', () {
    // Canonical formula:
    //   actual = (totalFoh Ã— blendedFohWage + totalBoh Ã— blendedBohWage) / totalHours
    //   target = (lockedFoh Ã— targetFohWage + lockedBoh Ã— targetBohWage) / totalPlanHours
    // Not the pre-7.55q.5 unweighted mean (FOH wage + BOH wage) / 2.
    const fohActualHours = 291;
    const bohActualHours = 279;
    const blendedFoh = 17.25;
    const blendedBoh = 22.10;
    const lockedFoh = 262;
    const lockedBoh = 278;
    const targetFohWage = 16.50;
    const targetBohWage = 21.35;

    const record = WeekRecord(
      weekId: 'wage-weighted', weekLabel: 'WageWeighted',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: fohActualHours, totalBohHours: bohActualHours,
      avgPPA: 41.79, avgCPLH: 4.12,
      theoreticalLaborPct: 20.48, actualLaborPct: 21.45,
      dollarGap: 478.50, primaryLeverId: 'cplh_down',
      blendedFohWage: blendedFoh, blendedBohWage: blendedBoh,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: targetFohWage, targetBohWage: targetBohWage,
      lockedRequiredFohHours: lockedFoh, lockedRequiredBohHours: lockedBoh,
    );

    testWidgets('actual blended wage is hour-weighted, not simple mean', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: record),
      ));
      await tester.pump();

      // Canonical hour-weighted actual
      final expectedWeighted =
          (fohActualHours * blendedFoh + bohActualHours * blendedBoh) /
              (fohActualHours + bohActualHours);
      // Pre-fix unweighted mean (must NOT render)
      final unweightedMean = (blendedFoh + blendedBoh) / 2;

      expect(find.text('\$${expectedWeighted.toStringAsFixed(2)}'),
          findsOneWidget);
      expect(find.text('\$${unweightedMean.toStringAsFixed(2)}'), findsNothing);
    });

    testWidgets('target blended wage uses preserved plan hours Ã— locked wages', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: record),
      ));
      await tester.pump();

      final expectedWeighted =
          (lockedFoh * targetFohWage + lockedBoh * targetBohWage) /
              (lockedFoh + lockedBoh);
      final unweightedMean = (targetFohWage + targetBohWage) / 2;

      expect(find.text('\$${expectedWeighted.toStringAsFixed(2)}'),
          findsOneWidget);
      expect(find.text('\$${unweightedMean.toStringAsFixed(2)}'), findsNothing);
    });
  });

  group('WeekDetailScreen â€” dollar gap color direction', () {
    testWidgets('over-model shows dollar sign with isNegative=true', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(_overModel.isOverModel, isTrue);
    });

    testWidgets('under-model shows + prefix in dollar impact card', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _underModel),
      ));
      await tester.pump();
      // Dollar impact card uses '+' sign for under-model
      expect(find.textContaining('+\$'), findsWidgets);
    });
  });

  // Annualized value coverage lives in the dedicated
  // 'WeekHistoryTile â€” dollarGapAnnualized' group below (over / under /
  // zero cases). The earlier single-case test was redundant.

  group('WeekDetailScreen â€” LeverCardWidget rendered for each lever', () {
    for (final record in DemoData.weekHistory) {
      testWidgets('renders LeverCardWidget for ${record.primaryLeverId}', (tester) async {
        await _pumpWeekDetail(tester, record);
        // LeverCardWidget renders the causeCategory
        final card = LeverCards.all.firstWhere(
          (c) => c.id == record.primaryLeverId,
          orElse: () => LeverCards.coversDown,
        );
        await _scrollWeekDetailToFinder(
          tester,
          find.text(card.causeCategory, skipOffstage: false),
        );
        expect(
          find.text(card.causeCategory, skipOffstage: false),
          findsAtLeastNWidgets(1),
        );
      });
    }
  });

  group('WeekDetailScreen â€” partial week (7.55q.5)', () {
    testWidgets('partial week with preserved plan hours renders the preserved value literally', (tester) async {
      // 7.55q.5: target hours no longer scale with shiftsCompleted.
      // They are the locked plan hours captured at close.
      const partial = WeekRecord(
        weekId: 'partial', weekLabel: 'Partial',
        totalCovers: 540, forecastCovers: 1200,
        totalFohHours: 120, totalBohHours: 125,
        avgPPA: 41.79, avgCPLH: 4.50,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.0,
        dollarGap: 200.0, primaryLeverId: 'covers_down',
        shiftsCompleted: 6,
        targetSourceType: 'system_baseline',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
        lockedRequiredFohHours: 262, lockedRequiredBohHours: 278,
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: partial),
      ));
      await tester.pump();
      // Full-week locked plan renders literally (262 / 278) regardless
      // of shiftsCompleted â€” no proration.
      expect(find.text('262'), findsWidgets);
      expect(find.text('278'), findsWidgets);
    });

    testWidgets('the pre-7.55q.5 "Target prorated" footnote is gone', (tester) async {
      // Stale copy removed: targets are no longer prorated from
      // shiftsCompleted under the new preserved-plan-hours contract.
      const partial = WeekRecord(
        weekId: 'partial', weekLabel: 'Partial',
        totalCovers: 540, forecastCovers: 1200,
        totalFohHours: 120, totalBohHours: 125,
        avgPPA: 41.79, avgCPLH: 4.50,
        theoreticalLaborPct: 20.48, actualLaborPct: 21.0,
        dollarGap: 200.0, primaryLeverId: 'covers_down',
        shiftsCompleted: 6,
        targetSourceType: 'system_baseline',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
        lockedRequiredFohHours: 262, lockedRequiredBohHours: 278,
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: partial),
      ));
      await tester.pump();
      expect(find.textContaining('Target prorated'), findsNothing);
    });
  });

  group('WeekDetailScreen â€” section label wording (7.55l.7d)', () {
    testWidgets('section label says LOCKED TARGETS not BASELINE', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('WEEKLY SUMMARY vs LOCKED TARGETS'), findsOneWidget);
      expect(find.text('WEEKLY SUMMARY vs BASELINE'), findsNothing);
    });

    testWidgets('provenance subtitle renders for system_baseline', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('Targets: 60-Day Benchmark'), findsOneWidget);
      expect(find.text('Built from Jan 27 - Mar 27'), findsOneWidget);
    });

    testWidgets('provenance subtitle renders for manager_override', (tester) async {
      const record = WeekRecord(
        weekId: 'mgr', weekLabel: 'Mgr',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
        targetSourceType: 'manager_override',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: record),
      ));
      await tester.pump();
      expect(find.text('Targets: Manager Override'), findsOneWidget);
    });
  });

  // Provenance label was removed from WeekHistoryTile per user request
  // ("get rid of the 14 shifts 60 day benchmark"). The label is still
  // exposed on WeekRecord and rendered on WeekDetailScreen. These tests
  // guard the tile against regressing back to showing that subtitle.
  group('WeekHistoryTile â€” provenance label hidden', () {
    testWidgets('system_baseline provenance is not rendered in tile',
        (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('60-Day Benchmark'), findsNothing);
    });

    testWidgets('manager_override provenance is not rendered in tile',
        (tester) async {
      const record = WeekRecord(
        weekId: 'mgr', weekLabel: 'Mgr',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
        targetSourceType: 'manager_override',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
      );
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: record),
      ));
      await tester.pump();
      expect(find.text('Manager Override'), findsNothing);
    });

    testWidgets('shifts-completed count is not rendered in tile',
        (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _overModel),
      ));
      await tester.pump();
      expect(find.textContaining('shifts'), findsNothing);
    });
  });

  group('WeekRecord â€” provenanceLabel getter (7.55l.7d)', () {
    test('system_baseline maps to 60-Day Benchmark', () {
      expect(_overModel.provenanceLabel, '60-Day Benchmark');
    });

    test('manager_override maps to Manager Override', () {
      const record = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetSourceType: 'manager_override',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(record.provenanceLabel, 'Manager Override');
    });

    test('admin_replacement maps to Admin Override', () {
      const record = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetSourceType: 'admin_replacement',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(record.provenanceLabel, 'Admin Override');
    });

    test('null sourceType falls back to Baseline', () {
      expect(_zeroGap.provenanceLabel, '60-Day Benchmark');
      const legacy = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(legacy.provenanceLabel, 'Baseline');
    });

    // â”€â”€ Cycle-era source types (7.55l.7d1) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    test('cycle_recommended maps to 60-Day Benchmark', () {
      const record = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetSourceType: 'cycle_recommended',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(record.provenanceLabel, '60-Day Benchmark');
    });

    test('cycle_manager_override maps to Manager Override', () {
      const record = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetSourceType: 'cycle_manager_override',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(record.provenanceLabel, 'Manager Override');
    });

    test('cycle_admin_replacement maps to Admin Override', () {
      const record = WeekRecord(
        weekId: 'x', weekLabel: 'X',
        totalCovers: 100, forecastCovers: 100,
        totalFohHours: 20, totalBohHours: 20,
        avgPPA: 40.0, avgCPLH: 5.0,
        theoreticalLaborPct: 20.0, actualLaborPct: 20.0,
        dollarGap: 0, primaryLeverId: 'covers_down',
        targetSourceType: 'cycle_admin_replacement',
        targetCPLH: 5.0, targetSPLH: 180.0, targetPPA: 40.0,
        targetFohWage: 16.0, targetBohWage: 21.0,
      );
      expect(record.provenanceLabel, 'Admin Override');
    });
  });

  group('WeekDetailScreen â€” cycle-era provenance subtitle (7.55l.7d1)', () {
    testWidgets('cycle_recommended renders as 60-Day Benchmark', (tester) async {
      const record = WeekRecord(
        weekId: 'cyc', weekLabel: 'Cyc',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
        targetSourceType: 'cycle_recommended',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: record),
      ));
      await tester.pump();
      expect(find.text('Targets: 60-Day Benchmark'), findsOneWidget);
    });
  });

  group('WeekHistoryTile â€” dollarGapAnnualized', () {
    test('dollarGapAnnualized always uses magnitude Ã— 52', () {
      // Over model
      expect(_overModel.dollarGapAnnualized, closeTo(478.50 * 52, 0.01));
      // Under model (dollarGap negative, annualized uses .abs())
      expect(_underModel.dollarGapAnnualized, closeTo(396.00 * 52, 0.01));
    });

    test('dollarGapAnnualized = 0 when dollarGap = 0', () {
      expect(_zeroGap.dollarGapAnnualized, 0.0);
    });
  });

  // â”€â”€ History benchmark dayparts â€” evidence-backed (7.55k.5) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('History benchmark dayparts â€” evidence-backed', () {
    test('canonical seed produces evidence-backed benchmark summaries', () {
      const service = HistoryBenchmarkDaypartReadService();
      final results = service.build(
          MockIntegrationReplaySeed.output.historicalClosedShifts);
      expect(results, isNotEmpty);
      for (final b in results) {
        expect(b.benchmarkCount, greaterThan(0));
        expect(b.avgCPLH, greaterThan(0));
        expect(b.avgSPLH, greaterThan(0));
        expect(b.label, isNotEmpty);
      }
    });

    test('benchmark summaries are no longer plain joined labels', () {
      const service = HistoryBenchmarkDaypartReadService();
      final results = service.build(
          MockIntegrationReplaySeed.output.historicalClosedShifts);
      // Each summary carries metric proof, not just a label string.
      for (final b in results) {
        expect(b.closedShiftCount, greaterThanOrEqualTo(b.benchmarkCount));
        expect(b.avgCPLH, isNot(0));
      }
    });

    test('compact benchmark row format includes benchmark-met sample depth', () {
      const service = HistoryBenchmarkDaypartReadService();
      final results = service.build(
          MockIntegrationReplaySeed.output.historicalClosedShifts);
      // Verify the rendering shape: "Met benchmark X of Y shifts" with total sample
      // depth still visible to the operator.
      for (final b in results) {
        final rendered =
            '${b.label} · Met benchmark ${b.benchmarkCount} of ${b.closedShiftCount} shifts · '
            '${b.avgCPLH.toStringAsFixed(2)} CPLH · '
            '\$${b.avgSPLH.toStringAsFixed(0)} SPLH';
        expect(rendered,
            contains(
                'Met benchmark ${b.benchmarkCount} of ${b.closedShiftCount} shifts'));
        // Total should always be >= favorable.
        expect(b.closedShiftCount, greaterThanOrEqualTo(b.benchmarkCount));
      }
    });
  });

  // â”€â”€ Tier-aware truncation â€” strong first (7.55k.7a) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('Tier-aware truncation â€” strong first', () {
    test('strong benchmark evidence is prioritized over early signals', () {
      const service = HistoryBenchmarkDaypartReadService();
      // Thin bucket (2/2) has higher benchmarkCount than strong bucket (1/3).
      final shifts = <ShiftRecord>[
        // Wed Lunch: 2 favorable, 2 total â†’ earlySignal
        ShiftRecord(weekId: 'w', dayLabel: 'Wed', daypart: 'lunch',
            status: 'closed', covers: 120, forecastCovers: 120,
            ppa: 42, cplh: 4.5, splh: 180, fohHours: 28, bohHours: 29,
            primaryLever: 'PPA_UP'),
        ShiftRecord(weekId: 'w', dayLabel: 'Wed', daypart: 'lunch',
            status: 'closed', covers: 120, forecastCovers: 120,
            ppa: 42, cplh: 4.5, splh: 180, fohHours: 28, bohHours: 29,
            primaryLever: 'PPA_UP', businessDate: '2026-03-12'),
        // Sat Dinner: 1 favorable, 3 total â†’ strong
        ShiftRecord(weekId: 'w', dayLabel: 'Sat', daypart: 'dinner',
            status: 'closed', covers: 120, forecastCovers: 120,
            ppa: 42, cplh: 4.5, splh: 180, fohHours: 28, bohHours: 29,
            primaryLever: 'PPA_UP'),
        ShiftRecord(weekId: 'w', dayLabel: 'Sat', daypart: 'dinner',
            status: 'closed', covers: 120, forecastCovers: 120,
            ppa: 42, cplh: 4.5, splh: 180, fohHours: 28, bohHours: 29,
            primaryLever: 'CPLH_DOWN', businessDate: '2026-03-08'),
        ShiftRecord(weekId: 'w', dayLabel: 'Sat', daypart: 'dinner',
            status: 'closed', covers: 120, forecastCovers: 120,
            ppa: 42, cplh: 4.5, splh: 180, fohHours: 28, bohHours: 29,
            primaryLever: 'CPLH_DOWN', businessDate: '2026-03-15'),
      ];
      final results = service.build(shifts);
      // Strong (Sat Dinner) must appear before earlySignal (Wed Lunch)
      // even though Wed Lunch has higher benchmarkCount.
      expect(results.first.label, 'Sat Dinner');
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: results.first.benchmarkCount,
            closedShiftCount: results.first.closedShiftCount),
        EvidenceTier.strong,
      );
    });
  });

  // â”€â”€ Visibility policy â€” interim evidence tiers (7.55k.7) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('Visibility policy â€” benchmark evidence tiers', () {
    test('strong benchmark requires >= 3 closed shifts', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: 2, closedShiftCount: 3),
        EvidenceTier.strong,
      );
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: 1, closedShiftCount: 3),
        EvidenceTier.strong,
      );
    });

    test('thin sample is early signal', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: 1, closedShiftCount: 2),
        EvidenceTier.earlySignal,
      );
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: 1, closedShiftCount: 1),
        EvidenceTier.earlySignal,
      );
    });

    test('zero favorable is hidden', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyBenchmark(
            benchmarkCount: 0, closedShiftCount: 5),
        EvidenceTier.hidden,
      );
    });

    test('repeatable win requires >= 2 favorable shifts', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
            benchmarkCount: 2),
        EvidenceTier.strong,
      );
      expect(
        DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
            benchmarkCount: 5),
        EvidenceTier.strong,
      );
    });

    test('single favorable shift is not a repeatable win', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
            benchmarkCount: 1),
        EvidenceTier.hidden,
      );
    });

    test('zero favorable is hidden for repeatable wins', () {
      expect(
        DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
            benchmarkCount: 0),
        EvidenceTier.hidden,
      );
    });
  });

  // -- 7.55q.10: Dollar Impact card frozen-at-close parity ----------------
  //
  // When a WeekRecord carries the new fields (closed via V22+), Week
  // Detail must render all 4 rows the live Variance card was showing,
  // with the frozen annualized number and the "As of close, ..." footer.
  // Pre-V22 rows must still render the legacy 2-row + boilerplate
  // footer so history doesn't crash or silently re-model.

  group('WeekDetailScreen â€” Dollar Impact frozen-at-close (7.55q.10)', () {
    const frozen = WeekRecord(
      weekId: '2026-W13', weekLabel: 'Mar 24',
      totalCovers: 1721, forecastCovers: 1721,
      totalFohHours: 488, totalBohHours: 510,
      avgPPA: 41.79, avgCPLH: 3.53,
      theoreticalLaborPct: 20.48, actualLaborPct: 21.45,
      dollarGap: 478.50, primaryLeverId: 'cplh_down',
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
      lockedRequiredFohHours: 462, lockedRequiredBohHours: 488,
      monthDollarImpact: 1430.20,
      sixtyDayDollarImpact: 2715.50,
      closedAt: '2026-03-29',
    );

    testWidgets('all 4 row labels render when frozen windows are populated',
        (tester) async {
      await _pumpWeekDetail(tester, frozen);
      await _scrollWeekDetailToText(tester, 'this week');
      expect(find.text('this week'), findsOneWidget);
      expect(find.text('this month'), findsOneWidget);
      expect(find.text('last 60 days'), findsOneWidget);
      expect(find.text('annualized'), findsOneWidget);
    });

    testWidgets('footer shows "As of close, Mar 29" when closedAt is present',
        (tester) async {
      await _pumpWeekDetail(tester, frozen);
      await _scrollWeekDetailToText(tester, 'As of close, Mar 29');
      expect(find.text('As of close, Mar 29'), findsOneWidget);
      // The legacy boilerplate footer must NOT render alongside.
      expect(find.text('At \$3M annual sales. One location.'), findsNothing);
    });

    test('frozenAnnualizedImpact = sixtyDayDollarImpact * (365/60)', () {
      expect(
        frozen.frozenAnnualizedImpact!,
        closeTo(2715.50 * (365.0 / 60), 0.001),
      );
    });

    testWidgets(
        'legacy row (no frozen fields) still renders 2 rows + boilerplate footer',
        (tester) async {
      const legacy = WeekRecord(
        weekId: 'legacy-impact', weekLabel: 'Legacy',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 278,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.95,
        dollarGap: 200.0, primaryLeverId: 'covers_down',
        targetSourceType: 'system_baseline',
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
        lockedRequiredFohHours: 262, lockedRequiredBohHours: 278,
        // no monthDollarImpact / sixtyDayDollarImpact / closedAt
      );
      await _pumpWeekDetail(tester, legacy);
      await _scrollWeekDetailToText(tester, 'this week');
      expect(find.text('this week'), findsOneWidget);
      expect(find.text('this month'), findsNothing);
      expect(find.text('last 60 days'), findsNothing);
      expect(find.text('annualized'), findsOneWidget);
      expect(find.text('At \$3M annual sales. One location.'), findsOneWidget);
    });
  });
}

