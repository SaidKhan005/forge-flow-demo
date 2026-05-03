// Phase 8.0 (V1 lean cut 2) — MetricCardNotYetAvailable widget tests.
//
// Asserts the operator-facing chrome: dash placeholder,
// "Not yet available" caption, and label echoed back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/widgets/metric_card_not_yet_available.dart';

void main() {
  testWidgets('renders dash, label, and "Not yet available" caption',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MetricCardNotYetAvailable(metricLabel: 'CPLH'),
      ),
    ));
    expect(find.byKey(const Key('metric_card_not_yet_available_label')),
        findsOneWidget);
    expect(find.byKey(const Key('metric_card_not_yet_available_dash')),
        findsOneWidget);
    expect(find.byKey(const Key('metric_card_not_yet_available_caption')),
        findsOneWidget);
    expect(find.text('CPLH'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Not yet available'), findsOneWidget);
  });

  testWidgets('label is upper-cased on render', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MetricCardNotYetAvailable(metricLabel: 'blended wage'),
      ),
    ));
    expect(find.text('BLENDED WAGE'), findsOneWidget);
  });
}
