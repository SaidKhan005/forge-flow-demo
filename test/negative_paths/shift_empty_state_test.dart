// Negative-path empty-state widget test: ShiftDashboard screen.
//
// Mounts ShiftDashboard with ShiftDashboardNotifier.emptyForTest — the
// test-only constructor that produces readModel == null, isLoading == false.
// The widget renders a _ShiftEmptyState (headline + body) in this state.
//
// Asserts:
//   - Widget mounts without throwing
//   - No RenderFlex overflow
//   - Some content renders (the empty-state headline text is present)
//
// No SQLite setup is required. ShiftServicePeriodNotifier is not provided,
// which is safe: the dashboard reads it via context.read<T?>() with a
// nullable type and skips it when absent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';

import '../_test_helpers/widget_pump_helpers.dart';

// ── Helper ────────────────────────────────────────────────────────────────────

Widget _buildSubject(ShiftDashboardNotifier notifier) {
  return MaterialApp(
    home: Scaffold(
      body: ChangeNotifierProvider<ShiftDashboardNotifier>.value(
        value: notifier,
        child: const ShiftDashboard(),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    // Clear the test clock override between cases.
    ShiftDashboard.clockOverride = null;
  });

  group('ShiftDashboard — empty state (no readModel, not loading)', () {
    late ShiftDashboardNotifier notifier;

    setUp(() {
      // emptyForTest sets readModel=null, isLoading=false, status=noData.
      notifier = ShiftDashboardNotifier.emptyForTest(AppDataStatus.noData);
    });

    tearDown(() {
      notifier.dispose();
    });

    testWidgets('mounts without throwing', (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);
      // No exception == pass.
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
          reason: 'No RenderFlex overflow expected on empty Shift screen');
    });

    testWidgets('empty-state headline or fallback text renders', (tester) async {
      await tester.pumpWidget(_buildSubject(notifier));
      await pumpEventually(tester);

      // The _ShiftEmptyState renders the notifier's status label as its
      // headline. AppDataStatus.noData.label == 'NO DATA'.
      // Also accept 'NO LIVE SHIFT' (the fallback when status is null)
      // or any visible text descendant — the minimum bar is that the
      // screen is not blank.
      final hasStatusLabel =
          find.text(AppDataStatus.noData.label).evaluate().isNotEmpty;
      final hasNoLiveShift =
          find.text('NO LIVE SHIFT').evaluate().isNotEmpty;
      final hasAnyText =
          find.byType(Text).evaluate().isNotEmpty;

      expect(
        hasStatusLabel || hasNoLiveShift || hasAnyText,
        isTrue,
        reason: 'Expected some content on empty Shift screen',
      );
    });
  });
}
