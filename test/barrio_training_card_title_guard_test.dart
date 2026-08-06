// Guards the card-title contract that tool/barrio_training_card_titles.json
// exists to satisfy.
//
// A section too long for one card is split into a run. Card 1 keeps the
// verbatim source heading; cards 2..N are titled '<heading> (cont.)' by
// the generator, which tells the reader nothing about what that card
// teaches. The manifest replaces those titles with authored ones.
//
// WHY TWO TIERS OF RULE. The end-state contract is "every card title is
// short, unique in its chapter, and never says (cont.)". Authoring is
// now DONE: all 183 continuation cards carry an authored title, so the
// '(cont.)' half of that contract is a HARD assertion below, not a
// ratchet. What is still out of reach is the source headings themselves:
//
//   * 251 run-start titles are longer than 26 characters. Those are
//     VERBATIM source headings. Shortening one deletes source words, and
//     tool/barrio_training_verbatim_check.py only passes at lost=0w, so
//     they are permanently out of reach. Held by a ratchet, not a rule.
//   * 1 chapter repeats a title: BOLD By Design c32 legitimately opens
//     two runs with the verbatim heading 'Protect the System'. Same
//     reason, same posture.
//
// So the strong rules bind every title this mechanism produces (an
// authored continuation title) at full strength, and the two verbatim
// source-heading populations are held by RATCHETS: the counts below may
// fall, never grow. A ratchet that drops is the signal to lower its
// constant in the same PR. The rules are not weakened, they are scoped
// honestly to what the source documents make possible.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

/// Longest authored title that stays on ONE line in the card header.
/// The measured header budget (Playfair 17 at a 390pt card) and the
/// diagram engine's own `wrap(title, 26, 3)` agree on this number.
const int kMaxCardTitleChars = 26;

/// RATCHET: card titles longer than [kMaxCardTitleChars].
///
/// Every one of these is a run-start card carrying a VERBATIM source
/// heading, so it cannot be shortened without failing
/// tool/barrio_training_verbatim_check.py at lost=0w. Authored titles
/// are held to the hard bound instead (see the strong rules below), so
/// this number can only move when a source document changes.
///
/// Was 351 before the authoring wave: 251 run-start headings plus the
/// 100 continuation cards whose generated `'<heading> (cont.)'` title
/// inherited a long heading. Authoring all 183 continuation cards took
/// the continuation share to 0, leaving the 251 source headings.
///
/// 257 as of 2026-08-06, the only sanctioned reason this number moves up:
/// a source document was ADDED. The Wine Training manual contributes six
/// run-start cards whose verbatim source headings exceed the budget:
///
///   Other Notable Grape Varietals    (29)
///   Asti Spumante/Moscato d'Asti     (28)
///   History of Argentinian Wine      (27)
///   Portuguese White Wine Varietals  (31)
///   How to Open Champagne/Sparkling  (31)
///   How to Pour Champagne/Sparkling  (31)
///
/// None can be shortened: they are the operator PDF's own headings, and
/// `tool/barrio_training_verbatim_check.py` only passes at `lost=0w`.
/// Wine's continuation share is 0, exactly like every other manual, and
/// the `authoredOver` assertion below is what actually holds the rule.
const int kOverBudgetTitleBaseline = 257;

/// RATCHET: cards that repeat a title already used in the same chapter.
///
/// Was 62 before the authoring wave, almost all of it '(cont.)' runs of
/// 3+ cards sharing one generated title. Authoring cleared those and
/// the count bottomed out at its floor of 1: the BOLD By Design chapter
/// that legitimately opens two runs with the verbatim source heading
/// 'Protect the System'. Only a source-document change can move it.
const int kChapterDuplicateTitleBaseline = 1;

/// One card plus the title of the card that opened its run.
typedef _Card = ({
  String docId,
  String chapterId,
  HandbookUnit unit,
  String runStartTitle,
});

/// Every training card, tagged with its run-start title.
///
/// Runs are read off run metadata (runIndex), never off the title text:
/// that is the whole point of the mechanism these rules guard.
List<_Card> _allCards() {
  final cards = <_Card>[];
  for (final doc in kBarrioTrainingDocs.values) {
    for (final chapter in doc.chapters) {
      var runStartTitle = '';
      for (final unit in chapter.units) {
        if (unit.runIndex == 1) runStartTitle = unit.title;
        cards.add((
          docId: doc.id,
          chapterId: chapter.id,
          unit: unit,
          runStartTitle: runStartTitle,
        ));
      }
    }
  }
  return cards;
}

/// The title the generator emits for a continuation card with no
/// manifest entry (see split_unit in the generator).
String _generatedContinuationTitle(String runStartTitle) =>
    '$runStartTitle (cont.)';

/// Whether [card] carries a title authored through the manifest: a
/// continuation card whose title is not the generator's default.
bool _isAuthored(_Card card) =>
    card.unit.runIndex > 1 &&
    card.unit.title != _generatedContinuationTitle(card.runStartTitle);

void main() {
  group('training card titles', () {
    test('every card title is non-empty', () {
      for (final card in _allCards()) {
        expect(card.unit.title.trim(), isNotEmpty,
            reason: '${card.unit.id} has no title');
      }
    });

    test('no card title anywhere says "(cont.)"', () {
      // HARD ASSERTION, not a ratchet. Every continuation card is
      // authored, so the generator's '<heading> (cont.)' default must
      // no longer reach the app: a run-start card ending in '(cont.)'
      // would mean the generator suffixed the wrong card, and a
      // continuation card ending in '(cont.)' would mean a card slipped
      // out of tool/barrio_training_card_titles.json (a new split, a
      // re-pointed unit id) without anyone authoring a title for it.
      final offenders = _allCards()
          .where((c) => c.unit.title.endsWith('(cont.)'))
          .map((c) => '${c.unit.id}: "${c.unit.title}"')
          .toList();
      expect(offenders, isEmpty,
          reason: '${offenders.length} card(s) still carry the generated '
              '"(cont.)" title; author each one in '
              'tool/barrio_training_card_titles.json: '
              '${offenders.join(", ")}');
    });

    test('every continuation card carries an authored title', () {
      // The other half of the same hard assertion. A card could dodge
      // the '(cont.)' test by having a run-start heading that already
      // ended in '(cont.)'; this checks the default directly.
      final pending = _allCards()
          .where((c) => c.unit.runIndex > 1 && !_isAuthored(c))
          .map((c) => c.unit.id)
          .toList();
      expect(pending, isEmpty,
          reason: '${pending.length} continuation card(s) still carry the '
              'generator default; every split card needs an authored title '
              'in tool/barrio_training_card_titles.json: '
              '${pending.join(", ")}');
    });

    test('every authored continuation title is short, self-describing, '
        'and unique in its chapter', () {
      final cards = _allCards();
      final titlesByChapter = <String, List<String>>{};
      for (final card in cards) {
        titlesByChapter
            .putIfAbsent(card.chapterId, () => <String>[])
            .add(card.unit.title);
      }

      for (final card in cards.where(_isAuthored)) {
        final title = card.unit.title;
        expect(title.length, lessThanOrEqualTo(kMaxCardTitleChars),
            reason: '${card.unit.id}: "$title" is ${title.length} chars; '
                'the card header fits $kMaxCardTitleChars on one line');
        expect(title.endsWith('(cont.)'), isFalse,
            reason: '${card.unit.id}: an authored title must say what the '
                'card teaches, not "(cont.)"');
        // U+2014 by code unit, so this guard does not itself contain the
        // glyph the repo's no-em-dash law bans.
        expect(title.codeUnits.contains(0x2014), isFalse,
            reason: '${card.unit.id}: no em dash in operator-facing copy');
        final sameTitle =
            titlesByChapter[card.chapterId]!.where((t) => t == title).length;
        expect(sameTitle, 1,
            reason: '${card.unit.id}: "$title" appears $sameTitle times in '
                '${card.chapterId}; a chapter must not repeat a title');
      }
    });

    test('RATCHET: the count of over-budget titles only falls', () {
      // Growth fails; a drop passes and is the signal to lower the
      // constant in the same PR (same posture as
      // tool/metrics_ratchet_check.dart: the bar only tightens on
      // purpose, never silently).
      final overBudget = _allCards()
          .where((c) => c.unit.title.length > kMaxCardTitleChars)
          .toList();
      expect(overBudget.length, lessThanOrEqualTo(kOverBudgetTitleBaseline),
          reason: 'card titles longer than $kMaxCardTitleChars chars grew '
              'from $kOverBudgetTitleBaseline to ${overBudget.length}; an '
              'authored title must fit the header budget, and a run-start '
              'heading only lengthens when the source document changes');
      // The whole justification for tolerating these is that they are
      // verbatim source headings. An AUTHORED title in here would mean
      // the ratchet is hiding a rule violation.
      final authoredOver = overBudget
          .where(_isAuthored)
          .map((c) => '${c.unit.id}: "${c.unit.title}"')
          .toList();
      expect(authoredOver, isEmpty,
          reason: 'the over-budget population must be verbatim source '
              'headings only: ${authoredOver.join(", ")}');
    });

    test('RATCHET: the count of repeated titles within a chapter only falls',
        () {
      final repeats = <String>[];
      for (final doc in kBarrioTrainingDocs.values) {
        for (final chapter in doc.chapters) {
          final seen = <String>{};
          for (final unit in chapter.units) {
            if (!seen.add(unit.title)) {
              repeats.add('${chapter.id}: "${unit.title}"');
            }
          }
        }
      }
      // Lower the constant whenever this drops (see the ratchet above).
      expect(repeats.length, lessThanOrEqualTo(kChapterDuplicateTitleBaseline),
          reason: 'chapter-internal duplicate titles grew from '
              '$kChapterDuplicateTitleBaseline to ${repeats.length}; '
              'authoring a continuation title must not create a collision: '
              '${repeats.join(", ")}');
    });
  });
}
