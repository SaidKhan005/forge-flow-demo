import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/database_helper.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';

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

Future<Set<String>> _commitDoneAndReadKeys(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    await tester.tap(find.text('DONE'));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
  }))!;
}

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
  });

  testWidgets('shows loading indicator when no initialCandidates provided',
      (tester) async {
    await tester.pumpWidget(_wrap(const BaselineManagerScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('A - required labels present', () {
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

  group('B - zero-selection preview', () {
    testWidgets('SELECTED SHIFTS shows 0 when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('five metric cells show -- when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();
      expect(find.text('--'), findsNWidgets(5));
    });
  });

  group('C - live preview updates on selection', () {
    testWidgets('selecting one candidate clears all -- from preview',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      expect(find.text('--'), findsNWidgets(5));

      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

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
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('--'), findsNothing);

      final boxes2 = find.byType(AnimatedContainer);
      await tester.tap(boxes2.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('--'), findsNWidgets(5));
    });
  });

  group('D - candidate tiles show required fields', () {
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

      expect(find.text('CPLH '), findsNWidgets(3));
      expect(find.text('COVERS '), findsNWidgets(3));
      expect(find.text('SPLH '), findsNWidgets(3));
      expect(find.text('PPA '), findsNWidgets(3));
      expect(find.text('LEVER '), findsNWidgets(3));
      expect(find.text('cplh_up'), findsWidgets);
    });
  });

  group('E - Cancel discards draft', () {
    testWidgets('Cancel does not write selection to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.text('CANCEL'));
      await tester.pump();

      final stored = await tester.runAsync(() async {
        return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, isEmpty);
    });
  });

  group('F - Done with non-empty draft commits selection', () {
    testWidgets('Done writes selected record key to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates),
      ));
      await tester.pump();

      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1'), findsOneWidget);

      final stored = await _commitDoneAndReadKeys(tester);
      expect(stored, contains(_lunch1.recordKey));
    });
  });

  group('G - Done with empty draft clears override', () {
    testWidgets('deselect all then Done empties DB and clears override',
        (tester) async {
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

      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected),
      ));
      await tester.pump();

      final boxes = find.byType(AnimatedContainer);
      await tester.tap(boxes.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('0'), findsOneWidget);

      final stored = await _commitDoneAndReadKeys(tester);

      expect(stored, isEmpty);
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });
}
