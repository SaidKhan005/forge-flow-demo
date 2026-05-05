// Phase 8 spine-bridge Lane .B — CoversSourceToggle widget tests.
//
// Covers walkthrough acceptance item B — tapping manual for dinner
// emits onChanged(Daypart.dinner, CoversSource.manual). The widget
// itself does NOT render the manual-entry sub-card; that surface is
// owned by the parent screen. This file validates the per-daypart
// chip wiring + the relativity label below it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/operator_web/widgets/covers_source_toggle.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  DataAccuracySettings settingsWith({
    CoversSource lunch = CoversSource.vendor,
    CoversSource dinner = CoversSource.vendor,
    CoversSource lateNight = CoversSource.vendor,
  }) {
    return DataAccuracySettings(
      settingId: 'test-setting',
      operatorId: 'brio-operator',
      locationId: 'brio-chicago-loop',
      coversSourceLunch: lunch,
      coversSourceDinner: dinner,
      coversSourceLateNight: lateNight,
      coversManualEntries: const <String, Map<String, int>>{},
      wageSource: WageSource.vendor,
      createdAt: DateTime.utc(2026, 5, 5),
      updatedAt: DateTime.utc(2026, 5, 5),
    );
  }

  testWidgets(
    'CoversSourceToggle renders 3 daypart rows with 3 chips each',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 800));

      await tester.pumpWidget(
        wrap(
          CoversSourceToggle(
            settings: settingsWith(),
            onChanged: (_, __) {},
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Card key.
      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsOneWidget,
      );

      // Daypart rows.
      expect(
        find.byKey(const Key('covers_source_daypart_lunch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('covers_source_daypart_dinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('covers_source_daypart_late_night')),
        findsOneWidget,
      );

      // Each row has 3 chips: vendor / forecast / manual.
      for (final daypart in <String>['lunch', 'dinner', 'late_night']) {
        expect(
          find.byKey(Key('covers_source_chip_${daypart}_vendor')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('covers_source_chip_${daypart}_forecast')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('covers_source_chip_${daypart}_manual')),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets(
    'tapping manual chip for dinner emits onChanged(dinner, manual)',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 800));

      Daypart? capturedDaypart;
      CoversSource? capturedSource;

      await tester.pumpWidget(
        wrap(
          CoversSourceToggle(
            settings: settingsWith(),
            onChanged: (daypart, source) {
              capturedDaypart = daypart;
              capturedSource = source;
            },
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('covers_source_chip_dinner_manual')),
      );
      await tester.pumpAndSettle();

      expect(capturedDaypart, equals(Daypart.dinner));
      expect(capturedSource, equals(CoversSource.manual));
    },
  );

  testWidgets(
    'selected chip flip after re-pump',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 800));

      // Initial: dinner = vendor.
      await tester.pumpWidget(
        wrap(
          CoversSourceToggle(
            settings: settingsWith(dinner: CoversSource.vendor),
            onChanged: (_, __) {},
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('covers_source_chip_dinner_vendor')),
        findsOneWidget,
      );

      // Re-pump with dinner = manual.
      await tester.pumpWidget(
        wrap(
          CoversSourceToggle(
            settings: settingsWith(dinner: CoversSource.manual),
            onChanged: (_, __) {},
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('covers_source_chip_dinner_manual')),
        findsOneWidget,
      );
    },
  );

  testWidgets('vendor relativity label is present', (tester) async {
    await sizeViewport(tester, const Size(1280, 800));

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          onChanged: (_, __) {},
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('vendor_relativity_label_covers')),
      findsOneWidget,
    );
  });
}
