// Tests for the shared DollarImpactCard widget.
//
// Phase 7.55q.10: this widget is the single source of truth for the
// Dollar Impact view on both the live Variance card (current week) and
// Week Detail (closed weeks). These tests guard the row-count gating
// (1 / 2 / 4 rows depending on which optional values are non-null), the
// sign convention (over model => − red; under model => + green), and
// the footerText pass-through (so callers can render "Through Tuesday"
// or "As of close, Mar 29" or any boilerplate fallback without the
// widget interpreting it).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/widgets/dollar_impact_card.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('DollarImpactCard - row gating', () {
    testWidgets('renders only the week row when all optionals are null',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 100.0,
          footerText: 'Through Tuesday',
        ),
      );

      expect(find.text('this week'), findsOneWidget);
      expect(find.text('this month'), findsNothing);
      expect(find.text('last 60 days'), findsNothing);
      expect(find.text('annualized'), findsNothing);
      expect(find.text('Through Tuesday'), findsOneWidget);
    });

    testWidgets(
        'renders 2 rows (week + annualized) when only annualized is set '
        '— legacy WeekRecord shape', (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 100.0,
          annualizedImpact: 5200.0,
          footerText: 'At \$3M annual sales. One location.',
        ),
      );

      expect(find.text('this week'), findsOneWidget);
      expect(find.text('this month'), findsNothing);
      expect(find.text('last 60 days'), findsNothing);
      expect(find.text('annualized'), findsOneWidget);
      expect(find.text('At \$3M annual sales. One location.'), findsOneWidget);
    });

    testWidgets(
        'renders all 4 rows when month + 60-day + annualized are set '
        '— frozen-at-close WeekRecord shape', (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 100.0,
          monthImpact: 400.0,
          sixtyDayImpact: 700.0,
          annualizedImpact: 4258.33,
          footerText: 'As of close, Mar 29',
        ),
      );

      expect(find.text('this week'), findsOneWidget);
      expect(find.text('this month'), findsOneWidget);
      expect(find.text('last 60 days'), findsOneWidget);
      expect(find.text('annualized'), findsOneWidget);
      expect(find.text('As of close, Mar 29'), findsOneWidget);
    });
  });

  group('DollarImpactCard - sign convention', () {
    testWidgets('positive value (over model) renders with leading minus',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 478.0,
          footerText: 'Through Tuesday',
        ),
      );
      // Unicode minus U+2212 prefix on positive (over-model) values.
      expect(find.text('\u2212\$478'), findsOneWidget);
    });

    testWidgets('negative value (under model) renders with leading plus',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: -396.0,
          footerText: 'Through Tuesday',
        ),
      );
      expect(find.text('+\$396'), findsOneWidget);
    });

    testWidgets('zero value renders as +\$0 (under-model side)',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 0.0,
          footerText: 'Through Tuesday',
        ),
      );
      expect(find.text('+\$0'), findsOneWidget);
    });
  });

  group('DollarImpactCard - footer pass-through', () {
    testWidgets('footerText renders verbatim — widget does not interpret it',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 100.0,
          footerText: 'Arbitrary footer string xyz123',
        ),
      );
      expect(find.text('Arbitrary footer string xyz123'), findsOneWidget);
    });
  });
}
