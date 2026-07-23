// Spaced "Quick refresher" scheduling (operator-approved rec #11,
// 2026-07-23). PURE LOGIC, NO I/O: every decision derives from real
// recorded timestamps passed in, and the clock is always injected, so
// tests never wait and production reads DateTime.now() exactly once at
// read time (no timers, no notifications; those stay out of scope).
//
// Evidence base: retrieval at growing intervals is the strongest known
// retention pattern. The schedule here: a manual becomes refresh-due
// 3 days after it was first fully read, then 10 days after the first
// completed refresher, then 30 days, then every 30 days.
//
// Honesty rules (Metric Honesty Doctrine):
//   * Due-ness derives ONLY from recorded facts (finishedAt /
//     lastRefreshedAt). No finishedAt = never due: a fresh install can
//     never see a refresher prompt.
//   * Completing a refresher claims nothing about mastery; it only
//     moves the next-due date.
//
// Only manuals that HAVE refresh material qualify: a quiz bank in
// [kBarrioQuizBanks] (refresher = that manual's quiz cards in
// sequence) or a TERM glossary flashcard deck (refresher = its
// shuffled flashcard deck). Everything else never becomes due.

import 'dart:math';

import '../content/quiz/barrio_quiz_models.dart';
import 'barrio_flashcard_deck.dart';

/// What a manual's refresher session is made of.
enum BarrioRefresherKind {
  /// The manual's quiz-bank questions, in sequence.
  quiz,

  /// The manual's glossary flashcard deck, shuffled per session.
  flashcards,
}

/// First gap: finishedAt + 3 days.
const Duration kBarrioFirstRefreshGap = Duration(days: 3);

/// Second gap: first lastRefreshedAt + 10 days.
const Duration kBarrioSecondRefreshGap = Duration(days: 10);

/// Steady state: lastRefreshedAt + 30 days, rolling.
const Duration kBarrioSteadyRefreshGap = Duration(days: 30);

/// The refresher material for [docId], or null when the manual has
/// none (such manuals never become refresh-due).
///
/// Glossary manuals refresh with their flashcard deck even when they
/// also carry a quiz bank (training_latin_dishes has both): the deck
/// covers every term of the manual, so a shuffled flashcard round is
/// the fuller retrieval pass for a glossary.
BarrioRefresherKind? barrioRefresherKindFor(String docId) {
  if (kBarrioFlashcardManualIds.contains(docId)) {
    return BarrioRefresherKind.flashcards;
  }
  if (kBarrioQuizBanks.containsKey(docId)) {
    return BarrioRefresherKind.quiz;
  }
  return null;
}

/// The recorded refresher facts for one manual. All fields come from
/// real persisted timestamps (BarrioReadingProgressService); nothing
/// here is ever inferred or pre-seeded.
class BarrioRefresherState {
  /// When the manual's read-mark set first covered ALL content cards.
  /// Null = never finished = never due.
  final DateTime? finishedAt;

  /// When a refresher for this manual was last completed. Null =
  /// no refresher completed yet.
  final DateTime? lastRefreshedAt;

  /// How many refreshers have been completed for this manual.
  final int completedRefreshers;

  const BarrioRefresherState({
    this.finishedAt,
    this.lastRefreshedAt,
    this.completedRefreshers = 0,
  });

  /// The honest fresh state: nothing recorded, never due.
  static const BarrioRefresherState empty = BarrioRefresherState();
}

/// Pure spaced-refresher schedule decisions. Injectable clock: every
/// query takes `now` explicitly.
class BarrioRefresherScheduler {
  BarrioRefresherScheduler._();

  /// When [state]'s manual next becomes refresh-due, or null when it
  /// never does (not finished yet: no finishedAt, no schedule).
  ///
  /// Progression: finishedAt + 3 days until the first refresher is
  /// completed; then lastRefreshedAt + 10 days; then + 30 days after
  /// every later refresher (rolling).
  static DateTime? nextDueAt(BarrioRefresherState state) {
    final finished = state.finishedAt;
    if (finished == null) return null;
    final last = state.lastRefreshedAt;
    if (last == null) return finished.add(kBarrioFirstRefreshGap);
    // A recorded lastRefreshedAt is trusted as at least one completed
    // refresher even if the count field is missing or corrupt.
    final completed = max(state.completedRefreshers, 1);
    if (completed == 1) return last.add(kBarrioSecondRefreshGap);
    return last.add(kBarrioSteadyRefreshGap);
  }

  /// Whether the manual is refresh-due at [now] (due instant counts).
  static bool isDue(BarrioRefresherState state, DateTime now) {
    final due = nextDueAt(state);
    return due != null && !now.isBefore(due);
  }

  /// How long past due the manual is at [now], or null when not due.
  static Duration? overdueBy(BarrioRefresherState state, DateTime now) {
    final due = nextDueAt(state);
    if (due == null || now.isBefore(due)) return null;
    return now.difference(due);
  }

  /// The doc ids that are refresh-due at [now], longest overdue first
  /// (ties break on doc id for determinism). Only manuals with refresh
  /// material ([barrioRefresherKindFor] non-null) are ever listed;
  /// everything else keeps its recorded schedule but never surfaces.
  static List<String> dueDocIds(
    Map<String, BarrioRefresherState> states,
    DateTime now,
  ) {
    final due = <MapEntry<String, Duration>>[];
    states.forEach((docId, state) {
      if (barrioRefresherKindFor(docId) == null) return;
      final overdue = overdueBy(state, now);
      if (overdue == null) return;
      due.add(MapEntry(docId, overdue));
    });
    due.sort((a, b) {
      final byOverdue = b.value.compareTo(a.value);
      return byOverdue != 0 ? byOverdue : a.key.compareTo(b.key);
    });
    return <String>[for (final entry in due) entry.key];
  }
}
