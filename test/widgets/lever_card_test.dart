// ─── LeverCardWidget tests ─────────────────────────────────────────────
// 7.58.UX.1 — pin the optional `dollarImpactByAxis` rendering contract:
//   - omitted/null → existing card layout unchanged (no DOLLAR ATTRIBUTION
//     section).
//   - non-null → DOLLAR ATTRIBUTION section renders with a primary
//     sentence naming the dominant axis and a per-axis breakdown for
//     contributions whose absolute value is at least $1.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/widgets/lever_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('LeverCardWidget — null dollarImpactByAxis (existing card preserved)',
      () {
    testWidgets('renders WHAT HAPPENED + WHAT TO STUDY without attribution',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(data: LeverCards.coversDown),
      ));
      await tester.pump();

      expect(find.text('WHAT HAPPENED'), findsOneWidget);
      expect(find.text('WHAT TO STUDY'), findsOneWidget);
      expect(find.text('DOLLAR ATTRIBUTION'), findsNothing);
    });

    testWidgets('explicit null param matches default omission',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(
          data: LeverCards.coversDown,
          dollarImpactByAxis: null,
        ),
      ));
      await tester.pump();

      expect(find.text('DOLLAR ATTRIBUTION'), findsNothing);
    });
  });

  group('LeverCardWidget — non-null dollarImpactByAxis (7.58.UX.1)', () {
    testWidgets(
        'renders DOLLAR ATTRIBUTION header + dominant-axis primary sentence',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(
          data: LeverCards.coversDown,
          dollarImpactByAxis: {
            'covers_down': 112.0,
            'covers_up': 0.0,
            'ppa_down': 24.0,
            'ppa_up': 0.0,
            'cplh_down': 32.0,
            'cplh_up': 0.0,
            'splh_down': 0.0,
            'splh_up': -12.0,
            'foh_wage_down': 0.0,
            'foh_wage_up': 0.0,
            'boh_wage_down': 0.0,
            'boh_wage_up': 0.0,
            'foh_hours_over': 0.0,
            'foh_hours_under': 0.0,
            'boh_hours_over': 0.0,
            'boh_hours_under': 0.0,
          },
        ),
      ));
      await tester.pump();

      expect(find.text('DOLLAR ATTRIBUTION'), findsOneWidget);
      // Total = 112 + 24 + 32 - 12 = 156. Dominant axis = covers_down ($112).
      expect(
        find.text('covers explained \$112 of the \$156 gap.'),
        findsOneWidget,
      );
    });

    testWidgets('per-axis breakdown lists axes above the \$1 threshold',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(
          data: LeverCards.coversDown,
          dollarImpactByAxis: {
            'covers_down': 112.0,
            'covers_up': 0.0,
            'ppa_down': 24.0,
            'ppa_up': 0.0,
            'cplh_down': 32.0,
            'cplh_up': 0.0,
            'splh_down': 0.0,
            'splh_up': -12.0,
            'foh_wage_down': 0.0,
            'foh_wage_up': 0.0,
            'boh_wage_down': 0.0,
            'boh_wage_up': 0.0,
            'foh_hours_over': 0.0,
            'foh_hours_under': 0.0,
            'boh_hours_over': 0.0,
            'boh_hours_under': 0.0,
          },
        ),
      ));
      await tester.pump();

      // Unfavorable rows render with `−$X` sign (covers, ppa, cplh).
      // Favorable row renders with `+$X` sign (splh under-model).
      expect(find.text('−\$112'), findsOneWidget);
      expect(find.text('−\$32'), findsOneWidget);
      expect(find.text('−\$24'), findsOneWidget);
      expect(find.text('+\$12'), findsOneWidget);

      // Axis labels accompany each row.
      expect(find.text('covers'), findsOneWidget);
      expect(find.text('cplh'), findsOneWidget);
      expect(find.text('ppa'), findsOneWidget);
      expect(find.text('splh'), findsOneWidget);

      // Axes whose pair sums to 0 (within the $1 threshold) are filtered
      // out: foh wage, boh wage, foh hours, boh hours should not appear.
      expect(find.text('foh wage'), findsNothing);
      expect(find.text('boh wage'), findsNothing);
      expect(find.text('foh hours'), findsNothing);
      expect(find.text('boh hours'), findsNothing);
    });

    testWidgets(
        'rounding noise (<\$1 contribution) is filtered from breakdown',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(
          data: LeverCards.cplhDown,
          dollarImpactByAxis: {
            'covers_down': 0.0,
            'covers_up': 0.0,
            'ppa_down': 0.0,
            'ppa_up': 0.0,
            'cplh_down': 50.0,
            'cplh_up': 0.0,
            'splh_down': 0.40,
            'splh_up': 0.0,
            'foh_wage_down': 0.0,
            'foh_wage_up': 0.0,
            'boh_wage_down': 0.0,
            'boh_wage_up': 0.0,
            'foh_hours_over': 0.0,
            'foh_hours_under': 0.0,
            'boh_hours_over': 0.0,
            'boh_hours_under': 0.0,
          },
        ),
      ));
      await tester.pump();

      // cplh row renders; splh row (sum < $1) is filtered out.
      expect(find.text('cplh'), findsOneWidget);
      expect(find.text('splh'), findsNothing);
    });

    testWidgets('favorable dominant axis renders +\$ sign on its row',
        (tester) async {
      // coversUp: under-model favorable scenario.
      await tester.pumpWidget(_wrap(
        const LeverCardWidget(
          data: LeverCards.coversUp,
          dollarImpactByAxis: {
            'covers_down': 0.0,
            'covers_up': -100.0,
            'ppa_down': 0.0,
            'ppa_up': 0.0,
            'cplh_down': 0.0,
            'cplh_up': 0.0,
            'splh_down': 0.0,
            'splh_up': 0.0,
            'foh_wage_down': 0.0,
            'foh_wage_up': 0.0,
            'boh_wage_down': 0.0,
            'boh_wage_up': 0.0,
            'foh_hours_over': 0.0,
            'foh_hours_under': 0.0,
            'boh_hours_over': 0.0,
            'boh_hours_under': 0.0,
          },
        ),
      ));
      await tester.pump();

      // Primary sentence uses absolute dollars; row carries the favorable
      // `+$` sign.
      expect(
        find.text('covers explained \$100 of the \$100 gap.'),
        findsOneWidget,
      );
      expect(find.text('+\$100'), findsOneWidget);
    });
  });
}
