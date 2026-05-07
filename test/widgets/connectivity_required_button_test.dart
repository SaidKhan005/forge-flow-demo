// A9.SY1 — ConnectivityRequiredButton widget tests.
//
// Pumps the button in online and offline states; asserts:
//   1. Online → label is the caller-supplied text, button is enabled.
//   2. Offline → label changes to "Requires connection", button is
//      disabled, and the hint copy appears.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/connectivity_notifier.dart';
import 'package:forge_and_flow/widgets/connectivity_required_button.dart';
import 'package:provider/provider.dart';

Widget _wrap({
  required FakeConnectivityNotifier notifier,
  required String label,
  required VoidCallback? onPressed,
}) {
  return MaterialApp(
    home: ChangeNotifierProvider<ConnectivityNotifier>.value(
      value: notifier,
      child: Scaffold(
        body: ConnectivityRequiredButton(
          label: label,
          onPressed: onPressed,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'online: shows caller label and button is tappable',
    (tester) async {
      final notifier = FakeConnectivityNotifier(initiallyOnline: true);
      addTearDown(notifier.dispose);

      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          label: 'DONE',
          onPressed: () => tapped = true,
        ),
      );

      // Label should be caller-supplied text
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('Requires connection'), findsNothing);
      expect(find.text('Reconnect to save changes.'), findsNothing);

      // Button should be enabled and respond to tap
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(tapped, isTrue);
    },
  );

  testWidgets(
    'offline: shows "Requires connection" label, button is disabled, hint shown',
    (tester) async {
      final notifier = FakeConnectivityNotifier(initiallyOnline: false);
      addTearDown(notifier.dispose);

      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          label: 'DONE',
          onPressed: () => tapped = true,
        ),
      );

      // Label should change
      expect(find.text('Requires connection'), findsOneWidget);
      expect(find.text('DONE'), findsNothing);

      // Hint copy should appear
      expect(find.text('Reconnect to save changes.'), findsOneWidget);

      // Button onPressed must be null (disabled)
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);

      // Tapping does nothing
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    },
  );

  testWidgets(
    'transitions: online -> offline -> online updates label correctly',
    (tester) async {
      final notifier = FakeConnectivityNotifier(initiallyOnline: true);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<ConnectivityNotifier>.value(
            value: notifier,
            child: const Scaffold(
              body: ConnectivityRequiredButton(
                label: 'SAVE',
                onPressed: null,
              ),
            ),
          ),
        ),
      );

      expect(find.text('SAVE'), findsOneWidget);

      // Go offline
      notifier.setOnline(false);
      await tester.pump();
      expect(find.text('Requires connection'), findsOneWidget);

      // Come back online
      notifier.setOnline(true);
      await tester.pump();
      expect(find.text('SAVE'), findsOneWidget);
    },
  );

  testWidgets(
    'no provider: degrades gracefully as online',
    (tester) async {
      // No ChangeNotifierProvider<ConnectivityNotifier> in the tree.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectivityRequiredButton(
              label: 'SUBMIT',
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.text('SUBMIT'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    },
  );
}
