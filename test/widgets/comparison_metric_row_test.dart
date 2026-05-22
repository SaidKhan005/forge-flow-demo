// Widget tests for ComparisonMetricRow.
//
// Coverage:
//   * mounts without crash with all required fields
//   * label, target, actual, variance strings all appear in the tree
//   * isBold=true variant mounts without crash
//   * varColor parameter is accepted (no assertion / crash)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/widgets/comparison_metric_row.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  group('ComparisonMetricRow', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
        ),
      ));
      await tester.pump();

      expect(find.text('Labor %'), findsOneWidget);
    });

    testWidgets('renders target text', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
        ),
      ));
      await tester.pump();

      expect(find.text('20.6%'), findsOneWidget);
    });

    testWidgets('renders actual text', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
        ),
      ));
      await tester.pump();

      expect(find.text('22.1%'), findsOneWidget);
    });

    testWidgets('renders variance text', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
        ),
      ));
      await tester.pump();

      expect(find.text('+1.5'), findsOneWidget);
    });

    testWidgets('isBold=true variant mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'TOTAL',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
          isBold: true,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('TOTAL'), findsOneWidget);
    });

    testWidgets('varColor parameter accepted without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
          varColor: Colors.red,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('+1.5'), findsOneWidget);
    });

    testWidgets('custom verticalPadding accepted without crash', (tester) async {
      await tester.pumpWidget(_wrap(
        const ComparisonMetricRow(
          label: 'Labor %',
          target: '20.6%',
          actual: '22.1%',
          variance: '+1.5',
          verticalPadding: 14,
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
