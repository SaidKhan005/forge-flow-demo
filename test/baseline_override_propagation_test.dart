// Phase 5.2 â€” Baseline override propagation tests.
//
// Verifies that after a manager override is committed:
//   A. the override-active banner appears on BaselineTracker via the
//      ValueListenableBuilder + KeyedSubtree rebuild path used in main.dart
//   B. the Baseline tab's visible derived target reflects the new selection
//   C. the Shift-facing surface (ZoneStatusCard) also reflects the new target
//
// All tests drive BaselineData directly (applyManagerOverride / clearManagerOverride)
// to isolate the propagation mechanism from the DB/async loading path.
// Screen-level Done/Cancel tests live in baseline_manager_screen_test.dart.
//
// Trusted surfaces for this test suite:
//   - BaselineTracker (reads BaselineData statically at build time)
//   - ZoneStatusCard  (reads BaselineData statically at build time)
// Mixed surfaces (not used here as pass/fail evidence):
//   - Shift full-screen Scaffold (demo-owned ShiftSnapshot inputs)
//   - Variance, Learn

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/benchmark_tracker_read_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/widgets/zone_status_card.dart';

// â”€â”€ Override fixture â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
//
// Two selected records whose avg CPLH (5.1) and OPZ floor/ceiling (4.8 / 5.4)
// are all distinct from each other and deliberately different from the seed
// derivedTargetCPLH (â‰ˆ 4.58 â†’ '4.6').

const _overrideRecords = [
  DaypartBaseline(
    daypart: 'lunch',
    cplh: 4.8,
    splh: 180.0,
    ppa: 42.0,
    covers: 150,
    isSelected: true,
  ),
  DaypartBaseline(
    daypart: 'dinner',
    cplh: 5.4,
    splh: 195.0,
    ppa: 44.0,
    covers: 200,
    isSelected: true,
  ),
];

// avgCPLH = (4.8 + 5.4) / 2 = 5.1 â†’ toStringAsFixed(2) = ‘5.10’ (Baseline 2dp)
// ZoneStatusCard still uses 1dp: ‘5.1’, floor ‘4.8’, ceiling ‘5.4’

// â”€â”€ Test shell â€” mirrors the ValueListenableBuilder + KeyedSubtree path â”€â”€â”€â”€â”€â”€â”€

Widget _baselineRevisionShell() => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: BaselineData.revision,
          builder: (ctx, revision, _) => KeyedSubtree(
            key: ValueKey('baseline-$revision'),
            child: const BaselineTracker(),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    BenchmarkTrackerReadService.enableBridgeOnly();
    BaselineData.clearManagerOverride();
  });

  tearDown(() {
    BenchmarkTrackerReadService.disableBridgeOnly();
    BaselineData.clearManagerOverride();
  });

  // â”€â”€ A: override banner appears via ValueListenableBuilder rebuild â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” override-active banner propagates through revision listener', () {
    testWidgets(
        'banner absent before override, present after revision increments',
        (tester) async {
      // Pump the revision-aware shell â€” no override active
      await tester.pumpWidget(_baselineRevisionShell());
      await tester.pump();

      expect(find.text('MANAGER OVERRIDE ACTIVE'), findsNothing);

      // Apply override â€” increments BaselineData.revision synchronously
      BaselineData.applyManagerOverride(_overrideRecords);

      // pump() processes the ValueListenableBuilder callback:
      // revision changes â†’ new key â†’ KeyedSubtree remounts BaselineTracker
      await tester.pump();

      expect(find.text('MANAGER OVERRIDE ACTIVE'), findsOneWidget);
      expect(find.text('2 STAR SHIFTS SELECTED'), findsOneWidget);
    });

    testWidgets('banner disappears after override is cleared', (tester) async {
      BaselineData.applyManagerOverride(_overrideRecords);

      await tester.pumpWidget(_baselineRevisionShell());
      await tester.pump();
      expect(find.text('MANAGER OVERRIDE ACTIVE'), findsOneWidget);

      // Clear the override â€” increments revision again
      BaselineData.clearManagerOverride();
      await tester.pump();

      expect(find.text('MANAGER OVERRIDE ACTIVE'), findsNothing);
    });
  });

  // â”€â”€ B: baseline visible target reflects override â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” baseline derived target reflects override selection', () {
    testWidgets('BaselineTracker shows override CPLH after rebuild',
        (tester) async {
      // Capture seed target text before override (2dp — 7.55h)
      final seedTargetText =
          BaselineData.derivedTargetCPLH.toStringAsFixed(2);

      // Verify override target is distinct from seed
      BaselineData.applyManagerOverride(_overrideRecords);
      final overrideTargetText =
          BaselineData.derivedTargetCPLH.toStringAsFixed(2); // '5.10'
      BaselineData.clearManagerOverride();

      expect(overrideTargetText, isNot(equals(seedTargetText)),
          reason: 'Override CPLH must differ from seed to be a meaningful test');

      // Pump baseline tab with no override â€” override target not visible
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: BaselineTracker())));
      await tester.pump();
      expect(find.text(overrideTargetText), findsNothing);

      // Apply override and repump â€” fresh build reads updated BaselineData
      BaselineData.applyManagerOverride(_overrideRecords);
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: BaselineTracker())));
      await tester.pump();

      // Override target must now appear in the Baseline targets card
      expect(find.text(overrideTargetText), findsWidgets);
    });
  });

  // â”€â”€ C: shift-facing surface reflects same active target â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //
  // ZoneStatusCard is the trusted Shift-surface for this test.
  // It renders 'Target X.X' from BaselineData.derivedTargetCPLH.
  // The full ShiftDashboard is a mixed surface (uses demo ShiftSnapshot inputs)
  // and is not used as pass/fail evidence here.

  group('C â€” shift surface reflects override target after rebuild', () {
    testWidgets('ZoneStatusCard shows override derivedTargetCPLH',
        (tester) async {
      BaselineData.applyManagerOverride(_overrideRecords);

      final expectedValue =
          BaselineData.derivedTargetCPLH.toStringAsFixed(2);

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ZoneStatusCard(
            currentCPLH: ShiftSnapshot.actualCPLH,
            opzFloorCPLH: BaselineData.opzFloorCPLH,
            opzCeilingCPLH: BaselineData.opzCeilingCPLH,
            targetCPLH: BaselineData.derivedTargetCPLH,
            opzStatus: BaselineData.opzStatusForCplh(ShiftSnapshot.actualCPLH),
            opzLabel: BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH),
            opzSubLabel: BaselineData.opzSubLabelForCplh(ShiftSnapshot.actualCPLH),
          ))));
      await tester.pump();

      // Target value rendered separately after Prompt 7.12 visual pass
      expect(find.text(expectedValue), findsAtLeastNWidgets(1));
    });

    testWidgets('ZoneStatusCard does not show stale seed target after override',
        (tester) async {
      // Capture the seed target value before any override
      final seedTargetValue =
          BaselineData.derivedTargetCPLH.toStringAsFixed(2);

      BaselineData.applyManagerOverride(_overrideRecords);

      final overrideTargetValue =
          BaselineData.derivedTargetCPLH.toStringAsFixed(2);

      // Verify values differ (test is only meaningful when they do)
      expect(overrideTargetValue, isNot(equals(seedTargetValue)));

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ZoneStatusCard(
            currentCPLH: ShiftSnapshot.actualCPLH,
            opzFloorCPLH: BaselineData.opzFloorCPLH,
            opzCeilingCPLH: BaselineData.opzCeilingCPLH,
            targetCPLH: BaselineData.derivedTargetCPLH,
            opzStatus: BaselineData.opzStatusForCplh(ShiftSnapshot.actualCPLH),
            opzLabel: BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH),
            opzSubLabel: BaselineData.opzSubLabelForCplh(ShiftSnapshot.actualCPLH),
          ))));
      await tester.pump();

      expect(find.text(overrideTargetValue), findsAtLeastNWidgets(1));
      expect(find.text(seedTargetValue), findsNothing);
    });
  });
}
