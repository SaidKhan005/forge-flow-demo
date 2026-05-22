// Negative-path empty-state widget test: VarianceReport screen.
//
// Mounts VarianceReport with a WeekDataNotifier that has no data
// (weekData == null, isLoading == false) and asserts the screen:
//   - Mounts without throwing
//   - Does not produce a RenderFlex overflow
//   - Renders the "This Week" tab label OR a known empty-state string
//
// No SQLite setup is needed: WeekDataNotifier receives a _NullShiftDataSource
// whose getWeekToDate() resolves to null, so the notifier settles with
// weekData == null and renders the empty-state branch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/variance/variance_this_week_tab.dart'
    show kVarianceNoDataEmptyCopy;
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';

import '../_test_helpers/widget_pump_helpers.dart';

// ── Minimal stub: always returns null/empty ───────────────────────────────────

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

// ── Helper ────────────────────────────────────────────────────────────────────

Widget _buildSubject(WeekDataNotifier notifier) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<WeekDataNotifier>.value(
        value: notifier,
        child: const VarianceReport(),
      ),
    ),
  );
}

void main() {
  group('VarianceReport — empty state (weekData == null)', () {
    late WeekDataNotifier notifier;

    setUp(() {
      notifier = WeekDataNotifier(const _NullShiftDataSource());
    });

    tearDown(() {
      notifier.dispose();
    });

    testWidgets('mounts without throwing', (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      // Let the async load (null -> loaded) settle.
      await pumpEventually(tester);
      // Reaching here without an exception == pass.
    });

    testWidgets('no RenderFlex overflow error', (tester) async {
      final overflowErrors = <String>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        final msg = details.toString();
        if (msg.contains('RenderFlex overflowed')) {
          overflowErrors.add(msg);
        } else {
          originalOnError?.call(details);
        }
      };

      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);

      FlutterError.onError = originalOnError;
      expect(overflowErrors, isEmpty,
          reason: 'No RenderFlex overflow expected on empty Variance screen');
    });

    testWidgets(
        'renders "This Week" tab label or known empty-state copy',
        (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);

      final hasTabLabel = find.text('This Week').evaluate().isNotEmpty;
      // The empty-state FutureBuilder may still be resolving; also check
      // the "week start" copy in case the classifier ran quickly.
      final hasEmptyCopy =
          find.text(kVarianceNoDataEmptyCopy, skipOffstage: false)
              .evaluate()
              .isNotEmpty ||
          find
              .textContaining('nothing closed yet', skipOffstage: false)
              .evaluate()
              .isNotEmpty;

      expect(
        hasTabLabel || hasEmptyCopy,
        isTrue,
        reason:
            'Expected "This Week" tab label or empty-state copy to be rendered',
      );
    });
  });
}
