// Wave 2 S-1 — widget tests for the blended-wage summary card.
//
// Asserts:
//   * Card mounts with the expected key.
//   * Empty-state copy renders when no rows have hours.
//   * Totals + blended hourly + per-bucket badges render when data
//     is present and obey the UX writing standard (plain English,
//     no engineer-string wire values).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/screens/wage_authority/blended_wage_calculator.dart';
import 'package:forge_and_flow/operator_web/screens/wage_authority/blended_wage_summary_card.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  testWidgets('renders empty-state copy when no rows have hours',
      (tester) async {
    final summary = computeBlendedWageSummary(
      rows: const <BlendedWageInputRow>[],
      bucketOrder: const <String>['foh', 'boh', 'manager'],
    );
    await tester.pumpWidget(wrap(BlendedWageSummaryCard(summary: summary)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('wage_authority_blended_summary_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_empty')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_hourly')),
      findsNothing,
    );
  });

  testWidgets('renders totals + blended hourly when rows have hours',
      (tester) async {
    final summary = computeBlendedWageSummary(
      rows: const <BlendedWageInputRow>[
        BlendedWageInputRow(
          laborBucket: 'foh',
          hourlyRate: 16.0,
          weightedHours: 8,
        ),
        BlendedWageInputRow(
          laborBucket: 'boh',
          hourlyRate: 20.0,
          weightedHours: 8,
        ),
      ],
      bucketOrder: const <String>['foh', 'boh', 'manager'],
    );
    await tester.pumpWidget(wrap(BlendedWageSummaryCard(summary: summary)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('wage_authority_blended_summary_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_hourly')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_totals_line')),
      findsOneWidget,
    );
    // Blended (16 × 8 + 20 × 8) / 16 = (128 + 160) / 16 = 18.00.
    expect(find.textContaining('\$18.00/hr'), findsOneWidget);
    // Two badges (FOH + BOH); Management has zero hours and is hidden.
    expect(
      find.byKey(const Key('wage_authority_blended_bucket_badge_foh')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_bucket_badge_boh')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_authority_blended_bucket_badge_manager')),
      findsNothing,
    );
    // No raw bucket wire values leak into operator-facing copy.
    expect(find.text('foh'), findsNothing);
    expect(find.text('boh'), findsNothing);
    expect(find.text('manager'), findsNothing);
  });
}
