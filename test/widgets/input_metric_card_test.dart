// Widget tests for InputMetricCard.
//
// Coverage:
//   * mounts without crash for a standard (non-hero) metric
//   * metric name is rendered
//   * currentFormatted value is rendered
//   * targetFormatted is rendered
//   * isHero=true renders the DRIVER badge
//   * isHero=false does not render the DRIVER badge
//   * dash delta ('—') path renders the em-dash sentinel, not the arrow badge
//   * non-dash deltaFormatted renders the arrow badge
//   * targetSupportFormatted is rendered when present

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/widgets/input_metric_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

InputMetric _metric({
  String name = 'COVERS',
  String currentFormatted = '1,150',
  String targetFormatted = 'Target 1,200',
  String deltaFormatted = '-50',
  bool deltaUnfavorable = true,
  bool isHero = false,
  String statusLine = 'Below target',
  String? targetSupportFormatted,
}) =>
    InputMetric(
      name: name,
      currentFormatted: currentFormatted,
      targetFormatted: targetFormatted,
      deltaFormatted: deltaFormatted,
      deltaUnfavorable: deltaUnfavorable,
      isHero: isHero,
      statusLine: statusLine,
      targetSupportFormatted: targetSupportFormatted,
    );

void main() {
  group('InputMetricCard', () {
    testWidgets('mounts without crash', (tester) async {
      await tester.pumpWidget(_wrap(InputMetricCard(metric: _metric())));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders metric name in uppercase', (tester) async {
      await tester.pumpWidget(_wrap(InputMetricCard(metric: _metric(name: 'Covers'))));
      await tester.pump();

      // The widget calls .toUpperCase() on the name.
      expect(find.text('COVERS'), findsOneWidget);
    });

    testWidgets('renders currentFormatted value', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(metric: _metric(currentFormatted: '1,150')),
      ));
      await tester.pump();

      expect(find.text('1,150'), findsOneWidget);
    });

    testWidgets('renders targetFormatted', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(metric: _metric(targetFormatted: 'Target 1,200')),
      ));
      await tester.pump();

      expect(find.text('Target 1,200'), findsOneWidget);
    });

    testWidgets('renders statusLine', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(metric: _metric(statusLine: 'Below target')),
      ));
      await tester.pump();

      expect(find.text('Below target'), findsOneWidget);
    });

    testWidgets('isHero=true renders DRIVER badge', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(metric: _metric(isHero: true)),
      ));
      await tester.pump();

      expect(find.text('DRIVER'), findsOneWidget);
    });

    testWidgets('isHero=false does not render DRIVER badge', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(metric: _metric(isHero: false)),
      ));
      await tester.pump();

      expect(find.text('DRIVER'), findsNothing);
    });

    testWidgets('dash delta renders em-dash sentinel, not arrow row',
        (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(
          metric: _metric(deltaFormatted: '—'),
        ),
      ));
      await tester.pump();

      // Em-dash sentinel text must be present.
      expect(find.text('—'), findsOneWidget);
      // Arrow icons are not rendered in the dash-delta path.
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
    });

    testWidgets('non-dash deltaFormatted renders arrow icon', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(
          metric: _metric(deltaFormatted: '-50', deltaUnfavorable: true),
        ),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });

    testWidgets('favorable delta renders upward arrow', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(
          metric: _metric(deltaFormatted: '+50', deltaUnfavorable: false),
        ),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('targetSupportFormatted rendered when present', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(
          metric: _metric(targetSupportFormatted: 'In the books 72'),
        ),
      ));
      await tester.pump();

      expect(find.text('In the books 72'), findsOneWidget);
    });

    testWidgets('targetSupportFormatted absent when null', (tester) async {
      await tester.pumpWidget(_wrap(
        InputMetricCard(
          metric: _metric(targetSupportFormatted: null),
        ),
      ));
      await tester.pump();

      expect(find.text('In the books 72'), findsNothing);
    });
  });
}
