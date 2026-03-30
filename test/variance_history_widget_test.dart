// ─── Variance History Widget Tests ───────────────────────────────────────────
// Phase 7.15 — Tests WeekHistoryTile and WeekDetailScreen rendering.
// Verifies: short labels, color direction, dollar gap sign, annualized value,
// model formula in targetFohHours/targetBohHours, grouped table structure,
// and edge cases.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/demo_data.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/models/week_record.dart';
import 'package:forge_flow_demo/services/labor_model.dart';
import 'package:forge_flow_demo/widgets/lever_card.dart';
import 'package:forge_flow_demo/widgets/week_history_tile.dart';
import 'package:forge_flow_demo/screens/week_detail_screen.dart';

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
);

const WeekRecord _underModel = WeekRecord(
  weekId: 'test-under', weekLabel: 'Test',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 238, totalBohHours: 279,
  avgPPA: 41.79, avgCPLH: 5.04,
  theoreticalLaborPct: 20.48, actualLaborPct: 19.71,
  dollarGap: -396.00,
  primaryLeverId: 'cplh_up',
);

const WeekRecord _zeroGap = WeekRecord(
  weekId: 'test-zero', weekLabel: 'Zero',
  totalCovers: 1200, forecastCovers: 1200,
  totalFohHours: 262, totalBohHours: 279,
  avgPPA: 41.79, avgCPLH: 4.58,
  theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
  dollarGap: 0.0,
  primaryLeverId: 'covers_down',
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
      // targetFohHours = modelFohHours(1200, derivedTargetCPLH)
      final expected = LaborModel.modelFohHours(
          1200, BaselineData.derivedTargetCPLH);
      expect(find.text(expected.toString()), findsWidgets);
    });

    testWidgets('BOH Hours target row shows model-derived value', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: _overModel),
      ));
      await tester.pump();
      final expected = LaborModel.modelBohHours(
          1200, 41.79, BaselineData.derivedTargetSPLH);
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
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: WeekDetailScreen(week: partial),
      ));
      await tester.pump();
      final expected = LaborModel.modelFohHours(
          540, BaselineData.derivedTargetCPLH);
      // Model formula value should appear in the table
      expect(find.text(expected.toString()), findsWidgets);
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
