// Widget tests for ScheduleDayRow.
//
// Coverage:
//   * normal data row mounts and shows the day string
//   * header factory mounts without crash and shows 'DAY' label
//   * isTotal=true mode mounts without crash
//   * isSubrow=true mode mounts without crash
//   * trailing widget appears in the tree when provided

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/widgets/schedule_day_row.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  group('ScheduleDayRow — normal data row', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Mon',
          forecastCovers: 180,
          forecastSales: 7560.0,
          requiredFohHours: 38,
          requiredBohHours: 40,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the day string', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Mon',
          forecastCovers: 180,
          forecastSales: 7560.0,
          requiredFohHours: 38,
          requiredBohHours: 40,
        ),
      ));
      await tester.pump();

      expect(find.text('Mon'), findsOneWidget);
    });

    testWidgets('shows forecast covers', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Tue',
          forecastCovers: 200,
          forecastSales: 8400.0,
          requiredFohHours: 44,
          requiredBohHours: 46,
        ),
      ));
      await tester.pump();

      expect(find.text('200'), findsOneWidget);
    });
  });

  group('ScheduleDayRow.header() factory', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(ScheduleDayRow.header()));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders DAY column label', (tester) async {
      await tester.pumpWidget(_wrap(ScheduleDayRow.header()));
      await tester.pump();

      // Header uses 'DAY' text in two places (the factory day field + the
      // Column widget), so findsWidgets is the right assertion.
      expect(find.text('DAY'), findsWidgets);
    });

    testWidgets('renders FOH header label', (tester) async {
      await tester.pumpWidget(_wrap(ScheduleDayRow.header()));
      await tester.pump();

      expect(find.text('FOH'), findsOneWidget);
    });

    testWidgets('renders BOH header label', (tester) async {
      await tester.pumpWidget(_wrap(ScheduleDayRow.header()));
      await tester.pump();

      expect(find.text('BOH'), findsOneWidget);
    });
  });

  group('ScheduleDayRow — isTotal mode', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'TOTAL',
          forecastCovers: 1200,
          forecastSales: 50400.0,
          requiredFohHours: 267,
          requiredBohHours: 280,
          isTotal: true,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('TOTAL'), findsOneWidget);
    });
  });

  group('ScheduleDayRow — isSubrow mode', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Lunch',
          forecastCovers: 80,
          forecastSales: 3360.0,
          requiredFohHours: 16,
          requiredBohHours: 18,
          isSubrow: true,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Lunch'), findsOneWidget);
    });
  });

  group('ScheduleDayRow — trailing widget', () {
    testWidgets('trailing widget appears when provided', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Wed',
          forecastCovers: 160,
          forecastSales: 6720.0,
          requiredFohHours: 36,
          requiredBohHours: 38,
          trailing: Icon(Icons.chevron_right, key: Key('trail_icon')),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('trail_icon')), findsOneWidget);
    });

    testWidgets('trailing widget absent when not provided', (tester) async {
      await tester.pumpWidget(_wrap(
        const ScheduleDayRow(
          day: 'Wed',
          forecastCovers: 160,
          forecastSales: 6720.0,
          requiredFohHours: 36,
          requiredBohHours: 38,
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('trail_icon')), findsNothing);
    });
  });
}
