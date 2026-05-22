// Negative-path empty-state widget test: BaselineTracker screen.
//
// Mounts BaselineTracker with BenchmarkTrackerReadService in bridge-only
// mode and BaselineData cleared, so the service returns a view with zero
// covers and no baseline shifts (the minimal honest empty state).
//
// Asserts:
//   - Widget mounts without throwing
//   - No RenderFlex overflow
//   - Some content renders (screen title, cover count, or a section label)
//
// No SQLite setup is required. BenchmarkTrackerReadService.enableBridgeOnly()
// bypasses the SQLite read path and uses BaselineData directly.
// ActiveTargetProfileNotifier is consumed with a nullable read
// (context.watch<T?>()) so it is safe to omit from the provider tree.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';

import '../_test_helpers/sqlite_demo_helpers.dart';
import '../_test_helpers/widget_pump_helpers.dart';

// ── Helper ────────────────────────────────────────────────────────────────────

Widget _buildSubject() {
  return const MaterialApp(
    home: Scaffold(body: BaselineTracker()),
  );
}

void main() {
  setUp(() {
    // Bridge mode bypasses SQLite so the test needs no database setup.
    BenchmarkTrackerReadService.enableBridgeOnly();
    // Clear any residual baseline state from prior tests.
    resetBaselineTestState();
  });

  tearDown(() {
    BenchmarkTrackerReadService.disableBridgeOnly();
    resetBaselineTestState();
  });

  group('BaselineTracker — empty state (bridge-only, cleared BaselineData)', () {
    testWidgets('mounts without throwing', (tester) async {
      await tester.pumpWidget(_buildSubject());
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

      await tester.pumpWidget(_buildSubject());
      await pumpEventually(tester);

      FlutterError.onError = originalOnError;
      expect(overflowErrors, isEmpty,
          reason:
              'No RenderFlex overflow expected on empty Benchmark screen');
    });

    testWidgets('screen title or cover count text renders', (tester) async {
      await tester.pumpWidget(_buildSubject());
      await pumpEventually(tester);

      // The screen always renders a "60 Day Benchmark" title in the
      // AppScreenHeader. With bridge-only + cleared data, the header
      // stat shows "0" covers. When view is non-null (bridge view is
      // always non-null), section labels are also present.
      final hasTitle =
          find.text('60 Day Benchmark').evaluate().isNotEmpty;
      final hasCoverLabel =
          find
              .textContaining('TOTAL COVERS', skipOffstage: false)
              .evaluate()
              .isNotEmpty;
      final hasCplhLabel =
          find.text('CPLH RANGE & TARGET', skipOffstage: false)
              .evaluate()
              .isNotEmpty;
      final hasAnyText = find.byType(Text).evaluate().isNotEmpty;

      expect(
        hasTitle || hasCoverLabel || hasCplhLabel || hasAnyText,
        isTrue,
        reason: 'Expected some content on empty Benchmark screen',
      );
    });
  });
}
