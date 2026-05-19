import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/operator_web/widgets/data_accuracy_explainer_card.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  const customPeriods = <ServicePeriodDefinition>[
    ServicePeriodDefinition(
      id: 'breakfast_service',
      label: 'Breakfast service',
      shortLabel: 'B',
      sortOrder: 1,
      startLocalTime: '08:00',
      endLocalTime: '11:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'supper',
      label: 'Supper',
      shortLabel: 'S',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '21:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'late_service',
      label: 'Late service',
      shortLabel: 'L',
      sortOrder: 3,
      startLocalTime: '21:00',
      endLocalTime: '01:00',
      rollsPastMidnight: true,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
  ];

  group('DataAccuracyExplainerCard', () {
    testWidgets('uses configured service-period labels in examples', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const DataAccuracyExplainerCard(servicePeriods: customPeriods)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Example: Square does not track covers. Set Breakfast service and '
          'Supper to Manual, type your numbers nightly, and CPLH stays '
          'trustworthy.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Example: Paste a CSV with date, Breakfast service, Supper, '
          'Late service columns. F&F uses it to forecast next week. You can '
          'edit any cell later.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('date, lunch, dinner'), findsNothing);
      expect(find.textContaining('late_night'), findsNothing);
    });

    testWidgets('uses generic examples when labels are unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const DataAccuracyExplainerCard()));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Example: Square does not track covers. Set any service period '
          'that needs a hand-entered count to Manual, type your numbers '
          'nightly, and CPLH stays trustworthy.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Example: Paste a CSV with one date column and one column for each '
          'service period. F&F uses it to forecast next week. You can edit '
          'any cell later.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Set lunch and dinner'), findsNothing);
      expect(find.textContaining('late_night'), findsNothing);
    });

    testWidgets('describes QuickBooks Time wages as configured rates', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const DataAccuracyExplainerCard()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'QuickBooks Time reports hours and configured rates',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('per-employee dollars'), findsNothing);
    });
  });
}
