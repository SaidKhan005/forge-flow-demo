// Phase 8 spine-bridge Lane .B — WalkInHandlingCard widget tests.
//
// Cover acceptance item E: 3-mode picker + daily walk-in count entry
// surfaces only in `walkInsAddedToReservations` mode (mode A).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/operator_web/widgets/walk_in_handling_card.dart';
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

  group('WalkInHandlingCard', () {
    testWidgets('card renders 3 mode radios', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.reservationsOnly,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: null,
            onDailyWalkInCountChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('walk_in_handling_radio_reservations_only')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('walk_in_handling_radio_added')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('walk_in_handling_radio_separate')),
        findsOneWidget,
      );
    });

    testWidgets('card key + title visible', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.reservationsOnly,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: null,
            onDailyWalkInCountChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_walk_in_handling_card')),
        findsOneWidget,
      );
    });

    testWidgets('source label renders when server metadata exists', (
      tester,
    ) async {
      await sizeViewport(tester);

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.reservationsOnly,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: null,
            onDailyWalkInCountChanged: (_) {},
            source: const DataAccuracySettingSource(
              scopeType: 'default',
              sourceKind: 'default',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('walk_in_handling_source_label')),
        findsOneWidget,
      );
      expect(find.text('Source: Default'), findsOneWidget);
    });

    testWidgets('tapping a mode emits onModeChanged', (tester) async {
      await sizeViewport(tester);
      final captured = <WalkInHandlingMode>[];

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.reservationsOnly,
            onModeChanged: captured.add,
            businessDateIso: '2026-05-05',
            dailyWalkInCount: null,
            onDailyWalkInCountChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('walk_in_handling_radio_added')));
      await tester.pumpAndSettle();

      expect(
        captured,
        equals(<WalkInHandlingMode>[
          WalkInHandlingMode.walkInsAddedToReservations,
        ]),
      );
    });

    testWidgets(
      'daily walk-in count field appears only in walkInsAddedToReservations mode',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          wrap(
            WalkInHandlingCard(
              mode: WalkInHandlingMode.reservationsOnly,
              onModeChanged: (_) {},
              businessDateIso: '2026-05-05',
              dailyWalkInCount: null,
              onDailyWalkInCountChanged: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('walk_in_handling_daily_count_field')),
          findsNothing,
        );

        await tester.pumpWidget(
          wrap(
            WalkInHandlingCard(
              mode: WalkInHandlingMode.walkInsAddedToReservations,
              onModeChanged: (_) {},
              businessDateIso: '2026-05-05',
              dailyWalkInCount: null,
              onDailyWalkInCountChanged: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('walk_in_handling_daily_count_field')),
          findsOneWidget,
        );

        await tester.pumpWidget(
          wrap(
            WalkInHandlingCard(
              mode: WalkInHandlingMode.walkInsTrackedSeparately,
              onModeChanged: (_) {},
              businessDateIso: '2026-05-05',
              dailyWalkInCount: null,
              onDailyWalkInCountChanged: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('walk_in_handling_daily_count_field')),
          findsNothing,
        );
      },
    );

    testWidgets('submitting daily walk-in count emits parsed int', (
      tester,
    ) async {
      await sizeViewport(tester);
      final captured = <int?>[];

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.walkInsAddedToReservations,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: null,
            onDailyWalkInCountChanged: captured.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('walk_in_handling_daily_count_field')),
        '14',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(captured, equals(<int?>[14]));
    });

    testWidgets('submitting empty value emits null', (tester) async {
      await sizeViewport(tester);
      final captured = <int?>[];

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.walkInsAddedToReservations,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: 14,
            onDailyWalkInCountChanged: captured.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('walk_in_handling_daily_count_field')),
        '',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(captured, equals(<int?>[null]));
    });

    testWidgets('pre-fills field from dailyWalkInCount', (tester) async {
      await sizeViewport(tester);

      await tester.pumpWidget(
        wrap(
          WalkInHandlingCard(
            mode: WalkInHandlingMode.walkInsAddedToReservations,
            onModeChanged: (_) {},
            businessDateIso: '2026-05-05',
            dailyWalkInCount: 22,
            onDailyWalkInCountChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('walk_in_handling_daily_count_field')),
      );
      expect(field.controller!.text, equals('22'));
    });
  });
}
