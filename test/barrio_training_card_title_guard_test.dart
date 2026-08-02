// Guards the card-title contract that tool/barrio_training_card_titles.json
// exists to satisfy.
//
// A section too long for one card is split into a run. Card 1 keeps the
// verbatim source heading; cards 2..N are titled '<heading> (cont.)' by
// the generator, which tells the reader nothing about what that card
// teaches. The manifest replaces those titles with authored ones.
//
// WHY TWO TIERS OF RULE. The end-state contract is "every card title is
// short, unique in its chapter, and never says (cont.)". Today's content
// cannot satisfy it, and not because it is sloppy:
//
//   * 251 run-start titles are longer than 26 characters. Those are
//     VERBATIM source headings. Shortening one deletes source words, and
//     tool/barrio_training_verbatim_check.py only passes at lost=0w, so
//     they are permanently out of reach.
//   * 183 continuation cards still carry the generated '(cont.)' title,
//     and a run of 3+ cards therefore repeats the same title inside one
//     chapter. Authoring those titles is the NEXT slice; this slice only
//     ships the mechanism.
//
// So the strong rules bind exactly the titles this mechanism produces
// (an authored continuation title), where they can be enforced at full
// strength from the first title that lands. The population still
// carrying generated titles is held by a RATCHET: the counts below may
// fall, never grow. Each authoring wave lowers the two constants in the
// same PR; when kDefaultContinuationTitleBaseline reaches 0 every
// continuation card is authored and the strong rules cover all of them.
// The rules are not weakened, they are scoped honestly to what exists.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

/// Longest authored title that stays on ONE line in the card header.
/// The measured header budget (Playfair 17 at a 390pt card) and the
/// diagram engine's own `wrap(title, 26, 3)` agree on this number.
const int kMaxCardTitleChars = 26;

/// RATCHET: continuation cards still carrying the generated
/// `'<heading> (cont.)'` title. Lower this as authoring waves land; it
/// must never grow. 0 means every continuation card is authored.
const int kDefaultContinuationTitleBaseline = 183;

/// RATCHET: cards that repeat a title already used in the same chapter.
/// Almost all of these are '(cont.)' runs of 3+ cards, so authoring
/// drives this down with the constant above. It bottoms out at 1: the
/// BOLD By Design chapter that legitimately opens two runs with the
/// verbatim heading 'Protect the System'.
const int kChapterDuplicateTitleBaseline = 62;

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

    test('only continuation cards carry a "(cont.)" title', () {
      // The run-start card holds the verbatim source heading, so a
      // '(cont.)' there would mean the generator suffixed the wrong
      // card. It also keeps _generatedContinuationTitle honest: the
      // authored-title test below depends on the default being exactly
      // '<run-start title> (cont.)'.
      for (final card in _allCards()) {
        if (card.unit.runIndex > 1) continue;
        expect(card.unit.title.endsWith('(cont.)'), isFalse,
            reason: '${card.unit.id} opens a run but is titled as a '
                'continuation');
      }
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

    test('RATCHET: the count of un-authored continuation titles only falls',
        () {
      // Growth fails; a drop passes and is the signal to lower the
      // constant in the same PR (same posture as
      // tool/metrics_ratchet_check.dart: the bar only tightens on
      // purpose, never silently).
      final pending = _allCards()
          .where((c) => c.unit.runIndex > 1 && !_isAuthored(c))
          .length;
      expect(pending, lessThanOrEqualTo(kDefaultContinuationTitleBaseline),
          reason: 'continuation cards still titled "(cont.)" grew from '
              '$kDefaultContinuationTitleBaseline to $pending; every new '
              'split card needs an authored title in '
              'tool/barrio_training_card_titles.json');
    });

    test('RATCHET: the count of repeated titles within a chapter only falls',
        () {
      var repeats = 0;
      for (final doc in kBarrioTrainingDocs.values) {
        for (final chapter in doc.chapters) {
          final seen = <String>{};
          for (final unit in chapter.units) {
            if (!seen.add(unit.title)) repeats++;
          }
        }
      }
      // Lower the constant whenever this drops (see the ratchet above).
      expect(repeats, lessThanOrEqualTo(kChapterDuplicateTitleBaseline),
          reason: 'chapter-internal duplicate titles grew from '
              '$kChapterDuplicateTitleBaseline to $repeats; authoring a '
              'continuation title must not create a collision');
    });
  });
}
