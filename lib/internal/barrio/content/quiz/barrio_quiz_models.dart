// Chapter-end quiz question bank for Barrio training manuals.
//
// DATA ONLY. This file defines the immutable model for a chapter-end
// recall quiz and the registry that maps a training-doc id to its bank.
// The per-manual question data lives in the sibling const files
// (`barrio_quiz_food_safety.dart`, `barrio_quiz_coffee.dart`,
// `barrio_quiz_latin_dishes.dart`).
//
// Authoring contract (binding, enforced by test/barrio_quiz_bank_test.dart):
//   * Every question is answerable SOLELY from the verbatim text of ONE
//     training card. [BarrioQuizQuestion.sourceUnitId] is the real unit id
//     of that card in [BarrioTrainingDoc] (see barrio_training_doc.dart).
//   * Prompts are plain-English recall questions a floor staffer benefits
//     from, never trivia about phrasing.
//   * 3 to 4 options, exactly one correct per the source text; distractors
//     are plausible but clearly wrong per the text. No "all of the above".
//   * [whyLine] states the fact in one plain sentence traceable to the
//     source card. No em dashes anywhere (UX no-em-dash law).
//
// OPERATOR REVIEW: these questions are NEW operator-facing training
// content and are drafts until the operator reads them. A later UI slice
// renders them; it must not ship them unreviewed.

import 'barrio_quiz_coffee.dart';
import 'barrio_quiz_food_safety.dart';
import 'barrio_quiz_latin_dishes.dart';

/// A single chapter-end recall question drawn from one training card.
class BarrioQuizQuestion {
  /// Stable unique id for this question (doc-scoped).
  final String id;

  /// The training-doc id this question belongs to (registry key,
  /// e.g. 'training_food_safety'). Matches [BarrioTrainingDoc.id].
  final String docId;

  /// The chapter id this question belongs to. Matches the
  /// [HandbookChapter.id] of the chapter that contains [sourceUnitId].
  final String chapterId;

  /// Plain-English recall prompt.
  final String prompt;

  /// 3 to 4 answer options. Exactly one is correct per the source card.
  final List<String> options;

  /// 0-based index into [options] of the correct answer.
  final int correctIndex;

  /// One plain sentence stating the fact, traceable to the source card.
  final String whyLine;

  /// The real [HandbookUnit.id] of the single card that supports this
  /// question. The correct option's key facts come from this card's text.
  final String sourceUnitId;

  const BarrioQuizQuestion({
    required this.id,
    required this.docId,
    required this.chapterId,
    required this.prompt,
    required this.options,
    required this.correctIndex,
    required this.whyLine,
    required this.sourceUnitId,
  });

  /// The correct option text.
  String get correctOption => options[correctIndex];
}

/// A per-doc quiz bank: all questions for one training manual.
class BarrioQuizBank {
  /// The training-doc id this bank covers (registry key).
  final String docId;

  /// All questions for the doc, in chapter reading order.
  final List<BarrioQuizQuestion> questions;

  const BarrioQuizBank({
    required this.docId,
    required this.questions,
  });

  /// Questions grouped by their [BarrioQuizQuestion.chapterId], preserving
  /// insertion order within each chapter. Computed (not const).
  Map<String, List<BarrioQuizQuestion>> get questionsByChapter {
    final grouped = <String, List<BarrioQuizQuestion>>{};
    for (final q in questions) {
      grouped.putIfAbsent(q.chapterId, () => <BarrioQuizQuestion>[]).add(q);
    }
    return grouped;
  }
}

/// Every quiz bank, keyed by training-doc id (matches [BarrioTrainingDoc.id]
/// / the `kBarrioTrainingDocs` registry key). Exactly the three manuals the
/// approved quiz-bank slice covers.
const Map<String, BarrioQuizBank> kBarrioQuizBanks = <String, BarrioQuizBank>{
  'training_food_safety': kBarrioQuizFoodSafety,
  'training_coffee': kBarrioQuizCoffee,
  'training_latin_dishes': kBarrioQuizLatinDishes,
};
