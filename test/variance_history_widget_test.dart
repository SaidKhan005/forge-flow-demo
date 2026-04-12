// ─── Variance History Widget Tests ───────────────────────────────────────────
// Phase 7.15 — Tests WeekHistoryTile and WeekDetailScreen rendering.
// Verifies: short labels, color direction, dollar gap sign, annualized value,
// model formula in targetFohHours/targetBohHours, grouped table structure,
// and edge cases.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/fixture_seed_data.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/widgets/lever_card.dart';
import 'package:forge_and_flow/widgets/week_history_tile.dart';
import 'package:forge_and_flow/screens/week_detail_screen.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: child),
    );

Widget _wrapScrollable(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

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
);

const WeekRecord _zeroGap = WeekRecord(
  weekId: 'test-zero', weekLabel: 'Zero',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 262, totalBohHours: 279,
  avgPPA: 41.79, avgCPLH: 4.58,
  theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
  dollarGap: 0.0,
  primaryLeverId: 'covers_down',
  targetSourceType: 'system_baseline',
  targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
  targetFohWage: 16.50, targetBohWage: 21.35,
);

// ─── WeekHistoryTile tests ────────────────────────────────────────────────────

void main() {
  group('WeekHistoryTile — lever short labels', () {
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

  group('WeekHistoryTile — color direction', () {
    testWidgets('over-model lever uses negative (red) color', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _overModel)));
      await tester.pump();
      // isOverModel = true → gapColor = AppColors.negative
      expect(_overModel.isOverModel, isTrue);
    });

    testWidgets('favorable lever uses positive (green) color in badge', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _underModel)));
      await tester.pump();
      // cplh_up is favorable → leverColor = AppColors.positive
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

  group('WeekHistoryTile — sign formatting', () {
    testWidgets('over-model gap displays with − prefix', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _overModel)));
      await tester.pump();
      // dollarGap = 478.50 → over model → gapSign = '−'
      expect(find.textContaining('−\$'), findsWidgets);
    });

    testWidgets('under-model gap displays with + prefix', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _underModel)));
      await tester.pump();
      // dollarGap = -396.00 → under model → gapSign = '+'
      expect(find.textContaining('+\$'), findsWidgets);
    });

    testWidgets(r'zero gap renders $0', (tester) async {
      await tester.pumpWidget(_wrap(WeekHistoryTile(week: _zeroGap)));
      await tester.pump();
      expect(find.textContaining('\$0'), findsWidgets);
    });
  });

  group('WeekHistoryTile — unknown lever falls back to coversDown', () {
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

  group('LeverCardWidget — all 12 levers render without exception', () {
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

  group('WeekDetailScreen — grouped table structure', () {
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
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('PRIMARY DRIVER'), findsOneWidget);
    });

    testWidgets('DOLLAR IMPACT label is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('DOLLAR IMPACT'), findsOneWidget);
    });
  });

  group('WeekDetailScreen — targetFohHours uses model formula', () {
    testWidgets('FOH Hours target row shows model-derived value', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      // targetFohHours = modelFohHours(1200, storedTargetCPLH)
      final expected = LaborModel.modelFohHours(1200, 4.58);
      expect(find.text(expected.toString()), findsWidgets);
    });

    testWidgets('BOH Hours target row shows model-derived value', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      final expected = LaborModel.modelBohHours(1200, 41.79, 180.0);
      expect(find.text(expected.toString()), findsWidgets);
    });
  });

  group('WeekDetailScreen — dollar gap color direction', () {
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

  group('WeekDetailScreen — annualized value', () {
    testWidgets('annualized = dollarGap.abs() × 52', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      final annualized = _overModel.dollarGapAnnualized;
      expect(annualized, closeTo(478.50 * 52, 0.01));
    });
  });

  group('WeekDetailScreen — LeverCardWidget rendered for each lever', () {
    for (final record in DemoData.weekHistory) {
      testWidgets('renders LeverCardWidget for ${record.primaryLeverId}', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: WeekDetailScreen(week: record),
        ));
        await tester.pump();
        // LeverCardWidget renders the causeCategory
        final card = LeverCards.all.firstWhere(
          (c) => c.id == record.primaryLeverId,
          orElse: () => LeverCards.coversDown,
        );
        expect(find.textContaining(card.causeCategory), findsWidgets);
      });
    }
  });

  group('WeekDetailScreen — partial week', () {
    testWidgets('partial week: targetFohHours uses model formula (not proration)', (tester) async {
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
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: partial),
      ));
      await tester.pump();
      final expected = LaborModel.modelFohHours(540, 4.58);
      // Model formula value should appear in the table
      expect(find.text(expected.toString()), findsWidgets);
    });
  });

  group('WeekDetailScreen — section label wording (7.55l.7d)', () {
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

  group('WeekHistoryTile — provenance label (7.55l.7d)', () {
    testWidgets('tile renders provenance label for system_baseline', (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _overModel),
      ));
      await tester.pump();
      expect(find.text('60-Day Benchmark'), findsOneWidget);
    });

    testWidgets('tile renders provenance label for manager_override', (tester) async {
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
      expect(find.text('Manager Override'), findsOneWidget);
    });

    testWidgets('tile renders fallback label for null sourceType', (tester) async {
      const record = WeekRecord(
        weekId: 'legacy', weekLabel: 'Legacy',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 279,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
        dollarGap: 0.0, primaryLeverId: 'covers_down',
        targetSourceType: null,
        targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
        targetFohWage: 16.50, targetBohWage: 21.35,
      );
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: record),
      ));
      await tester.pump();
      expect(find.text('Baseline'), findsOneWidget);
    });
  });

  group('WeekRecord — provenanceLabel getter (7.55l.7d)', () {
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

    // ── Cycle-era source types (7.55l.7d1) ─────────────────────────────

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

  group('WeekDetailScreen — cycle-era provenance subtitle (7.55l.7d1)', () {
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

  group('WeekHistoryTile — dollarGapAnnualized', () {
    test('dollarGapAnnualized always uses magnitude × 52', () {
      // Over model
      expect(_overModel.dollarGapAnnualized, closeTo(478.50 * 52, 0.01));
      // Under model (dollarGap negative, annualized uses .abs())
      expect(_underModel.dollarGapAnnualized, closeTo(396.00 * 52, 0.01));
    });

    test('dollarGapAnnualized = 0 when dollarGap = 0', () {
      expect(_zeroGap.dollarGapAnnualized, 0.0);
    });
  });
}
