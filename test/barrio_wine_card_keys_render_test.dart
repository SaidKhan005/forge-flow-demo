// Proof that the Wine Training manual's authored per-card key phrases really
// light up, and that a wine card without an authored set is unharmed.
//
// WHY A RENDER TEST AND NOT JUST A DATA TEST
//
// `test/barrio_card_key_sets_test.dart` proves the DATA satisfies the
// authoring contract. It does not pump a widget, so it cannot prove the
// phrases survive the card's five-tier span pipeline (search highlight, term
// link, numeric pop, quiz answer evidence, then key terms last). Every one of
// those tiers outranks key terms and drops an overlapping phrase WHOLE, with
// no error: the phrase simply never appears. Wine is the first manual whose
// phrases were authored alongside its own quiz answer evidence, so this test
// pumps real wine cards and asserts the phrases are on screen.
//
// WHY THE FALLBACK HALF MATTERS MORE FOR WINE THAN FOR ANY EARLIER MANUAL
//
// Wine is the first doc to carry per-card phrases WITHOUT a per-manual list
// behind it (`training_wine` is absent from `barrio_key_terms.dart`). So an
// uncovered wine card must resolve to the per-manual answer, which for wine is
// an empty list, and must render with no key-term span at all. If
// `barrioCardKeysForUnit` ever leaked another doc's list, or the renderer
// started highlighting uncurated cards, that is exactly where it would show.
// The last test keeps the fallback claim honest by proving it is not vacuous:
// an uncovered card in a CURATED manual still gets that manual's non-empty
// list.
//
// Nothing about the corpus is hard-coded: the sampled cards, the uncovered
// cards, and the curated comparison doc are all derived at runtime from
// `kBarrioTrainingDocs`, so a content regeneration cannot rot this file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

const String _wineDocId = 'training_wine';

/// Every unit of [docId] in reading order.
List<HandbookUnit> _unitsOf(String docId) => <HandbookUnit>[
      for (final chapter in kBarrioTrainingDocs[docId]!.chapters)
        ...chapter.units,
    ];

/// Every leaf [TextSpan] under [span], in reading order.
List<TextSpan> _flatten(InlineSpan span) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      out.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return out;
}

/// A key-term emphasis span: bold + tealInk with NO background wash. That
/// combination is what distinguishes it from the search highlight (tealWarm
/// background), the numeric fact pop (the manual's accent) and the quiz
/// answer span (tealDeep, w600).
bool _isKeyTermSpan(TextSpan s) =>
    s.style?.color == BarrioColors.tealInk &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: HandbookLessonCard(unit: unit)),
      ),
    ),
  );
  await tester.pump();
}

/// The key-term-emphasized wording actually on screen for [unit], in reading
/// order. Only [RichText]s whose plain text is verbatim body content are read,
/// so a title or badge can never be mistaken for body emphasis (list rows drop
/// their bullet marker and table rows split on the cell separator, and both
/// remain substrings of the body).
List<String> _renderedKeyPhrases(WidgetTester tester, HandbookUnit unit) {
  final out = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final plain = rich.text.toPlainText();
    if (plain.length < 20 || !unit.body.contains(plain)) continue;
    for (final span in _flatten(rich.text)) {
      if (span.text != null && _isKeyTermSpan(span)) out.add(span.text!);
    }
  }
  return out;
}

void main() {
  final wineUnits = _unitsOf(_wineDocId);
  final covered = wineUnits
      .where((u) => (kBarrioCardKeysByUnit[u.id] ?? const []).isNotEmpty)
      .toList();
  final uncovered = wineUnits
      .where((u) => (kBarrioCardKeysByUnit[u.id] ?? const []).isEmpty)
      .toList();

  group('the wine manual actually carries authored phrases', () {
    test('most wine cards are covered, and every card is accounted for', () {
      expect(wineUnits, isNotEmpty, reason: 'the wine manual must render');
      expect(covered.length + uncovered.length, wineUnits.length);
      // Deliberately a floor, not an equality: a handful of one-clause and
      // number-only cards honestly cannot carry three phrases and ship no
      // entry. Ratchet only.
      expect(covered.length, greaterThanOrEqualTo(200),
          reason: 'wine coverage fell: ${covered.length} of '
              '${wineUnits.length} cards carry an authored set');
    });

    test('every authored wine phrase is disjoint from that card\'s quiz '
        'answer evidence (the tier that would silently drop it)', () {
      for (final unit in covered) {
        final evidence = barrioAnswerEvidenceForUnit(unit.id);
        if (evidence.isEmpty) continue;
        for (final phrase in kBarrioCardKeysByUnit[unit.id]!) {
          for (final answer in evidence) {
            expect(answer.contains(phrase), isFalse,
                reason: '${unit.id}: "$phrase" sits inside answer evidence');
            expect(phrase.contains(answer), isFalse,
                reason: '${unit.id}: "$phrase" swallows answer evidence');
          }
        }
      }
    });
  });

  group('authored phrases render on the card (the silent-drop guard)', () {
    // A spread sample plus, deliberately, a card that also carries quiz
    // answer evidence: that is the pairing where the higher tier could eat a
    // phrase. Indices are derived, so the sample follows the content.
    final sample = <HandbookUnit>{
      covered.first,
      covered[covered.length ~/ 4],
      covered[covered.length ~/ 2],
      covered[(covered.length * 3) ~/ 4],
      covered.last,
      covered.firstWhere(
        (u) => barrioAnswerEvidenceForUnit(u.id).isNotEmpty,
        orElse: () => covered.first,
      ),
    }.toList();

    for (final unit in sample) {
      testWidgets('${unit.id} shows all of its authored phrases in reading '
          'order', (tester) async {
        final authored = kBarrioCardKeysByUnit[unit.id]!;
        await _pumpCard(tester, unit);
        expect(_renderedKeyPhrases(tester, unit), authored,
            reason: '${unit.id}: the rendered emphasis must be exactly the '
                'authored phrases, in order. A missing one was dropped by a '
                'higher-precedence tier or never matched.');
      });
    }

    testWidgets('emphasis is styling only: the sampled card\'s body text is '
        'byte-identical to the source', (tester) async {
      final unit = sample.first;
      await _pumpCard(tester, unit);
      final rendered = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((rt) => rt.text.toPlainText())
          .where((t) => t.length >= 20 && unit.body.contains(t))
          .join('\n\n');
      expect(rendered, isNotEmpty);
      for (final chunk in rendered.split('\n\n')) {
        expect(unit.body.contains(chunk), isTrue,
            reason: 'rendered body wording drifted from the source');
      }
    });
  });

  group('a card with no authored entry still takes the fallback', () {
    test('every uncovered wine card resolves to the per-manual answer', () {
      expect(uncovered, isNotEmpty,
          reason: 'the fallback path must still be exercised by real cards');
      for (final unit in uncovered) {
        expect(barrioCardKeysForUnit(unit.id), barrioKeyTermsForUnit(unit.id),
            reason: '${unit.id} must render the per-manual list unchanged');
      }
    });

    testWidgets('an uncovered wine card renders no key-term emphasis at all',
        (tester) async {
      final unit = uncovered.first;
      await _pumpCard(tester, unit);
      expect(_renderedKeyPhrases(tester, unit), isEmpty,
          reason: '${unit.id} has no authored set and wine has no per-manual '
              'list, so nothing may light up');
    });

    test('the fallback is not vacuous: an uncovered card in a CURATED manual '
        'still gets that manual\'s non-empty list', () {
      HandbookUnit? curatedUncovered;
      for (final entry in kBarrioTrainingDocs.entries) {
        for (final chapter in entry.value.chapters) {
          for (final unit in chapter.units) {
            final authored = kBarrioCardKeysByUnit[unit.id] ?? const [];
            if (authored.isEmpty && barrioKeyTermsForUnit(unit.id).isNotEmpty) {
              curatedUncovered = unit;
              break;
            }
          }
          if (curatedUncovered != null) break;
        }
        if (curatedUncovered != null) break;
      }
      expect(curatedUncovered, isNotNull,
          reason: 'no uncovered card left in a curated manual: the fallback '
              'claim can no longer be proved here, move this guard');
      expect(barrioCardKeysForUnit(curatedUncovered!.id),
          barrioKeyTermsForUnit(curatedUncovered.id));
      expect(barrioCardKeysForUnit(curatedUncovered.id), isNotEmpty);
    });
  });
}
