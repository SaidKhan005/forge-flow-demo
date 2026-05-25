// Shared console switch widgets — ConsoleSwitchRow + ConsoleChannelToggle.
//
// These back the unified premium on/off control used across the admin and
// operator-web consoles. The tests assert:
//   * the label (and optional subcopy) render,
//   * the inner Switch reflects the on/off value,
//   * onChanged fires on tap and carries the flipped value,
//   * onChanged == null renders a disabled (inert) switch,
//   * the caller-supplied switchKey lands directly on the inner Switch (so the
//     existing screen tests' `tester.widget<Switch>(find.byKey(...))` finders
//     keep working),
//   * the labeled row keeps a >=44px tap target.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_switch_row.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: Center(child: child)),
  );

  group('ConsoleSwitchRow', () {
    testWidgets('renders label + subcopy and reflects the on value', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          ConsoleSwitchRow(
            switchKey: const Key('row_switch'),
            label: 'Show technical details',
            subcopy: 'Reveals raw signal values.',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Show technical details'), findsOneWidget);
      expect(find.text('Reveals raw signal values.'), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('row_switch')));
      expect(sw.value, isTrue);
      expect(sw.onChanged, isNotNull);
    });

    testWidgets('omits subcopy when not supplied', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConsoleSwitchRow(
            label: 'Show all vendors',
            value: false,
            onChanged: null,
          ),
        ),
      );

      expect(find.text('Show all vendors'), findsOneWidget);
      // Exactly one Text (the label) — no subcopy line.
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('onChanged == null renders a disabled switch', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConsoleSwitchRow(
            switchKey: Key('row_switch'),
            label: 'Disabled row',
            value: false,
            onChanged: null,
          ),
        ),
      );

      final sw = tester.widget<Switch>(find.byKey(const Key('row_switch')));
      expect(sw.onChanged, isNull);
    });

    testWidgets('tapping the switch fires onChanged with the flipped value', (
      tester,
    ) async {
      bool? received;
      await tester.pumpWidget(
        wrap(
          ConsoleSwitchRow(
            switchKey: const Key('row_switch'),
            label: 'Toggle me',
            value: false,
            onChanged: (v) => received = v,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('row_switch')));
      await tester.pumpAndSettle();
      expect(received, isTrue);
    });

    testWidgets('keeps a >=44px tap-target row height', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConsoleSwitchRow(
            switchKey: const Key('row_switch'),
            label: 'Tall enough',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );

      final size = tester.getSize(find.byType(ConsoleSwitchRow));
      expect(size.height, greaterThanOrEqualTo(44.0));
    });
  });

  group('ConsoleChannelToggle', () {
    testWidgets('renders channel label and reflects value', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConsoleChannelToggle(
            switchKey: const Key('chan_switch'),
            label: 'Email',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Email'), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('chan_switch')));
      expect(sw.value, isTrue);
      expect(sw.onChanged, isNotNull);
    });

    testWidgets('onChanged == null renders a disabled channel switch', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const ConsoleChannelToggle(
            switchKey: Key('chan_switch'),
            label: 'Push Notifications',
            value: false,
            onChanged: null,
          ),
        ),
      );

      final sw = tester.widget<Switch>(find.byKey(const Key('chan_switch')));
      expect(sw.onChanged, isNull);
    });

    testWidgets('tapping fires onChanged with the flipped value', (
      tester,
    ) async {
      bool? received;
      await tester.pumpWidget(
        wrap(
          ConsoleChannelToggle(
            switchKey: const Key('chan_switch'),
            label: 'In-App Inbox',
            value: true,
            onChanged: (v) => received = v,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('chan_switch')));
      await tester.pumpAndSettle();
      expect(received, isFalse);
    });
  });
}
