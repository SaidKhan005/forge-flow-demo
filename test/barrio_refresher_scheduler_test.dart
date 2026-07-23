// Unit tests for the spaced Quick refresher slice (operator-approved
// rec #11): the pure BarrioRefresherScheduler (injected clock, no
// waiting, no I/O) and the additive finish/refresh persistence on
// BarrioReadingProgressService (exercised through
// SharedPreferences.setMockInitialValues).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_refresher_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A fixed reference instant; every scenario derives from it, so no
  /// test ever waits on a real clock.
  final t0 = DateTime(2026, 7, 1, 12);

  group('BarrioRefresherScheduler: never-finished manuals', () {
    test('no finishedAt = never due, at any clock reading', () {
      const state = BarrioRefresherState.empty;
      expect(BarrioRefresherScheduler.nextDueAt(state), isNull);
      expect(BarrioRefresherScheduler.isDue(state, t0), isFalse);
      expect(
        BarrioRefresherScheduler.isDue(
          state,
          t0.add(const Duration(days: 3650)),
        ),
        isFalse,
        reason: 'a fresh install must never be told to refresh',
      );
      expect(BarrioRefresherScheduler.overdueBy(state, t0), isNull);
    });
  });

  group('BarrioRefresherScheduler: the 3/10/30 day progression', () {
    test('finished, no refresher yet: due exactly at finishedAt + 3 days',
        () {
      final state = BarrioRefresherState(finishedAt: t0);
      final due = t0.add(const Duration(days: 3));
      expect(BarrioRefresherScheduler.nextDueAt(state), due);
      expect(
        BarrioRefresherScheduler.isDue(
          state,
          due.subtract(const Duration(minutes: 1)),
        ),
        isFalse,
        reason: 'one minute early is not due',
      );
      expect(BarrioRefresherScheduler.isDue(state, due), isTrue,
          reason: 'the due instant itself counts');
      expect(
        BarrioRefresherScheduler.overdueBy(
          state,
          due.add(const Duration(hours: 5)),
        ),
        const Duration(hours: 5),
      );
    });

    test('one completed refresher pushes the next due to '
        'lastRefreshedAt + 10 days', () {
      final refreshed = t0.add(const Duration(days: 4));
      final state = BarrioRefresherState(
        finishedAt: t0,
        lastRefreshedAt: refreshed,
        completedRefreshers: 1,
      );
      final due = refreshed.add(const Duration(days: 10));
      expect(BarrioRefresherScheduler.nextDueAt(state), due);
      expect(
        BarrioRefresherScheduler.isDue(
          state,
          due.subtract(const Duration(days: 1)),
        ),
        isFalse,
      );
      expect(BarrioRefresherScheduler.isDue(state, due), isTrue);
    });

    test('two completed refreshers push the next due to '
        'lastRefreshedAt + 30 days', () {
      final refreshed = t0.add(const Duration(days: 20));
      final state = BarrioRefresherState(
        finishedAt: t0,
        lastRefreshedAt: refreshed,
        completedRefreshers: 2,
      );
      expect(
        BarrioRefresherScheduler.nextDueAt(state),
        refreshed.add(const Duration(days: 30)),
      );
    });

    test('later refreshers keep rolling every 30 days', () {
      final refreshed = t0.add(const Duration(days: 200));
      final state = BarrioRefresherState(
        finishedAt: t0,
        lastRefreshedAt: refreshed,
        completedRefreshers: 7,
      );
      expect(
        BarrioRefresherScheduler.nextDueAt(state),
        refreshed.add(const Duration(days: 30)),
      );
    });

    test('a recorded lastRefreshedAt with a corrupt zero count is trusted '
        'as one completed refresher (10 day gap, not 3)', () {
      final refreshed = t0.add(const Duration(days: 4));
      final state = BarrioRefresherState(
        finishedAt: t0,
        lastRefreshedAt: refreshed,
        completedRefreshers: 0,
      );
      expect(
        BarrioRefresherScheduler.nextDueAt(state),
        refreshed.add(const Duration(days: 10)),
        reason: 'the timestamp is the fact; the count only picks the gap',
      );
    });
  });

  group('BarrioRefresherScheduler: dueDocIds ordering and qualification',
      () {
    test('due manuals come back longest overdue first', () {
      final now = t0.add(const Duration(days: 40));
      final states = <String, BarrioRefresherState>{
        // Overdue by 37 days (due at t0 + 3d).
        'training_food_safety': BarrioRefresherState(finishedAt: t0),
        // Overdue by 17 days (due at t0 + 20d + 3d).
        'training_latin_dishes': BarrioRefresherState(
          finishedAt: t0.add(const Duration(days: 20)),
        ),
        // Not due: refreshed 5 days ago, second gap is 10 days.
        'training_coffee': BarrioRefresherState(
          finishedAt: t0,
          lastRefreshedAt: now.subtract(const Duration(days: 5)),
          completedRefreshers: 1,
        ),
      };
      expect(
        BarrioRefresherScheduler.dueDocIds(states, now),
        ['training_food_safety', 'training_latin_dishes'],
      );
    });

    test('a finished manual with NO refresh material never surfaces, '
        'even long overdue', () {
      final now = t0.add(const Duration(days: 400));
      final states = <String, BarrioRefresherState>{
        // Narrative manual: no quiz bank, not a glossary deck.
        'training_three_pillars': BarrioRefresherState(finishedAt: t0),
      };
      expect(BarrioRefresherScheduler.dueDocIds(states, now), isEmpty);
    });

    test('material kinds: glossaries refresh with flashcards (even with a '
        'quiz bank), banked manuals with quizzes, others never', () {
      // Glossary + quiz bank: the flashcard deck wins.
      expect(kBarrioQuizBanks.containsKey('training_latin_dishes'), isTrue,
          reason: 'sanity: latin dishes carries both kinds of material');
      expect(
        barrioRefresherKindFor('training_latin_dishes'),
        BarrioRefresherKind.flashcards,
      );
      expect(
        barrioRefresherKindFor('training_general_words'),
        BarrioRefresherKind.flashcards,
      );
      // Quiz bank only.
      expect(
        barrioRefresherKindFor('training_food_safety'),
        BarrioRefresherKind.quiz,
      );
      expect(
        barrioRefresherKindFor('training_coffee'),
        BarrioRefresherKind.quiz,
      );
      // Neither.
      expect(barrioRefresherKindFor('training_three_pillars'), isNull);
      expect(barrioRefresherKindFor('company_handbook'), isNull);
    });
  });

  group('BarrioReadingProgressService: finish + refresh persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('fresh state reads as empty (never due)', () async {
      final state =
          await BarrioReadingProgressService.getRefresherState('doc_a');
      expect(state.finishedAt, isNull);
      expect(state.lastRefreshedAt, isNull);
      expect(state.completedRefreshers, 0);
    });

    test('recordFinished is write-once: re-reading never resets it',
        () async {
      await BarrioReadingProgressService.recordFinished('doc_a', now: t0);
      await BarrioReadingProgressService.recordFinished(
        'doc_a',
        now: t0.add(const Duration(days: 90)),
      );
      final state =
          await BarrioReadingProgressService.getRefresherState('doc_a');
      expect(state.finishedAt, t0,
          reason: 'the first finish timestamp is the fact that stays');
    });

    test('recordRefreshCompleted stamps lastRefreshedAt and advances the '
        'count', () async {
      await BarrioReadingProgressService.recordFinished('doc_a', now: t0);
      final r1 = t0.add(const Duration(days: 3));
      final r2 = t0.add(const Duration(days: 14));
      await BarrioReadingProgressService.recordRefreshCompleted(
        'doc_a',
        now: r1,
      );
      var state =
          await BarrioReadingProgressService.getRefresherState('doc_a');
      expect(state.lastRefreshedAt, r1);
      expect(state.completedRefreshers, 1);

      await BarrioReadingProgressService.recordRefreshCompleted(
        'doc_a',
        now: r2,
      );
      state = await BarrioReadingProgressService.getRefresherState('doc_a');
      expect(state.lastRefreshedAt, r2);
      expect(state.completedRefreshers, 2);
    });

    test('loadRefresherStates carries every asked doc and the whole cycle '
        'drives the scheduler end to end', () async {
      await BarrioReadingProgressService.recordFinished('doc_a', now: t0);
      final states = await BarrioReadingProgressService.loadRefresherStates(
        ['doc_a', 'doc_b'],
      );
      expect(states.keys, containsAll(['doc_a', 'doc_b']));
      expect(states['doc_b'], isNotNull);
      expect(states['doc_b']!.finishedAt, isNull);
      expect(
        BarrioRefresherScheduler.isDue(
          states['doc_a']!,
          t0.add(const Duration(days: 3)),
        ),
        isTrue,
      );
      expect(
        BarrioRefresherScheduler.isDue(
          states['doc_b']!,
          t0.add(const Duration(days: 3650)),
        ),
        isFalse,
      );
    });
  });

  group('shuffled deck sanity for glossary refreshers', () {
    test('every glossary manual resolves to a non-empty deck', () {
      for (final docId in kBarrioFlashcardManualIds) {
        final deck = barrioFlashcardDeckForManual(docId, title: docId);
        expect(deck, isNotNull, reason: '$docId must have a deck');
        expect(deck!.cards, isNotEmpty, reason: '$docId deck must be usable');
      }
    });
  });
}
