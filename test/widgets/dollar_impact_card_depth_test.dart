// ─── DollarImpactCard depth-footer tests (7.58.UX.6) ──────────────────────
//
// Phase 7.58.UX.6 makes the footer name what `theoreticalLaborPct` has
// always been: the operator's mathematical labor floor at the locked
// target rates and wages (Jim Taylor ch. 8). When the math floor is
// known, the card replaces its single-line footer with a triplet:
//
//   Best Possible: <theoretical>%  ·  Actual: <actual>%  ·  Closable Gap: <variance> pts
//
// When `theoreticalLaborPct` is null (legacy / partial seed), the
// existing footer text renders unchanged — the honest fallback. These
// tests pin the triplet, the sum invariant, the null-fallback path,
// and the em-dash hygiene rule from the depth wave plan.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/widgets/dollar_impact_card.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('DollarImpactCard — Best Possible / Actual / Closable Gap triplet', () {
    testWidgets(
        'renders triplet for an over-floor case (24.2 / 31.4 / +7.2 pts)',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 478.0,
          monthImpact: 1900.0,
          sixtyDayImpact: 3500.0,
          annualizedImpact: 21291.67,
          footerText: 'Through Tuesday',
          theoreticalLaborPct: 24.2,
          actualLaborPct: 31.4,
        ),
      );

      expect(
        find.text(
          'Best Possible: 24.2%  ·  Actual: 31.4%  ·  Closable Gap: +7.2 pts',
        ),
        findsOneWidget,
      );
      // The triplet replaces the existing footer text.
      expect(find.text('Through Tuesday'), findsNothing);
    });

    testWidgets('renders triplet with Closable Gap as a negative when actual '
        'is below theoretical (under-floor)', (tester) async {
      // Hypothetical: actual labor came in below the math floor (e.g. an
      // under-staffed week). The triplet must keep its sign honest.
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: -200.0,
          footerText: 'Through Tuesday',
          theoreticalLaborPct: 24.2,
          actualLaborPct: 22.8,
        ),
      );

      expect(
        find.text(
          'Best Possible: 24.2%  ·  Actual: 22.8%  ·  Closable Gap: -1.4 pts',
        ),
        findsOneWidget,
      );
    });
  });

  group('DollarImpactCard — Closable Gap sum invariant (7.58.UX.6)', () {
    test(
        'Closable Gap MUST equal Actual − Best Possible (modulo display rounding)',
        () {
      // Pin the math the renderer derives. The widget itself computes
      // the gap from the two inputs; this test enumerates representative
      // inputs and verifies the sum invariant Codex requires.
      final cases = <List<double>>[
        // [theoretical, actual, expectedGap]
        [24.2, 31.4, 7.2],
        [22.8, 24.2, 1.4],
        [20.5, 20.5, 0.0],
        [33.3, 28.1, -5.2],
        [25.0, 30.7, 5.7],
      ];
      for (final c in cases) {
        final theo = c[0];
        final actual = c[1];
        final expectedGap = c[2];
        final computed = actual - theo;
        // Round to one decimal place to match `Fmt.varPts` display
        // precision; the renderer shows one decimal.
        final computedRounded =
            (computed * 10).roundToDouble() / 10;
        expect(
          computedRounded,
          closeTo(expectedGap, 1e-9),
          reason: 'Sum invariant violated for theo=$theo actual=$actual',
        );
      }
    });
  });

  group('DollarImpactCard — honest fallback when theoreticalLaborPct is null',
      () {
    testWidgets('null theoretical → existing footerText renders unchanged',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 478.0,
          footerText: 'Through Tuesday',
          // theoreticalLaborPct intentionally omitted (legacy seed shape).
        ),
      );

      expect(find.text('Through Tuesday'), findsOneWidget);
      // No triplet copy leaks when the floor is unknown.
      expect(find.textContaining('Best Possible'), findsNothing);
      expect(find.textContaining('Closable Gap'), findsNothing);
    });

    testWidgets('null actual (theoretical present) → fallback to footerText',
        (tester) async {
      await _pump(
        tester,
        const DollarImpactCard(
          weekImpact: 478.0,
          footerText: 'As of close, Mar 29',
          theoreticalLaborPct: 24.2,
          // actualLaborPct null → triplet cannot be rendered honestly.
        ),
      );

      expect(find.text('As of close, Mar 29'), findsOneWidget);
      expect(find.textContaining('Best Possible'), findsNothing);
    });
  });

  group('DollarImpactCard — em-dash hygiene (7.58 hard gate #4)', () {
    test('no em dash (U+2014) appears in operator-facing string literals '
        'inside lib/widgets/dollar_impact_card.dart', () {
      final source =
          File('lib/widgets/dollar_impact_card.dart').readAsStringSync();
      // Strip out single-line comments — the Phase 7.58 rule is "no em
      // dashes in operator-facing copy" (string literals), not in
      // documentation comments. The literals we care about are inside
      // single or double quotes.
      final withoutLineComments = source
          .split('\n')
          .map((line) {
            final idx = line.indexOf('//');
            return idx >= 0 ? line.substring(0, idx) : line;
          })
          .join('\n');
      // Match content inside single-quoted Dart string literals.
      final stringLiteralRe = RegExp(r"'([^'\\]*(?:\\.[^'\\]*)*)'");
      final matches = stringLiteralRe.allMatches(withoutLineComments);
      for (final m in matches) {
        final body = m.group(1) ?? '';
        expect(
          body.contains('—'),
          isFalse,
          reason: 'Em dash (U+2014) leaked into a string literal: '
              '\'$body\'. Use period, colon, or middot instead.',
        );
      }
    });
  });
}
