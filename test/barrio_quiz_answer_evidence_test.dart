// Guard for the chapter-end quiz answer-highlight data (operator request
// 2026-07-26): the training reader highlights, inside a reading card, the
// exact phrase that answers each chapter-end quiz question, so a learner
// can scan the key fact before reaching the quiz.
//
// This is the STRONG guard that keeps every highlight honest: for every
// question that carries an [BarrioQuizQuestion.answerEvidence] phrase, the
// phrase must be a VERBATIM substring of its source card's real body,
// loaded from the live `kBarrioTrainingDocs` registry. That proves the
// highlight always exists in the text the reader sees (verbatim law:
// styling only, never a body-text change). It also checks the pure lookup
// helper the reader uses, and forbids em dashes (UX no-em-dash law).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

const int _emDash = 0x2014;

void main() {
  // unit id -> card body, over the whole live training registry (the
  // real docs the reader renders, resolved via kBarrioTrainingDocs).
  final bodyByUnit = <String, String>{};
  for (final doc in kBarrioTrainingDocs.values) {
    for (final chapter in doc.chapters) {
      for (final unit in chapter.units) {
        bodyByUnit[unit.id] = unit.body;
      }
    }
  }

  test('every answerEvidence phrase is a verbatim substring of its card body',
      () {
    var checked = 0;
    for (final bank in kBarrioQuizBanks.values) {
      for (final q in bank.questions) {
        final phrase = q.answerEvidence;
        if (phrase == null) continue;
        checked++;
        expect(phrase, isNotEmpty,
            reason: '${q.id}: answerEvidence must be null, not empty');
        final body = bodyByUnit[q.sourceUnitId];
        expect(body, isNotNull,
            reason: '${q.id}: sourceUnitId ${q.sourceUnitId} not in registry');
        expect(body!.contains(phrase), isTrue,
            reason: '${q.id}: answerEvidence is not a verbatim substring of '
                'card ${q.sourceUnitId}:\n  <$phrase>');
      }
    }
    // Sanity: the slice authored evidence for the large majority of the
    // ~105-question bank, so a regression that blanks the data is caught.
    expect(checked, greaterThanOrEqualTo(90),
        reason: 'expected most questions to carry answer evidence');
  });

  test('answerEvidence carries no em dash (UX no-em-dash law)', () {
    for (final bank in kBarrioQuizBanks.values) {
      for (final q in bank.questions) {
        final phrase = q.answerEvidence;
        if (phrase == null) continue;
        expect(phrase.runes.contains(_emDash), isFalse,
            reason: '${q.id}: answerEvidence must not use an em dash');
      }
    }
  });

  test('barrioAnswerEvidenceForUnit returns exactly a unit\'s phrases', () {
    // Build the expected map straight from the banks, then compare.
    final expected = <String, List<String>>{};
    for (final bank in kBarrioQuizBanks.values) {
      for (final q in bank.questions) {
        final phrase = q.answerEvidence;
        if (phrase == null) continue;
        expected.putIfAbsent(q.sourceUnitId, () => <String>[]).add(phrase);
      }
    }
    for (final entry in expected.entries) {
      expect(barrioAnswerEvidenceForUnit(entry.key), entry.value,
          reason: 'helper mismatch for unit ${entry.key}');
    }
    // A unit with no quiz evidence returns an empty list (callers need no
    // special-casing), and an unknown id is empty too.
    expect(barrioAnswerEvidenceForUnit('does_not_exist'), isEmpty);
  });
}
