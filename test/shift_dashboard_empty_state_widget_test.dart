import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

Widget _buildEmptyState(AppDataStatus status) {
  return ChangeNotifierProvider<ShiftDashboardNotifier>(
    create: (_) => ShiftDashboardNotifier.emptyForTest(status),
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

void main() {
  group('ShiftDashboard empty state', () {
    testWidgets('renders no-data state instead of spinner', (tester) async {
      await tester.pumpWidget(_buildEmptyState(AppDataStatus.noData));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('NO DATA'), findsOneWidget);
      expect(
        find.text('No shifts or history found. Load demo data or connect a source.'),
        findsOneWidget,
      );
    });

    testWidgets('renders historical-only state instead of spinner',
        (tester) async {
      await tester.pumpWidget(_buildEmptyState(AppDataStatus.historicalOnly));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('HISTORICAL ONLY'), findsOneWidget);
      expect(
        find.text('Week history exists but no current-week open/projected state.'),
        findsOneWidget,
      );
    });

    testWidgets('renders failed-import state instead of spinner',
        (tester) async {
      final status = AppDataStatus.failedImport(
        errorSummary: 'Connection timeout',
        timestamp: '2026-03-30T09:00:00',
      );
      await tester.pumpWidget(_buildEmptyState(status));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('IMPORT FAILED'), findsOneWidget);
      expect(find.text('Connection timeout'), findsOneWidget);
      expect(find.text('Last import: 2026-03-30T09:00:00'), findsOneWidget);
    });

    testWidgets('renders stale state instead of spinner', (tester) async {
      final status = AppDataStatus.stale(
        timestamp: '2026-03-28T10:00:00',
      );
      await tester.pumpWidget(_buildEmptyState(status));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('STALE'), findsOneWidget);
      expect(
        find.text('Current-state data is older than the freshness threshold.'),
        findsOneWidget,
      );
      expect(find.text('Last import: 2026-03-28T10:00:00'), findsOneWidget);
    });
  });
}
