// Validation for the operator-reviewable Barrio quiz question bank.
//
// These questions are NEW operator-facing training content (drafts until
// the operator reads them). This test is the automated guard that keeps
// every draft honest and traceable to the verbatim training text:
//
//   * every `sourceUnitId` resolves to a real card in its manual;
//   * the question's `chapterId` is the chapter that actually contains
//     that card (traceability);
//   * the correct option's key fact terms actually appear in that card's
//     text (best-effort textual check, heuristic documented below);
//   * `correctIndex` is in range, options are 3 to 4 and unique, and
//     `whyLine`/`prompt` are non-empty;
//   * every chapter of every covered manual has at least one question
//     (target 2 to 3 per chapter);
//   * no operator-facing string contains an em dash (UX no-em-dash law).
//
// TEXTUAL-CONTAINMENT HEURISTIC (best-effort, deliberately forgiving):
//   The "card text" searched is the source card's title plus its body,
//   lowercased (the title is verbatim card content shown to the reader,
//   e.g. the card titled "Biological Hazards"). The correct option is
//   tokenized into "significant" tokens: alphabetic words of length >= 3
//   that are not common function words, plus all-digit tokens of length
//   >= 3 (so "165" counts, "40" does not). A token matches when it occurs
//   as a substring of the card text. At least 60% of a correct option's
//   significant tokens must match. This catches invented facts and wrong
//   source cards while tolerating verbatim-source typos (e.g. "course"
//   for "coarse") and minor grammatical rewording.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_coffee_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_food_safety_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_latin_dishes_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_wine_content.dart';

const int _emDash = 0x2014;

/// The manuals the quiz bank covers, keyed by their doc id. Wine joined the
/// original three on 2026-08-06 at the same per-chapter density.
const Map<String, BarrioTrainingDoc> _docsUnderTest = <String, BarrioTrainingDoc>{
  'training_food_safety': kTrainingFoodSafety,
  'training_coffee': kTrainingCoffee,
  'training_latin_dishes': kTrainingLatinDishes,
  'training_wine': kTrainingWine,
};

/// Common English function words dropped before textual containment.
const Set<String> _stopWords = <String>{
  'the', 'and', 'or', 'of', 'to', 'in', 'is', 'are', 'be', 'it', 'its',
  'that', 'this', 'with', 'for', 'on', 'at', 'as', 'by', 'from', 'into',
  'than', 'then', 'they', 'them', 'you', 'your', 'our', 'was', 'were',
  'will', 'would', 'should', 'can', 'could', 'not', 'but', 'if', 'so',
  'do', 'does', 'done', 'has', 'have', 'had', 'what', 'which', 'who',
  'when', 'where', 'how', 'why', 'about',
};

bool _isAllDigits(String s) => RegExp(r'^[0-9]+$').hasMatch(s);

/// Significant tokens of [text]: length >= 3 non-stopword words, plus
/// all-digit tokens of length >= 3.
List<String> _significantTokens(String text) {
  final raw = text.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
  final tokens = <String>[];
  for (final t in raw) {
    if (t.isEmpty) continue;
    if (_isAllDigits(t)) {
      if (t.length >= 3) tokens.add(t);
      continue;
    }
    if (t.length >= 3 && !_stopWords.contains(t)) tokens.add(t);
  }
  return tokens;
}

bool _hasEmDash(String s) => s.runes.contains(_emDash);

void main() {
  // Build, per doc, a lookup from unit id to (unit, owning chapter id) and
  // the ordered list of chapter ids.
  final unitLookup = <String, Map<String, MapEntry<HandbookUnit, String>>>{};
  final chapterIds = <String, List<String>>{};
  for (final entry in _docsUnderTest.entries) {
    final doc = entry.value;
    final units = <String, MapEntry<HandbookUnit, String>>{};
    final chapters = <String>[];
    for (final chapter in doc.chapters) {
      chapters.add(chapter.id);
      for (final unit in chapter.units) {
        units[unit.id] = MapEntry(unit, chapter.id);
      }
    }
    unitLookup[entry.key] = units;
    chapterIds[entry.key] = chapters;
  }

  test('registry covers exactly the approved manuals', () {
    expect(
      kBarrioQuizBanks.keys.toSet(),
      <String>{
        'training_food_safety',
        'training_coffee',
        'training_latin_dishes',
        'training_wine',
      },
    );
    for (final docId in kBarrioQuizBanks.keys) {
      expect(_docsUnderTest.containsKey(docId), isTrue,
          reason: '$docId has no training doc under test');
      expect(kBarrioQuizBanks[docId]!.docId, docId,
          reason: 'bank docId mismatch for $docId');
    }
  });

  test('every question is well-formed and traceable to one source card', () {
    final seenIds = <String>{};
    for (final bank in kBarrioQuizBanks.values) {
      final units = unitLookup[bank.docId]!;
      for (final q in bank.questions) {
        final where = '${bank.docId} / ${q.id}';

        // Unique ids and matching docId.
        expect(seenIds.add(q.id), isTrue, reason: 'duplicate question id $where');
        expect(q.docId, bank.docId, reason: 'docId mismatch on $where');

        // Prompt + whyLine present.
        expect(q.prompt.trim(), isNotEmpty, reason: 'empty prompt on $where');
        expect(q.whyLine.trim(), isNotEmpty, reason: 'empty whyLine on $where');

        // 3 to 4 unique options; correctIndex in range.
        expect(q.options.length, inInclusiveRange(3, 4),
            reason: 'option count out of range on $where');
        expect(q.options.toSet().length, q.options.length,
            reason: 'duplicate options on $where');
        for (final o in q.options) {
          expect(o.trim(), isNotEmpty, reason: 'empty option on $where');
        }
        expect(q.correctIndex, inInclusiveRange(0, q.options.length - 1),
            reason: 'correctIndex out of range on $where');

        // Source unit resolves within THIS doc, and the question chapter is
        // the chapter that owns the card.
        final resolved = units[q.sourceUnitId];
        expect(resolved, isNotNull,
            reason: 'sourceUnitId ${q.sourceUnitId} not found in ${bank.docId} '
                '($where)');
        expect(q.chapterId, resolved!.value,
            reason: 'chapterId ${q.chapterId} is not the chapter that owns '
                '${q.sourceUnitId} ($where)');

        // Textual containment: correct option key terms appear in the card.
        final cardText =
            '${resolved.key.title}\n${resolved.key.body}'.toLowerCase();
        final tokens = _significantTokens(q.correctOption);
        expect(tokens, isNotEmpty,
            reason: 'correct option has no significant tokens on $where');
        final present = tokens.where((t) => cardText.contains(t)).length;
        final ratio = present / tokens.length;
        expect(ratio, greaterThanOrEqualTo(0.6),
            reason: 'correct option not traceable to source card on $where: '
                'only $present/${tokens.length} key terms found in the card '
                'text. Option: "${q.correctOption}"');
      }
    }
  });

  test('no operator-facing string uses an em dash', () {
    for (final bank in kBarrioQuizBanks.values) {
      for (final q in bank.questions) {
        expect(_hasEmDash(q.prompt), isFalse,
            reason: 'em dash in prompt of ${q.id}');
        expect(_hasEmDash(q.whyLine), isFalse,
            reason: 'em dash in whyLine of ${q.id}');
        for (final o in q.options) {
          expect(_hasEmDash(o), isFalse,
              reason: 'em dash in an option of ${q.id}');
        }
      }
    }
  });

  test('every chapter of every covered manual has at least one question',
      () {
    for (final bank in kBarrioQuizBanks.values) {
      final covered = bank.questionsByChapter.keys.toSet();
      for (final chapterId in chapterIds[bank.docId]!) {
        expect(covered.contains(chapterId), isTrue,
            reason: 'chapter $chapterId of ${bank.docId} has no quiz question');
      }
    }
  });

  test('each covered chapter targets 2 to 3 questions', () {
    // Soft target from the slice spec: aim for 2 to 3 per chapter. Any
    // chapter honestly limited to 1 by its source text would be reported
    // in the PR body; none currently are, so this asserts the achieved
    // floor of 2 to keep future edits from silently thinning a chapter.
    for (final bank in kBarrioQuizBanks.values) {
      bank.questionsByChapter.forEach((chapterId, qs) {
        expect(qs.length, inInclusiveRange(2, 3),
            reason: '${bank.docId} / $chapterId has ${qs.length} questions '
                '(target 2 to 3)');
      });
    }
  });
}
