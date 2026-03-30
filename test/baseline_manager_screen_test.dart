// Phase 5.1 — BaselineManagerScreen widget tests.
//
// Uses BaselineManagerScreen.withCandidates() to inject pre-built candidate
// lists directly, bypassing the async DB load. This avoids the runAsync /
// google_fonts HTTP incompatibility and keeps tests deterministic.
// Navigation tests (Cancel / Done) verify the DB commit path via tester.runAsync
// because sqflite isolate responses don't complete inside Flutter's fakeAsync.
// pump() is NOT called after CANCEL/DONE taps to avoid Navigator animation loops.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/baseline_manager_service.dart';
import 'package:forge_flow_demo/data/database_helper.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/models/baseline_candidate_shift.dart';
import 'package:forge_flow_demo/screens/baseline_manager_screen.dart';

// ── Shared test fixtures ──────────────────────────────────────────────────────

const _lunch1 = BaselineCandidateShift(
  recordKey: '2026-W10|Mon|lunch',
  weekId: '2026-W10',
  weekLabel: 'Week of Mar 3',
  dayLabel: 'Mon',
  daypart: 'lunch',
  covers: 155,
  cplh: 4.80,
  splh: 185.0,
  ppa: 42.5,
  primaryLeverId: 'cplh_up',
  isSelected: false,
);

const _lunch2 = BaselineCandidateShift(
  recordKey: '2026-W11|Tue|lunch',
  weekId: '2026-W11',
  weekLabel: 'Week of Mar 10',
  dayLabel: 'Tue',
  daypart: 'lunch',
  covers: 148,
  cplh: 4.60,
  splh: 182.0,
  ppa: 41.8,
  primaryLeverId: 'cplh_up',
  isSelected: false,
);

const _dinner1 = BaselineCandidateShift(
  recordKey: '2026-W10|Fri|dinner',
  weekId: '2026-W10',
  weekLabel: 'Week of Mar 3',
  dayLabel: 'Fri',
  daypart: 'dinner',
  covers: 210,
  cplh: 4.70,
  splh: 190.0,
  ppa: 43.0,
  primaryLeverId: 'cplh_up',
  isSelected: false,
);

const _selectedLunch = BaselineCandidateShift(
  recordKey: '2026-W12|Mon|lunch',
  weekId: '2026-W12',
  weekLabel: 'Week of Mar 17',
  dayLabel: 'Mon',
  daypart: 'lunch',
  covers: 162,
  cplh: 4.90,
  splh: 188.0,
  ppa: 43.2,
  primaryLeverId: 'cplh_up',
  isSelected: true,
);

const _allCandidates = [_lunch1, _lunch2, _dinner1];
const _withPreSelected = [_selectedLunch, _lunch1, _dinner1];

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: child,
    );

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
  });

  // ── Loading indicator (kept from prior suite) ─────────────────────────────

  testWidgets('shows loading indicator when no initialCandidates provided',
      (tester) async {
    await tester.pumpWidget(_wrap(const BaselineManagerScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  // ── A: manager page renders required labels ───────────────────────────────

  group('A — required labels present', () {
    testWidgets('page title, buttons, and all six preview labels render',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      expect(find.text('Choose Star Shifts'), findsOneWidget);
      expect(find.text('CANCEL'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('SELECTED SHIFTS'), findsOneWidget);
      expect(find.text('TARGET CPLH'), findsOneWidget);
      expect(find.text('TARGET SPLH'), findsOneWidget);
      expect(find.text('TARGET PPA'), findsOneWidget);
      expect(find.text('OPZ FLOOR'), findsOneWidget);
      expect(find.text('OPZ CEILING'), findsOneWidget);
    });
  });

  // ── B: zero-selection preview shows empty state ───────────────────────────

  group('B — zero-selection preview', () {
    testWidgets('SELECTED SHIFTS shows 0 when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // Count cell shows the integer '0'
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('five metric cells show -- when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // TARGET CPLH, TARGET SPLH, TARGET PPA, OPZ FLOOR, OPZ CEILING
      expect(find.text('--'), findsNWidgets(5));
    });
  });

  // ── C: selecting a candidate updates live preview ─────────────────────────

  group('C — live preview updates on selection', () {
    testWidgets('selecting one candidate clears all -- from preview',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // Precondition: five dashes showing
      expect(find.text('--'), findsNWidgets(5));

      // Tap first tile (→ _lunch1, cplh 4.80)
      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // No -- remaining in preview
      expect(find.text('--'), findsNothing);
    });

    testWidgets('count increments to 1 after first selection', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('deselecting returns preview to all --', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      final boxes = find.byType(AnimatedContainer);
      // Select
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('--'), findsNothing);

      // Deselect
      final boxes2 = find.byType(AnimatedContainer);
      await tester.tap(boxes2.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('--'), findsNWidgets(5));
    });
  });

  // ── D: candidate tiles and section headers ────────────────────────────────

  group('D — candidate tiles show required fields', () {
    testWidgets('LUNCH section header renders', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();
      expect(find.text('LUNCH'), findsOneWidget);
    });

    testWidgets('DINNER section header renders', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();
      expect(find.text('DINNER'), findsOneWidget);
    });

    testWidgets('each tile shows CPLH, COVERS, SPLH, PPA, and lever',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // Three candidates → three chips of each label
      expect(find.text('CPLH '), findsNWidgets(3));
      expect(find.text('COVERS '), findsNWidgets(3));
      expect(find.text('SPLH '), findsNWidgets(3));
      expect(find.text('PPA '), findsNWidgets(3));
      expect(find.text('LEVER '), findsNWidgets(3));

      // primaryLeverId value from fixture appears at least once
      expect(find.text('cplh_up'), findsWidgets);
    });
  });

  // ── E: Cancel discards draft ──────────────────────────────────────────────

  group('E — Cancel discards draft', () {
    testWidgets('Cancel does not write selection to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // Select a candidate so there is a draft selection
      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1'), findsOneWidget);

      // Tap Cancel — must NOT commit (no pump after to avoid nav loop)
      await tester.tap(find.text('CANCEL'));

      // DB must still be empty
      final stored = await tester.runAsync(() async {
        return await DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, isEmpty);
    });
  });

  // ── F: Done with non-empty draft commits ──────────────────────────────────

  group('F — Done with non-empty draft commits selection', () {
    testWidgets('Done writes selected record key to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      // Select first candidate (_lunch1)
      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1'), findsOneWidget);

      // Tap Done and wait for sqflite write to complete
      await tester.tap(find.text('DONE'));
      final stored = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return await DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, contains(_lunch1.recordKey));
    });
  });

  // ── G: Done with empty draft clears override ──────────────────────────────

  group('G — Done with empty draft clears override', () {
    testWidgets('deselect all then Done empties DB and clears override',
        (tester) async {
      // Precondition: a selection exists in DB and override is active
      await tester.runAsync(() async {
        await DatabaseHelper.instance
            .replaceBaselineSelectedRecordKeys({_selectedLunch.recordKey});
      });
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
          daypart: 'lunch',
          cplh: 4.90,
          splh: 188.0,
          ppa: 43.2,
          covers: 162,
        ),
      ]);
      expect(BaselineData.hasManagerOverride, isTrue);

      // Open screen with _selectedLunch pre-selected (isSelected: true)
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected),
      ));
      await tester.pump();

      // Deselect the pre-selected candidate (first AnimatedContainer = _selectedLunch)
      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Draft is now empty
      expect(find.text('0'), findsOneWidget);

      // Tap Done — empty draft must call saveSelection({}) → clearManagerOverride
      await tester.tap(find.text('DONE'));
      final stored = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return await DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });

      expect(stored!, isEmpty);
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });
}
