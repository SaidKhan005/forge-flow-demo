// Widget tests for the spaced Quick refresher shelf (operator-approved
// rec #11), all at a 390x844 phone viewport.
//
// Home surface: no card on fresh state (no phantom card), the card
// appears with the honest operator-approved copy when a manual is
// refresh-due, tap opens the quiz refresher for a banked manual and
// the shuffled flashcard deck for a glossary, completing a refresher
// records lastRefreshedAt and removes the card, and a B18-hidden
// manual is never listed (schedule preserved in storage).
//
// Finish tracking: reading every content card of a manual records a
// write-once finishedAt.
//
// The home screen and shelf run looping ambient motion: NEVER
// pumpAndSettle in those tests; pump explicit durations only. Every
// test asserts takeException() is null (overflow guard).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_quiz_refresher_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// B18 resolver that denies everything: proves the resolver wins over
/// the admin preview-role fallback for the refresher card, exactly
/// like the bubbles, Continue Reading, and the review pills.
class _DenyAllResolver implements BarrioDestinationVisibilityResolver {
  const _DenyAllResolver();

  @override
  bool isVisible(BarrioDestination destination) => false;
}

/// Small fixture manual for finish tracking: one section, two cards.
const _kFixtureDocId = 'fixture_refresher_doc';
const _fixtureDoc = BarrioTrainingDoc(
  id: _kFixtureDocId,
  title: 'Refresher Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'rfx_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'rfx_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'First fixture card body.',
        ),
        HandbookUnit(
          id: 'rfx_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second fixture card body.',
        ),
      ],
    ),
  ],
);

void main() {
  const phoneSize = Size(390, 844);
  final refresherCard = find.byKey(const Key('barrio_refresher_card'));
  final advanceButton = find.byKey(const Key('barrio_refresher_advance'));

  int millisAgo(Duration ago) =>
      DateTime.now().subtract(ago).millisecondsSinceEpoch;

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpHome(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
    // One-shot entrance (900ms) + wordmark (700ms); the refresher
    // state load resolves inside these pumps too.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> pumpShelf(
    WidgetTester tester, {
    List<String> due = const <String>[],
    BarrioDestinationVisibilityResolver? resolver,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BarrioHomeShelf(
            destinations:
                barrioDestinations.where((d) => d.showOnHomeHub).toList(),
            visibilityResolver: resolver,
            refresherDueDocIds: due,
            onDestinationTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
  }

  group('Quick refresher card on the home shelf', () {
    testWidgets('fresh state shows no card at all (no phantom card)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpHome(tester);

      expect(refresherCard, findsNothing);
      expect(find.text('QUICK REFRESHER'), findsNothing,
          reason: 'no finishedAt = never due, so a fresh install must '
              'never be told to refresh');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a due banked manual shows the honest quiz copy',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor('training_food_safety'):
            millisAgo(const Duration(days: 4)),
      });
      await pumpHome(tester);

      final n = kBarrioQuizBanks['training_food_safety']!.questions.length;
      expect(refresherCard, findsOneWidget);
      expect(find.text('QUICK REFRESHER'), findsOneWidget);
      expect(find.text('Refresh Food Safety'), findsOneWidget);
      expect(find.text('$n quick questions'), findsOneWidget,
          reason: 'the question count is a real bank fact');
      expect(find.textContaining('more due'), findsNothing,
          reason: 'one due manual gets no phantom "more due" line');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap opens the quiz refresher (checkpoint cards in '
        'sequence) for a banked manual', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor('training_food_safety'):
            millisAgo(const Duration(days: 4)),
      });
      await pumpHome(tester);

      await tester.tap(refresherCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final n = kBarrioQuizBanks['training_food_safety']!.questions.length;
      expect(find.byType(BarrioQuizRefresherScreen), findsOneWidget);
      expect(find.text('Question 1 of $n'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tap opens the shuffled flashcard deck for a glossary '
        'manual', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor(
            'training_latin_ingredients'): millisAgo(const Duration(days: 4)),
      });
      await pumpHome(tester);

      expect(find.text('Refresh Latin Ingredients'), findsOneWidget);
      expect(find.text('flashcard round'), findsOneWidget);

      await tester.tap(refresherCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(BarrioFlashcardReviewScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('completing the quiz refresher records lastRefreshedAt '
        'and the card disappears', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor('training_coffee'):
            millisAgo(const Duration(days: 4)),
      });
      await pumpHome(tester);

      expect(find.text('Refresh Coffee'), findsOneWidget);
      await tester.tap(refresherCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(BarrioQuizRefresherScreen), findsOneWidget);

      // Answer the first question, then move through the whole run
      // (no gating: unanswered questions can be passed, same as the
      // in-reader checkpoint cards).
      final bank = kBarrioQuizBanks['training_coffee']!;
      final firstQuestion = bank.questions.first;
      await tester.tap(
        find.byKey(ValueKey<String>('quiz_option_${firstQuestion.id}_0')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < bank.questions.length; i++) {
        await tester.tap(advanceButton);
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Honest end state: no mastery claim, real counts only.
      expect(find.text('Refresher done.'), findsOneWidget);
      expect(
        find.textContaining('You answered 1 of ${bank.questions.length}.'),
        findsOneWidget,
      );

      // Completion recorded exactly one refresher.
      final state = await BarrioReadingProgressService.getRefresherState(
          'training_coffee');
      expect(state.lastRefreshedAt, isNotNull);
      expect(state.completedRefreshers, 1);

      // Exit: back on home the card is gone (next due is 10 days out).
      await tester.tap(find.byKey(const Key('barrio_refresher_exit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BarrioHomeScreen), findsOneWidget);
      expect(refresherCard, findsNothing,
          reason: 'a completed refresher must clear the card until the '
              'next spacing interval');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('multiple due manuals: longest overdue leads plus an '
        'honest "and 1 more due"', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor('training_food_safety'):
            millisAgo(const Duration(days: 10)),
        BarrioReadingProgressService.finishedKeyFor('training_coffee'):
            millisAgo(const Duration(days: 4)),
      });
      await pumpHome(tester);

      expect(refresherCard, findsOneWidget,
          reason: 'exactly one quiet card, never a stack');
      expect(find.text('Refresh Food Safety'), findsOneWidget,
          reason: 'the longest-overdue manual leads');
      expect(find.text('Refresh Coffee'), findsNothing);
      expect(find.text('and 1 more due'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a B18-hidden manual is never listed even when due; the '
        'stored schedule is untouched', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.finishedKeyFor('training_food_safety'):
            millisAgo(const Duration(days: 4)),
      });

      // Sanity: without a resolver the admin preview tier shows it.
      await pumpShelf(tester, due: const ['training_food_safety']);
      expect(refresherCard, findsOneWidget);

      await pumpShelf(
        tester,
        due: const ['training_food_safety'],
        resolver: const _DenyAllResolver(),
      );
      expect(refresherCard, findsNothing,
          reason: 'a hidden manual never appears as a refresher');

      final state = await BarrioReadingProgressService.getRefresherState(
          'training_food_safety');
      expect(state.finishedAt, isNotNull,
          reason: 'hiding is display-only; the schedule stays recorded');
      expect(tester.takeException(), isNull);
    });
  });

  group('finish tracking in the training reader', () {
    testWidgets('reading every content card records a write-once '
        'finishedAt', (tester) async {
      SharedPreferences.setMockInitialValues({});
      usePhoneViewport(tester);
      await tester.pumpWidget(
        const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      // Landing card read only: not finished yet.
      var state = await BarrioReadingProgressService.getRefresherState(
          _kFixtureDocId);
      expect(state.finishedAt, isNull,
          reason: 'a partially read manual is never marked finished');

      // Reading the second (last) card covers the whole manual.
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      state = await BarrioReadingProgressService.getRefresherState(
          _kFixtureDocId);
      expect(state.finishedAt, isNotNull,
          reason: 'full coverage records the finish fact');
      final firstFinishedAt = state.finishedAt;

      // Re-reading (swipe back) must never reset the recorded finish.
      await tester.drag(find.byType(PageView), const Offset(400, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      state = await BarrioReadingProgressService.getRefresherState(
          _kFixtureDocId);
      expect(state.finishedAt, firstFinishedAt,
          reason: 'finishedAt is write-once');
      expect(tester.takeException(), isNull);
    });
  });
}
