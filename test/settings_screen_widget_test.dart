// Settings screen data status widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';

void main() {
  group('Settings DATA STATUS section', () {
    testWidgets('shows CURRENT when status is current', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(
            importStatus: 'completed',
            timestamp: '2026-03-30T10:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('DATA STATUS'), findsOneWidget);
      expect(find.text('CURRENT'), findsOneWidget);
    });

    testWidgets('shows IMPORT FAILED when status is failedImport',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.failedImport(
            errorSummary: 'Connection timeout',
            timestamp: '2026-03-30T09:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('IMPORT FAILED'), findsOneWidget);
    });

    testWidgets('shows NO DATA when status is noData', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SettingsScreen(initialStatus: AppDataStatus.noData),
      ));
      await tester.pump();

      expect(find.text('NO DATA'), findsOneWidget);
    });

    testWidgets('shows HISTORICAL ONLY when status is historicalOnly',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SettingsScreen(initialStatus: AppDataStatus.historicalOnly),
      ));
      await tester.pump();

      expect(find.text('HISTORICAL ONLY'), findsOneWidget);
    });

    testWidgets('shows STALE when status is stale', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.stale(
            timestamp: '2026-03-28T10:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('STALE'), findsOneWidget);
    });

    testWidgets('Clear All Data description text is correct', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
        ),
      ));
      await tester.pump();

      expect(
        find.textContaining('Remove all operational data'),
        findsOneWidget,
      );
    });
  });
}
