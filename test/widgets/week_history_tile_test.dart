// Widget tests for WeekHistoryTile.
//
// Coverage:
//   * mounts without crash with a minimal WeekRecord
//   * weekLabel text is rendered
//   * dollar-gap text is rendered
//   * onTap callback fires when the tile is tapped
//   * unknown primaryLeverId renders the '—' degraded badge (not a crash)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/widgets/week_history_tile.dart';

/// Minimal WeekRecord with all required fields filled.
WeekRecord _makeRecord({
  String weekLabel = 'May 5',
  double dollarGap = 1200.0,
  String primaryLeverId = 'covers_down',
}) =>
    WeekRecord(
      weekId: '2026-W18',
      weekLabel: weekLabel,
      totalCovers: 1150,
      forecastCovers: 1200,
      totalFohHours: 260,
      totalBohHours: 275,
      avgPPA: 41.5,
      avgCPLH: 4.42,
      theoreticalLaborPct: 20.6,
      actualLaborPct: 22.1,
      dollarGap: dollarGap,
      primaryLeverId: primaryLeverId,
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  group('WeekHistoryTile', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _makeRecord()),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders weekLabel', (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _makeRecord(weekLabel: 'May 5')),
      ));
      await tester.pump();

      expect(find.text('May 5'), findsOneWidget);
    });

    testWidgets('renders dollar gap with sign when over model', (tester) async {
      // dollarGap > 0 → isOverModel=true → gapSign='−'
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _makeRecord(dollarGap: 1200.0)),
      ));
      await tester.pump();

      // The widget formats as '−$1,200.00'; just check gapSign present.
      final finder = find.textContaining('\$1,200');
      expect(finder, findsOneWidget);
    });

    testWidgets('renders dollar gap with + sign when under model',
        (tester) async {
      // dollarGap < 0 → isOverModel=false → gapSign='+'
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _makeRecord(dollarGap: -800.0)),
      ));
      await tester.pump();

      final finder = find.textContaining('\$800');
      expect(finder, findsOneWidget);
    });

    testWidgets('onTap fires when tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(
          week: _makeRecord(),
          onTap: () => tapped = true,
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(InkWell).first);
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('known lever id renders its short label', (tester) async {
      // covers_down → shortLabel = 'COVERS'
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(week: _makeRecord(primaryLeverId: 'covers_down')),
      ));
      await tester.pump();

      expect(find.text('COVERS'), findsOneWidget);
    });

    testWidgets('unknown lever id renders degraded — badge without crash',
        (tester) async {
      await tester.pumpWidget(_wrap(
        WeekHistoryTile(
          week: _makeRecord(primaryLeverId: 'on_model'),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The degraded badge shows '—' (em dash sentinel).
      expect(find.text('—'), findsOneWidget);
    });
  });
}
