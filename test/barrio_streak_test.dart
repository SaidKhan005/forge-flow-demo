// Honest streak revival tests (operator-approved rec #10, 2026-07-23):
//   * service: consecutive-day extension; up to 2 automatic free
//     passes per Monday-start week covering days off; honest reset
//     when the gap exceeds the allowance; weekly allowance reset;
//     backward-compatible storage keys;
//   * wiring: opening the training reader records activity, and so
//     does opening a flashcard review deck;
//   * chip: renders on home with the real persisted count, labels a
//     pass-covered day 'day off covered', and renders nothing at
//     count 0 (no phantom zero streak).
//
// Widget tests at a 390x844 phone viewport; home uses explicit pumps
// only (looping ambient motion). takeException() asserted null.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_streak_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_streak_doc',
  title: 'Streak Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'st_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'st_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'Streak fixture body.',
        ),
      ],
    ),
  ],
);

const _fixtureDeck = BarrioFlashcardDeck(
  id: 'fixture_streak_deck',
  title: 'Streak Fixture Deck',
  cards: [
    BarrioFlashcard(
      id: 'st_f1',
      term: 'TERM ONE',
      body: 'Definition one.',
    ),
  ],
);

/// The service's unpadded 'y-m-d' key for a date.
String _keyOf(DateTime d) => '${d.year}-${d.month}-${d.day}';

void main() {
  const phoneSize = Size(390, 844);

  // A fixed Monday anchor keeps the week arithmetic readable:
  // 2026-07-20 is a Monday.
  final mon = DateTime(2026, 7, 20);
  DateTime day(int offset) => mon.add(Duration(days: offset));

  group('BarrioStreakService (pure, injected clock)', () {
    test('first activity starts at 1 and consecutive days extend', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await BarrioStreakService.recordActivity(now: day(0)), 1);
      expect(await BarrioStreakService.recordActivity(now: day(0)), 1,
          reason: 'idempotent per day');
      expect(await BarrioStreakService.recordActivity(now: day(1)), 2);
      final info = await BarrioStreakService.getStreak(now: day(1));
      expect(info.count, 2);
      expect(info.status, StreakStatus.active);
      expect(info.dayOffCovered, isFalse);
    });

    test('a day off is covered by a free pass and flagged, never silent',
        () async {
      SharedPreferences.setMockInitialValues({});
      await BarrioStreakService.recordActivity(now: day(0)); // Mon: 1
      // Tue off; Wed opens: gap 2, one day off <= 2 passes.
      expect(await BarrioStreakService.recordActivity(now: day(2)), 2);
      final info = await BarrioStreakService.getStreak(now: day(2));
      expect(info.count, 2);
      expect(info.dayOffCovered, isTrue,
          reason: 'a pass-covered extension must be visibly labeled');

      // Thu opens normally: the covered flag clears (no stale label).
      expect(await BarrioStreakService.recordActivity(now: day(3)), 3);
      final cleared = await BarrioStreakService.getStreak(now: day(3));
      expect(cleared.dayOffCovered, isFalse);
    });

    test('more days off than the weekly allowance resets honestly',
        () async {
      SharedPreferences.setMockInitialValues({});
      await BarrioStreakService.recordActivity(now: day(0)); // Mon: 1
      // Tue+Wed+Thu off; Fri opens: 3 days off > 2 passes: reset.
      expect(await BarrioStreakService.recordActivity(now: day(4)), 1);
      final info = await BarrioStreakService.getStreak(now: day(4));
      expect(info.count, 1);
      expect(info.dayOffCovered, isFalse);
    });

    test('the two passes are per week: a third day off in the same week '
        'breaks the streak; a new week restores the allowance', () async {
      SharedPreferences.setMockInitialValues({});
      await BarrioStreakService.recordActivity(now: day(0)); // Mon: 1
      // Tue+Wed off, Thu opens: 2 days off consume BOTH passes.
      expect(await BarrioStreakService.recordActivity(now: day(3)), 2);
      // Fri opens: consecutive, fine.
      expect(await BarrioStreakService.recordActivity(now: day(4)), 3);
      // Sat off, Sun opens: no passes left this week: honest reset.
      expect(await BarrioStreakService.recordActivity(now: day(6)), 1);

      // Next week: Mon opens (consecutive), Tue off, Wed opens: the
      // fresh weekly allowance covers it again.
      expect(await BarrioStreakService.recordActivity(now: day(7)), 2);
      expect(await BarrioStreakService.recordActivity(now: day(9)), 3);
      final info = await BarrioStreakService.getStreak(now: day(9));
      expect(info.dayOffCovered, isTrue);
    });

    test('status: yesterday reads atRisk; a coverable gap reads atRisk; '
        'past the allowance reads broken with count 0', () async {
      SharedPreferences.setMockInitialValues({
        BarrioStreakService.keyLastActivity: _keyOf(day(0)),
        BarrioStreakService.keyStreakCount: 4,
      });
      var info = await BarrioStreakService.getStreak(now: day(1));
      expect(info.status, StreakStatus.atRisk);
      expect(info.count, 4);

      info = await BarrioStreakService.getStreak(now: day(2));
      expect(info.status, StreakStatus.atRisk,
          reason: 'one day off is still coverable by a fresh pass');

      info = await BarrioStreakService.getStreak(now: day(5));
      expect(info.status, StreakStatus.broken);
      expect(info.count, 0, reason: 'a dead streak never shows a count');
    });

    test('backward compatible: an old install with only the original two '
        'keys extends in place', () async {
      SharedPreferences.setMockInitialValues({
        BarrioStreakService.keyLastActivity: _keyOf(day(0)),
        BarrioStreakService.keyStreakCount: 5,
      });
      expect(await BarrioStreakService.recordActivity(now: day(1)), 6,
          reason: 'the original keys keep their exact meaning');
    });
  });

  group('activity wiring', () {
    testWidgets('opening the training reader records today', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      final info = await BarrioStreakService.getStreak();
      expect(info.count, 1,
          reason: 'a manual open is the activity fact the streak counts');
      expect(info.status, StreakStatus.active);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening a flashcard review deck records today',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: BarrioFlashcardReviewScreen(
            deck: _fixtureDeck,
            shuffleSeed: 7,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final info = await BarrioStreakService.getStreak();
      expect(info.count, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('home chip', () {
    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('renders the real persisted count', (tester) async {
      final today = DateTime.now();
      SharedPreferences.setMockInitialValues({
        BarrioStreakService.keyLastActivity: _keyOf(today),
        BarrioStreakService.keyStreakCount: 3,
      });
      await pumpHome(tester);

      expect(find.byType(BarrioStreakChip), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(BarrioStreakChip), matching: find.text('3')),
        findsOneWidget,
        reason: 'the chip shows the real persisted streak count',
      );
      expect(find.text('day off covered'), findsNothing,
          reason: 'no covered-day label on a clean run');
      expect(tester.takeException(), isNull);
    });

    testWidgets('labels a pass-covered day honestly', (tester) async {
      final today = DateTime.now();
      SharedPreferences.setMockInitialValues({
        BarrioStreakService.keyLastActivity: _keyOf(today),
        BarrioStreakService.keyStreakCount: 4,
        BarrioStreakService.keyCoveredOn: _keyOf(today),
      });
      await pumpHome(tester);

      expect(find.text('day off covered'), findsOneWidget,
          reason: 'a streak surviving on a pass must say so');
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders nothing at count 0 (no phantom zero streak)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpHome(tester);

      expect(find.byType(BarrioStreakChip), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
