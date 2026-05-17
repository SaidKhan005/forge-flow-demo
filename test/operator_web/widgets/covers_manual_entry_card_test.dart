// Phase 8 spine-bridge Lane .B — CoversManualEntryCard widget tests.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the card iterates the
// operator-configured service periods passed in by the screen, keyed
// by service_period_id, NOT a hardcoded `Daypart` enum.
//
// Cover acceptance item C: non-negative integer validation +
// "copy yesterday" populates. The widget uses
// `FilteringTextInputFormatter.digitsOnly` so negatives cannot be
// typed — these tests cover the positive submission path, the
// empty-clear path, the copy-yesterday enable/disable, and the
// pre-fill from `coversManualEntries[today][servicePeriodId]`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/operator_web/widgets/covers_manual_entry_card.dart';
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

  final periods = ServicePeriodDefinitionResolver.demoDefinitions;

  DataAccuracySettings buildSettings({
    CoversSource lunch = CoversSource.vendor,
    CoversSource dinner = CoversSource.manual,
    CoversSource lateNight = CoversSource.vendor,
    Map<String, Map<String, int>> manualEntries =
        const <String, Map<String, int>>{},
  }) =>
      DataAccuracySettings(
        settingId: 'test-id',
        operatorId: 'op',
        locationId: 'loc',
        coversSourcePerServicePeriod: <String, CoversSource>{
          'lunch': lunch,
          'dinner': dinner,
          'late_night': lateNight,
        },
        coversManualEntries: manualEntries,
        wageSource: WageSource.vendor,
        createdAt: DateTime.utc(2026, 5, 5),
        updatedAt: DateTime.utc(2026, 5, 5),
      );

  group('CoversManualEntryCard', () {
    testWidgets('card renders with hint when no period is manual',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(
        lunch: CoversSource.vendor,
        dinner: CoversSource.vendor,
        lateNight: CoversSource.vendor,
      );

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (_, __) {},
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_covers_manual_entry_card')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Switch a service period to'),
        findsOneWidget,
      );
    });

    testWidgets('renders one input row per manual period',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(
        lunch: CoversSource.vendor,
        dinner: CoversSource.manual,
        lateNight: CoversSource.manual,
      );

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (_, __) {},
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('covers_manual_entry_field_dinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('covers_manual_entry_field_late_night')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('covers_manual_entry_field_lunch')),
        findsNothing,
      );
    });

    testWidgets(
        'submitting digits invokes onEnterCovers with the parsed int',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(dinner: CoversSource.manual);
      final captured = <(String, int?)>[];

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (d, v) => captured.add((d, v)),
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('covers_manual_entry_field_dinner')),
        '127',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(captured, equals(<(String, int?)>[('dinner', 127)]));
    });

    testWidgets('empty submission emits null (clear)', (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(dinner: CoversSource.manual);
      final captured = <(String, int?)>[];

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (d, v) => captured.add((d, v)),
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('covers_manual_entry_field_dinner')),
        '',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(captured, equals(<(String, int?)>[('dinner', null)]));
    });

    testWidgets(
        'copy yesterday button populates the field when yesterday\'s value exists',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(
        dinner: CoversSource.manual,
        manualEntries: <String, Map<String, int>>{
          '2026-05-04': <String, int>{'dinner': 187},
        },
      );
      final copied = <String>[];

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (_, __) {},
          onCopyYesterday: copied.add,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('covers_manual_entry_copy_yesterday_dinner')),
      );
      await tester.pumpAndSettle();

      expect(copied, equals(<String>['dinner']));
    });

    testWidgets(
        'copy yesterday button is disabled when yesterday has no value',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(dinner: CoversSource.manual);

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (_, __) {},
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(
        find.byKey(const Key('covers_manual_entry_copy_yesterday_dinner')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('pre-fills field from manualEntries[today][servicePeriodId]',
        (tester) async {
      await sizeViewport(tester);
      final settings = buildSettings(
        dinner: CoversSource.manual,
        manualEntries: <String, Map<String, int>>{
          '2026-05-05': <String, int>{'dinner': 200},
        },
      );

      await tester.pumpWidget(wrap(
        CoversManualEntryCard(
          businessDateIso: '2026-05-05',
          yesterdayBusinessDateIso: '2026-05-04',
          settings: settings,
          servicePeriods: periods,
          onEnterCovers: (_, __) {},
          onCopyYesterday: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('covers_manual_entry_field_dinner')),
      );
      expect(field.controller!.text, equals('200'));
    });
  });
}
