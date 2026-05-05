// Phase 8 spine-bridge Lane .B — CoversHistoricalSeedCard tests.
//
// Cover acceptance item F: 60-day matrix entry + bulk paste shortcut.
// Spot-checks the matrix surface (one row per date × 3 daypart cells),
// the apply-button enable rules, the apply payload, and the bulk paste
// dialog opening.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/operator_web/widgets/covers_historical_seed_card.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('CoversHistoricalSeedCard', () {
    testWidgets('card renders 60 date rows x 3 daypart cells',
        (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: const <String, Map<Daypart, int>>{},
          onApplySeed: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_covers_historical_seed_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('covers_historical_seed_2026-05-04_lunch')),
        findsOneWidget,
      );
    });

    testWidgets('cells pre-fill from initialEntries', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: <String, Map<Daypart, int>>{
            '2026-05-04': <Daypart, int>{Daypart.dinner: 220},
          },
          onApplySeed: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('covers_historical_seed_2026-05-04_dinner')),
      );
      expect(field.controller!.text, equals('220'));
    });

    testWidgets('apply button disabled when draft empty', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: const <String, Map<Daypart, int>>{},
          onApplySeed: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('covers_historical_seed_apply')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('apply button enabled after typing into a cell',
        (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: const <String, Map<Daypart, int>>{},
          onApplySeed: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('covers_historical_seed_2026-05-04_lunch')),
        '120',
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('covers_historical_seed_apply')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('apply button calls onApplySeed with the draft',
        (tester) async {
      await sizeViewport(tester);
      final captured = <Map<String, Map<Daypart, int>>>[];

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: const <String, Map<Daypart, int>>{},
          onApplySeed: captured.add,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('covers_historical_seed_2026-05-04_lunch')),
        '95',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('covers_historical_seed_apply')),
      );
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      expect(
        captured.single,
        equals(<String, Map<Daypart, int>>{
          '2026-05-04': <Daypart, int>{Daypart.lunch: 95},
        }),
      );
    });

    testWidgets('bulk paste button opens dialog', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(wrap(
        CoversHistoricalSeedCard(
          endDateIso: '2026-05-04',
          dayCount: 60,
          initialEntries: const <String, Map<Daypart, int>>{},
          onApplySeed: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('covers_historical_seed_bulk_paste')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });
}
