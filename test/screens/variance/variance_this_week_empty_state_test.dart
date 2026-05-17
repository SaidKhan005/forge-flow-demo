// Per-Daypart V1 / demo-seed workstream — Variance "This Week" empty-state
// copy clarity. (NOT the Variance Coaching V2 wave.)
//
// Covers the two empty-state branches the tab must distinguish when the
// shared `WeekData` is null:
//
//   (a) FIRST day of the configured business week, no prior closed shifts
//       yet -> the reassuring "new week" copy.
//   (b) Genuine no-data / empty condition -> the honest existing empty
//       copy ("No closed shifts yet.").
//
// The branch is decided by `VarianceEmptyStateResolver`, which reads the
// SAME real business-date + week-start config the app/seed already use
// (`RestaurantTimingConfig.weekStartDay`). No weekday literal is hardcoded;
// these tests prove the predicate is config-driven by exercising BOTH a
// Monday-start and a Sunday-start operator.
//
// HARD: neither copy may contain an em dash (U+2014). Asserted explicitly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/domain/services/variance_empty_state_resolver.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/screens/variance/variance_this_week_tab.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';

const int _emDash = 0x2014;

/// Returns null `WeekData` so `ThisWeekTab` renders its empty state.
class _NullWeekSource implements ShiftDataSource {
  const _NullWeekSource();

  @override
  Future<WeekData?> getWeekToDate() async => null;
  @override
  Future<List<WeekRecord>> getWeekHistory() async => const [];
  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async =>
      const [];
  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => const [];
  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => const [];
}

Future<void> _pumpEmptyState(
  WidgetTester tester,
  VarianceEmptyStateKind kind,
) async {
  const source = _NullWeekSource();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (_) => WeekDataNotifier(source),
        ),
        Provider<ShiftDataSource>.value(value: source),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ThisWeekTab(
            emptyStateClassifier: () async => kind,
          ),
        ),
      ),
    ),
  );
  // Let WeekDataNotifier resolve null + the injected classifier future.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('VarianceEmptyStateResolver — config-driven week-start predicate', () {
    test('Monday-start operator: a Monday business date is week-start', () {
      // 2026-05-18 is a Monday.
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-18',
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.weekStart,
      );
    });

    test('Monday-start operator: a non-Monday business date is no-data', () {
      // 2026-05-20 is a Wednesday.
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-20',
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.noData,
      );
    });

    test(
        'Sunday-start operator: a Sunday business date is week-start '
        '(predicate is read from config, not a Monday literal)', () {
      // 2026-05-17 is a Sunday. Same date is NOT week-start for a
      // Monday-start operator, proving the comparison tracks config.
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-17',
          weekStartDay: DateTime.sunday,
        ),
        VarianceEmptyStateKind.weekStart,
      );
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-17',
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.noData,
      );
    });

    test('unresolved business date or week-start config -> no-data', () {
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: null,
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.noData,
      );
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-18',
          weekStartDay: null,
        ),
        VarianceEmptyStateKind.noData,
      );
    });

    test('unparseable / out-of-range inputs -> no-data (honest default)', () {
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: 'not-a-date',
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.noData,
      );
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-02-30', // overflow date
          weekStartDay: DateTime.monday,
        ),
        VarianceEmptyStateKind.noData,
      );
      expect(
        VarianceEmptyStateResolver.classify(
          currentBusinessDate: '2026-05-18',
          weekStartDay: 0, // invalid weekday
        ),
        VarianceEmptyStateKind.noData,
      );
    });
  });

  group('Empty-state copy strings', () {
    test('neither copy contains an em dash (U+2014)', () {
      expect(kVarianceWeekStartEmptyCopy.codeUnits.contains(_emDash), isFalse,
          reason: 'week-start copy must not use an em dash');
      expect(kVarianceNoDataEmptyCopy.codeUnits.contains(_emDash), isFalse,
          reason: 'no-data copy must not use an em dash');
    });

    test('exact strings are stable', () {
      expect(kVarianceWeekStartEmptyCopy,
          'New week, nothing closed yet. Check back after the first shift closes.');
      expect(kVarianceNoDataEmptyCopy, 'No closed shifts yet.');
    });
  });

  group('ThisWeekTab empty state — rendered copy by branch', () {
    testWidgets(
        '(a) week-start day, no prior closed shifts -> new-week copy',
        (tester) async {
      await _pumpEmptyState(tester, VarianceEmptyStateKind.weekStart);

      expect(
        find.text(
            'New week, nothing closed yet. Check back after the first shift closes.'),
        findsOneWidget,
      );
      expect(find.text('No closed shifts yet.'), findsNothing);

      final shown = tester
          .widget<Text>(find.text(
              'New week, nothing closed yet. Check back after the first shift closes.'))
          .data!;
      expect(shown.codeUnits.contains(_emDash), isFalse);
    });

    testWidgets('(b) genuine no-data -> honest existing empty copy',
        (tester) async {
      await _pumpEmptyState(tester, VarianceEmptyStateKind.noData);

      expect(find.text('No closed shifts yet.'), findsOneWidget);
      expect(
        find.text(
            'New week, nothing closed yet. Check back after the first shift closes.'),
        findsNothing,
      );

      final shown = tester
          .widget<Text>(find.text('No closed shifts yet.'))
          .data!;
      expect(shown.codeUnits.contains(_emDash), isFalse);
    });
  });
}
