// In-app text-size stepper tests (accessibility pass, rec #12,
// 2026-07-24). Pins:
//   * persistence: a chosen step writes through to SharedPreferences
//     and a fresh load restores it;
//   * application: BarrioTextScale overrides MediaQuery.textScaler for
//     the subtree;
//   * composition: the step multiplier MULTIPLIES the system scaler
//     (system 1.3 x Extra large 1.3 = 1.69), never replaces it;
//   * the sheet: tapping a step applies + persists it;
//   * the home header's Aa entry opens the sheet.
//
// The home screen runs looping ambient motion: NEVER pumpAndSettle
// there; pump explicit durations only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_text_size.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_text_scale.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_text_size_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BarrioTextSizeController.resetForTest();
  });

  group('BarrioTextSizeController', () {
    test('set persists the step to SharedPreferences', () async {
      await BarrioTextSizeController.set(BarrioTextSize.large);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BarrioTextSizeController.prefsKey), 'large');
      expect(BarrioTextSizeController.notifier.value, BarrioTextSize.large);
    });

    test('load restores a persisted step', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BarrioTextSizeController.prefsKey: 'extraLarge',
      });
      BarrioTextSizeController.resetForTest();
      await BarrioTextSizeController.load();
      expect(
          BarrioTextSizeController.notifier.value, BarrioTextSize.extraLarge);
    });

    test('load ignores an unreadable stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BarrioTextSizeController.prefsKey: 'gigantic',
      });
      BarrioTextSizeController.resetForTest();
      await BarrioTextSizeController.load();
      expect(
          BarrioTextSizeController.notifier.value, BarrioTextSize.standard);
    });
  });

  group('BarrioTextScale', () {
    testWidgets('standard step passes the system scaler through unchanged',
        (tester) async {
      late TextScaler seen;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: BarrioTextScale(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.textScalerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen.scale(10), closeTo(13.0, 0.001),
          reason: 'Standard adds nothing on top of the system 1.3x');
    });

    testWidgets('a chosen step composes with the system scaler',
        (tester) async {
      await BarrioTextSizeController.set(BarrioTextSize.extraLarge);
      late TextScaler seen;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: BarrioTextScale(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.textScalerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen.scale(10), closeTo(10 * 1.3 * 1.3, 0.001),
          reason: 'system 1.3 x Extra large 1.3 = 1.69, multiplied, '
              'never replaced');
    });

    testWidgets('changing the step live rebuilds the subtree',
        (tester) async {
      late TextScaler seen;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              BarrioTextScale(child: child ?? const SizedBox.shrink()),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.textScalerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen.scale(10), closeTo(10.0, 0.001));

      await BarrioTextSizeController.set(BarrioTextSize.large);
      await tester.pump();
      expect(seen.scale(10), closeTo(11.5, 0.001));
    });
  });

  group('BarrioTextSizeSheet', () {
    testWidgets('tapping a step applies and persists it', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BarrioTextSizeSheet(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('Card text will read like this.'), findsOneWidget);
      expect(
        find.text('This adds to the text size set on your phone.'),
        findsOneWidget,
      );

      await tester
          .tap(find.byKey(const ValueKey<String>('barrio_text_size_large')));
      await tester.pump();

      expect(BarrioTextSizeController.notifier.value, BarrioTextSize.large);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BarrioTextSizeController.prefsKey), 'large');
      expect(tester.takeException(), isNull);
    });
  });

  group('home header entry', () {
    testWidgets('the Aa button opens the text-size sheet', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: BarrioHomeScreen()),
      );
      await tester.pump(const Duration(milliseconds: 1000));

      await tester.tap(
          find.byKey(const ValueKey<String>('barrio_text_size_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Large'), findsOneWidget);
      expect(find.text('Extra large'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
