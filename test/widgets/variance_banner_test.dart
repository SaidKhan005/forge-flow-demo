// Widget tests for VarianceBanner.
//
// Coverage:
//   * mounts without crash when weekData is null (shows 0.0 defaults)
//   * onTap callback fires when the banner is tapped

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';
import 'package:forge_and_flow/widgets/variance_banner.dart';

/// Stub ShiftDataSource that always returns null for week-to-date data.
class _NullShiftDataSource implements ShiftDataSource {
  const _NullShiftDataSource();

  @override
  Future<WeekData?> getWeekToDate() async => null;

  @override
  Future<List<WeekRecord>> getWeekHistory() async => [];

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async => [];

  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => [];

  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => [];
}

Widget _wrap(Widget child) => ChangeNotifierProvider<WeekDataNotifier>(
      create: (_) => WeekDataNotifier(const _NullShiftDataSource()),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 120, child: child),
        ),
      ),
    );

void main() {
  group('VarianceBanner', () {
    testWidgets('mounts without crash when weekData is null', (tester) async {
      await tester.pumpWidget(_wrap(const VarianceBanner()));
      // Allow the async _load() inside WeekDataNotifier to complete.
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders 0.0% default actual value when weekData is null',
        (tester) async {
      await tester.pumpWidget(_wrap(const VarianceBanner()));
      await tester.pump();
      await tester.pump();

      // The banner renders actual as '0.0%' when weekData is null.
      expect(find.text('0.0%'), findsWidgets);
    });

    testWidgets('onTap callback fires when banner is tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(
        VarianceBanner(onTap: () => tapped = true),
      ));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('renders LABOR % VARIANCE header label', (tester) async {
      await tester.pumpWidget(_wrap(const VarianceBanner()));
      await tester.pump();
      await tester.pump();

      expect(find.text('LABOR % VARIANCE'), findsOneWidget);
    });

    testWidgets('renders VIEW DETAILS label', (tester) async {
      await tester.pumpWidget(_wrap(const VarianceBanner()));
      await tester.pump();
      await tester.pump();

      expect(find.text('VIEW DETAILS'), findsOneWidget);
    });
  });
}
