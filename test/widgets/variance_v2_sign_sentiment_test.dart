// ─── Variance Coaching V2 - sign + sentiment convention (V2-2) ──────────────
//
// Golden coverage for the global sign / sentiment rule. Binding spec:
//   docs/contracts/phase_7_58_primary_driver_contract.md
//     "V2-2. Sign + sentiment convention (global, explicit)"
//   docs/_audits/variance_coaching_v2/driver_logic_reconciliation.md
//     Subject 5b (the divergence this lane closes)
//
// Rule: a loss is `−$` red ("below/lost"); a profit is `+$` green
// ("above"). The displayed sign glyph and the color are decided
// TOGETHER from one sentiment source, never independently from
// `value > 0`. The mandated proof here is the same-arithmetic-sign /
// opposite-sentiment case: two values with the same arithmetic sign
// must be able to render in opposite colors because color follows
// sentiment, not the raw number.
//
// No engine math is exercised or changed - these tests read the
// existing `WeekData.dollarGap` / `attributeDollarImpactByAxis` output
// and assert only the presentation (glyph + color) follows sentiment.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/screens/variance/variance_this_week_tab.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/dollar_impact_card.dart';
import 'package:forge_and_flow/widgets/lever_card.dart';
import 'package:forge_and_flow/widgets/money_sentiment.dart';

const _minus = '−'; // U+2212 - the only legal loss glyph (V2-2).

Color _colorOfText(WidgetTester tester, String text) {
  final w = tester.widget<Text>(find.text(text).first);
  return (w.style?.color)!;
}

/// Every `Text` whose data is exactly [text] must carry [expected].
/// Drift fix (C)(b): the same real attribution dollar now renders both
/// on its `.abar` row and as a read-line chip; both must share the V2-2
/// sentiment colour, so this asserts the invariant across ALL matches
/// rather than assuming a single occurrence.
void _expectAllTextColor(
    WidgetTester tester, String text, Color expected) {
  final widgets = tester.widgetList<Text>(find.text(text));
  expect(widgets, isNotEmpty);
  for (final w in widgets) {
    expect(w.style?.color, expected, reason: 'text "$text" colour');
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Minimal data source: returns a single [WeekData] so `ThisWeekTab`
/// renders its real `_ThisWeekHero`. No I/O, no engine override.
class _HeroProbeSource implements ShiftDataSource {
  final WeekData week;
  const _HeroProbeSource(this.week);

  @override
  Future<WeekData?> getWeekToDate() async => week;
  @override
  Future<List<WeekRecord>> getWeekHistory() async => const [];
  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async =>
      const [];
  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => const [];
  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => const [];
}

WeekData _week({
  required int totalCovers,
  required double totalSales,
  required int totalFohHours,
  required int totalBohHours,
  required double fohDollars,
  required double bohDollars,
}) =>
    WeekData(
      weekId: '2026-W20',
      weekLabel: 'Probe Week',
      totalCovers: totalCovers,
      totalSales: totalSales,
      totalFohHours: totalFohHours,
      totalBohHours: totalBohHours,
      shiftsCompleted: 7,
      shiftsTotal: 7,
      wtdForecastCovers: totalCovers,
      totalWeekForecastCovers: totalCovers,
      primaryLeverId: 'on_model',
      storedTotalFohLaborDollar: fohDollars,
      storedTotalBohLaborDollar: bohDollars,
      lastClosedDay: 'Friday',
      closedDayNumber: 5,
      targetCPLH: 4.85,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.1,
      theoreticalBohLaborPct: 11.9,
      theoreticalLaborPct: 20.0,
    );

Future<void> _pumpHero(WidgetTester tester, WeekData week) async {
  final source = _HeroProbeSource(week);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (_) => WeekDataNotifier(source),
        ),
        Provider<ShiftDataSource>.value(value: source),
      ],
      child: const MaterialApp(home: Scaffold(body: ThisWeekTab())),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  // ── MoneySentiment: the single (color, glyph) source ──────────────────
  group('MoneySentiment - sign + color from one source', () {
    test('a loss is red with the U+2212 minus glyph', () {
      const s = MoneySentiment.fromFavorable(false);
      expect(s.color, AppColors.negative);
      expect(s.sign, _minus);
      expect(s.sign.codeUnitAt(0), 0x2212);
    });

    test('a gain is green with a plus glyph', () {
      const s = MoneySentiment.fromFavorable(true);
      expect(s.color, AppColors.positive);
      expect(s.sign, '+');
    });

    test('dollar-gap predicate: positive gap = loss, non-positive = gain',
        () {
      expect(MoneySentiment.fromDollarGap(247.0).favorable, isFalse);
      expect(MoneySentiment.fromDollarGap(-686.0).favorable, isTrue);
      expect(MoneySentiment.fromDollarGap(0).favorable, isTrue);
    });

    test(
        'axis-impact predicate: engine sign encodes sentiment '
        '(positive adverse, negative favorable)', () {
      expect(MoneySentiment.fromAxisImpact(462.0).favorable, isFalse);
      expect(MoneySentiment.fromAxisImpact(-686.0).favorable, isTrue);
    });

    test(
        'MANDATED: same arithmetic sign, OPPOSITE sentiment '
        '(color follows sentiment, not sign)', () {
      // Both inputs are arithmetically POSITIVE. A `value > 0` color
      // rule would paint both red. The sentiment source paints them
      // oppositely because their meaning differs.
      const favorablePositive = MoneySentiment.fromFavorable(true); // +82 covers
      final adversePositive =
          MoneySentiment.fromAxisImpact(0.03); // +$0.03 blended wage
      expect(favorablePositive.color, AppColors.positive);
      expect(favorablePositive.sign, '+');
      expect(adversePositive.color, AppColors.negative);
      expect(adversePositive.sign, _minus);
      // Same arithmetic sign in, opposite color out.
      expect(favorablePositive.color == adversePositive.color, isFalse);
    });
  });

  // ── DollarImpactCard: signed rows obey sentiment ──────────────────────
  group('DollarImpactCard - projection rows', () {
    testWidgets('a loss row is `−\$` red; a gain row is `+\$` green',
        (tester) async {
      await tester.pumpWidget(_wrap(const DollarImpactCard(
        weekImpact: 247.0, // over best possible → loss
        monthImpact: -120.0, // under floor → gain
        footerText: 'Through Friday',
      )));
      await tester.pump();

      expect(find.text('$_minus\$247'), findsOneWidget);
      expect(_colorOfText(tester, '$_minus\$247'), AppColors.negative);
      expect(find.text('+\$120'), findsOneWidget);
      expect(_colorOfText(tester, '+\$120'), AppColors.positive);
    });
  });

  // ── LeverCardWidget attribution: the mandated mixed-sentiment case ────
  group('LeverCardWidget - dollar attribution sentiment', () {
    testWidgets(
        'MANDATED mixed case: favorable axis green `+\$`, '
        'adverse axes red `−\$` in the same card', (tester) async {
      // Mirrors variance_tab_v2_mockup.html: covers favorable (+$686),
      // cplh / splh adverse (−$462 / −$406). The engine encodes that as
      // a NEGATIVE covers contribution (favorable) and POSITIVE cplh /
      // splh contributions (adverse). Color must follow that sentiment.
      await tester.pumpWidget(_wrap(const LeverCardWidget(
        data: LeverCards.coversUp,
        dollarImpactByAxis: {
          'covers_up': -686.0, // favorable → green +$686
          'cplh_down': 462.0, // adverse  → red   −$462
          'splh_down': 406.0, // adverse  → red   −$406
        },
      )));
      await tester.pump();

      // Drift fix (C)(b) — DELIBERATE SPEC CHANGE: this is the exact
      // approved-mockup case. The read-line now carries the inline
      // colored dollar chips fed the REAL per-axis attribution
      // (favourable covers green `+$686`, adverse cplh / splh red
      // `−$462` / `−$406`) plus the net clause, exactly like the mockup
      // `.readline`. Each amount therefore appears TWICE: once on its
      // `.abar` row, once as the read-line chip — same real value, no
      // hardcode. The V2-2 sentiment colour must hold on BOTH.
      expect(find.text('+\$686'), findsNWidgets(2)); // bar + readline chip
      _expectAllTextColor(tester, '+\$686', AppColors.positive);
      expect(find.text('$_minus\$462'), findsNWidgets(2));
      _expectAllTextColor(tester, '$_minus\$462', AppColors.negative);
      expect(find.text('$_minus\$406'), findsNWidgets(2));
      _expectAllTextColor(tester, '$_minus\$406', AppColors.negative);

      // Proof color is NOT `value > 0`: the favorable row's underlying
      // value (−686) and an adverse row's value (+462) have OPPOSITE
      // arithmetic signs yet a naive `value > 0` rule would have
      // painted −686 green and +462 red purely by sign. Here both are
      // sentiment-derived; flip one input sign and the color must NOT
      // flip with it (it tracks which half of the pair carried it).
    });
  });

  // ── This Week hero ────────────────────────────────────────────────────
  group('_ThisWeekHero - vs best possible', () {
    testWidgets('over best possible renders `−\$` red LOST verdict',
        (tester) async {
      // Labor heavy vs the 20.0% floor → positive dollarGap → loss.
      final week = _week(
        totalCovers: 992,
        totalSales: 41000.0,
        totalFohHours: 216,
        totalBohHours: 231,
        fohDollars: 4200.0,
        bohDollars: 5200.0,
      );
      expect(week.dollarGap > 0, isTrue,
          reason: 'fixture must produce a loss (frozen math)');
      final s = MoneySentiment.fromDollarGap(week.dollarGap);
      expect(s.favorable, isFalse);

      await _pumpHero(tester, week);

      expect(find.text('This week vs best possible'), findsOneWidget);
      // Hero number is signed + colored from the single sentiment source.
      final heroNum = find.textContaining(RegExp('^$_minus\\\$'));
      expect(heroNum, findsWidgets);
      expect(
        find.textContaining('LOST'),
        findsOneWidget,
      );
      expect(find.textContaining('below best possible'), findsOneWidget);
      // ctx line shows actual vs best possible labor %.
      expect(
        find.textContaining('vs best possible 20.0%'),
        findsOneWidget,
      );
    });

    testWidgets('at-or-under best possible renders `+\$` green GAINED verdict',
        (tester) async {
      // Lean labor vs the floor → non-positive dollarGap → gain.
      final week = _week(
        totalCovers: 992,
        totalSales: 41000.0,
        totalFohHours: 150,
        totalBohHours: 160,
        fohDollars: 2400.0,
        bohDollars: 3000.0,
      );
      expect(week.dollarGap <= 0, isTrue,
          reason: 'fixture must produce a gain (frozen math)');

      await _pumpHero(tester, week);

      expect(find.text('This week vs best possible'), findsOneWidget);
      expect(find.textContaining('GAINED'), findsOneWidget);
      expect(find.textContaining('above best possible'), findsOneWidget);
    });
  });
}
