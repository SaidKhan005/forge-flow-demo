import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/widgets/console/console_surface.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('OperatorWebPanel renders the standard heading and body', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const SizedBox(
          width: 520,
          child: OperatorWebPanel(
            title: 'Timing in use',
            subtitle: 'Effective values for the selected scope.',
            child: Text('Timezone: America/Toronto'),
          ),
        ),
      ),
    );

    expect(find.text('Timing in use'), findsOneWidget);
    expect(
      find.text('Effective values for the selected scope.'),
      findsOneWidget,
    );
    expect(find.text('Timezone: America/Toronto'), findsOneWidget);
  });

  testWidgets('section heading keeps actions in a predictable right rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 220,
          child: OperatorWebPanel(
            title: 'People filters',
            trailing: OutlinedButton(
              onPressed: () {},
              child: const Text('Clear filters'),
            ),
            child: const Text('Active filters'),
          ),
        ),
      ),
    );

    expect(find.text('People filters'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Clear filters')).dy,
      greaterThan(tester.getTopLeft(find.text('People filters')).dy),
    );
  });

  testWidgets('OperatorWebBanner supports tone, title, and action', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        OperatorWebBanner(
          tone: OperatorWebBannerTone.warning,
          title: 'Read-only',
          message: 'Owners manage timing changes.',
          action: TextButton(onPressed: () {}, child: const Text('Review')),
        ),
      ),
    );

    expect(find.text('Read-only'), findsOneWidget);
    expect(find.text('Owners manage timing changes.'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });

  testWidgets('showOperatorWebDialog uses the shared compact shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) {
            return FilledButton(
              onPressed: () {
                showOperatorWebDialog<void>(
                  context: context,
                  title: 'Timing changes are unavailable here',
                  icon: Icons.lock_outline,
                  child: const Text('Nothing was changed.'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                );
              },
              child: const Text('Open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(OperatorWebDialog), findsOneWidget);
    expect(find.text('Timing changes are unavailable here'), findsOneWidget);
    expect(find.text('Nothing was changed.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('date range dialog applies the visible range', (tester) async {
    final initial = DateTimeRange(
      start: DateTime(2026, 5, 1),
      end: DateTime(2026, 5, 7),
    );

    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) {
            return FilledButton(
              onPressed: () async {
                final range = await showOperatorWebDateRangeDialog(
                  context: context,
                  initialRange: initial,
                  firstDate: DateTime(2026),
                  lastDate: DateTime(2026, 12, 31),
                );
                if (!context.mounted || range == null) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(range.end.toIso8601String())),
                );
              },
              child: const Text('Pick dates'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Pick dates'));
    await tester.pumpAndSettle();

    expect(find.byType(OperatorWebDateRangeDialog), findsOneWidget);
    expect(find.text('2026-05-01'), findsOneWidget);
    expect(find.text('2026-05-07'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2026-05-07'), findsOneWidget);
  });
}
