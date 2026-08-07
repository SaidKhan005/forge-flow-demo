// Render + fallback guards for the per-CARD key phrases authored on the
// two Latin American glossaries and the Push Schedule SOP (2026-08-07).
//
// WHY A SEPARATE FILE. `test/barrio_card_key_sets_test.dart` binds the
// authoring CONTRACT over whatever is in the registry: cardinality,
// verbatim matching, ordering, no digits, no boilerplate, no collision
// with quiz answer evidence. What it cannot say is that any of it
// reaches the screen. Those three manuals are the first to carry
// authored phrases with NO per-manual list behind them AND no prose
// curation of any kind, so "the data is well formed" and "the reader
// sees six highlights" are genuinely different claims here: before this
// data landed, every card in all three rendered zero emphasis.
//
// HOW THIS AVOIDS TESTING ITSELF. The expected phrase list for each
// probe card is written out LONGHAND below. It is deliberately NOT read
// from `kBarrioCardKeysByUnit` or `barrioCardKeysForUnit` (the path
// under test): a guard that asks the data what the data says passes on
// any data, including none. The card BODY comes from
// `kBarrioTrainingDocs`, a different path, and every probe asserts the
// EXACT set of emphasized substrings, so a dropped phrase and a stray
// extra one both go red.
//
// WHAT EACH PROBE COSTS IF IT IS WRONG. Every tier that outranks key
// phrases drops an overlapping one WHOLE and silently
// (`handbook_lesson_card.dart` `_composeChunk`), so the failure mode
// this file exists for is a card that quietly loses a highlight and
// still looks fine. The three probes are picked to sit next to the
// tiers that do the eating:
//   * PICO DE GALLO carries chapter-quiz answer evidence mid-body,
//   * SHISHITO PEPPER carries a numeric pop ('10%'),
//   * 'Releasing a Shift' carries a numbered-list block, where the
//     rendered chunk is not the raw paragraph (the 'N. ' marker is
//     stripped into its own Text).
//
// The last group proves the rules are load-bearing rather than
// decorative: on those same real cards, a deliberately rule-breaking
// phrase renders NOTHING.
//
// RED-PROOFED 2026-08-07, one mutation at a time on this branch:
//   * unregister `kBarrioCardKeysTrainingLatinDishes` in the index and
//     the dishes probe fails alone (same for ingredients, same for the
//     SOP), so each render probe is tied to its own manual's data;
//   * author the Pay Stubs card and its fallback probe fails;
//   * make [_wouldRender] pass empty `blockedRanges` and both the
//     'renders NOTHING' assertions that depend on an outranking tier
//     fail, so those two are about blocking and not about a typo.
// One honest non-result: removing the chunk filter in [_emphasized]
// changed nothing, because no chrome on these cards happens to carry
// tealInk + w700 today. The filter stays as defence in depth; it is not
// a proven guard, and this comment says so rather than implying it is.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

// ---------------------------------------------------------------------
// Probe cards. Ids and expected phrases are longhand on purpose (see the
// header): they are the independent statement this file makes about the
// data, not a copy of it.
// ---------------------------------------------------------------------

/// Latin American Dishes, chapter 'M to S', card 'PICO DE GALLO'. Its
/// chapter quiz claims the 'dry consistency' clause as answer evidence,
/// so this probe also proves the two tiers coexist on one card.
const _dishesUnitId = 'training_latin_dishes_c3_u2';
const _dishesExpected = <String>[
  'vibrant and fresh Mexican condiment',
  'chopped raw tomatoes, white onions, and cilantro',
  'heat of serrano or jalapeño peppers',
  'brightened with a splash of lime juice',
  'Unlike blended salsas',
  'perfect topping for tacos or grilled meats',
];

/// Latin American Ingredients, chapter 'P to T', card 'SHISHITO PEPPER'.
/// Its body carries '10%', which the numeric tier claims whole, so this
/// probe proves the phrases were authored around a live numeric pop.
const _ingredientsUnitId = 'training_latin_ingredients_c3_u9';
const _ingredientsExpected = <String>[
  'small and slender pepper',
  'vibrant green hue',
  'Mostly mild with a sweet flavor profile',
  'smoky, citrusy undertone',
  'can surprise the palate with unexpected spiciness',
  'modern Latin-fusion cuisine',
];

/// Push Schedule, chapter 'Hours and Shift Management', card 'Releasing
/// a Shift'. Its body holds a numbered-list block, so the rendered chunk
/// is not the raw paragraph, and quoted button labels ('Accept',
/// 'Cancel') that the phrases have to survive.
const _pushUnitId = 'training_push_sop_c1_u6';
const _pushExpected = <String>[
  'click on the arrow icon on the shift you want to release',
  'Add a note before sending it over for the manger to approve',
  'they will apear with a yellow status banner below',
  'Click "Accept" to confirm the shift swap request',
  'Click on "Cancel" to reject the shift swap request',
  // One phrase, one literal, over the usual line width on purpose:
  // split across adjacent strings it trips no_adjacent_strings_in_list,
  // and it has to stay the verbatim body substring it matches.
  'Once any release or swap is accepted by a teammate it has to go through manager approval',
];

/// Cards in these manuals that carry NO authored entry, and must
/// therefore render exactly what they rendered before: nothing. Both are
/// short by nature ('Spanish word for salad.'), which is why fewer than
/// three phrases survive on them.
const _unauthoredDishesUnitId = 'training_latin_dishes_c2_u0'; // ENSALADA
const _unauthoredPushUnitId = 'training_push_sop_c2_u1'; // Pay Stubs

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/// The real [HandbookUnit] behind an id, from the CONTENT registry (not
/// the key-phrase registry). Throws loudly if a content regeneration
/// renames the card, so this file can never silently pass on a corpus it
/// no longer describes.
HandbookUnit _unit(String id) {
  for (final doc in kBarrioTrainingDocs.values) {
    for (final chapter in doc.chapters) {
      for (final unit in chapter.units) {
        if (unit.id == id) return unit;
      }
    }
  }
  throw StateError(
      'probe card $id no longer exists; re-pick a card and re-author the '
      'expected phrase list from the live body');
}

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

/// A key-term emphasis span: bold + tealInk with no background wash.
/// Distinct from the search highlight (tealWarm background), the numeric
/// pop (the manual's accent colour) and the quiz answer span (tealDeep,
/// w600).
bool _isKeyTermSpan(TextSpan s) =>
    s.style?.color == BarrioColors.tealInk &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

/// The emphasized substrings the reader actually sees on the pumped
/// card, in reading order.
///
/// Only [RichText]s whose plain text is one of the card's rendered body
/// chunks are considered, so the card title and chrome can never be
/// mistaken for body emphasis. The chunk list comes from
/// [chunksForBody], the single parse the card itself renders off.
List<String> _emphasized(WidgetTester tester, HandbookUnit unit) {
  final chunks = chunksForBody(unit.body).map((c) => c.text).toSet();
  final out = <String>[];
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    if (!chunks.contains(rt.text.toPlainText())) continue;
    for (final span in _flatten(rt.text)) {
      if (_isKeyTermSpan(span) && (span.text ?? '').isNotEmpty) {
        out.add(span.text!);
      }
    }
  }
  return out;
}

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = const Size(390, 3600);
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

/// What the key-phrase tier would emit for [phrases] on [unit], composed
/// the way `handbook_lesson_card.dart` `_composeChunk` composes it: the
/// numeric tier first, then quiz answer evidence, then key phrases with
/// both handed in as `blockedRanges`, threading one `alreadyUsed` set
/// across the card's chunks in reading order.
///
/// Used ONLY by the last group, to show a rule-breaking phrase produces
/// nothing. The render probes above go through the real widget instead,
/// so this mirror is never what proves the shipped data works.
List<String> _wouldRender(HandbookUnit unit, List<String> phrases) {
  final evidence = barrioAnswerEvidenceForUnit(unit.id);
  final used = <String>{};
  final out = <String>[];
  for (final chunk in chunksForBody(unit.body)) {
    final text = chunk.text;
    final numerics = BarrioNumericHighlight.matchesIn(text);
    final numericRanges = [
      for (final n in numerics) [n.start, n.end]
    ];
    final answerRanges = <List<int>>[];
    for (final phrase in evidence) {
      if (phrase.isEmpty) continue;
      final idx = text.indexOf(phrase);
      if (idx < 0) continue;
      final range = [idx, idx + phrase.length];
      final blocked = numericRanges
          .any((r) => range[0] < r[1] && range[1] > r[0]);
      if (!blocked) answerRanges.add(range);
    }
    for (final m in BarrioKeyTermHighlight.matchesIn(
      text,
      phrases,
      alreadyUsed: used,
      blockedRanges: [...numericRanges, ...answerRanges],
    )) {
      out.add(text.substring(m.start, m.end));
    }
  }
  return out;
}

void main() {
  group('render proof: the authored phrases really light up', () {
    testWidgets('Latin American Dishes, PICO DE GALLO: exactly its own six '
        'phrases render emphasized, alongside the quiz answer span',
        (tester) async {
      final unit = _unit(_dishesUnitId);
      await _pumpCard(tester, unit);
      expect(_emphasized(tester, unit), _dishesExpected);
    });

    testWidgets('Latin American Ingredients, SHISHITO PEPPER: exactly its '
        'own six phrases render, around the live numeric pop',
        (tester) async {
      final unit = _unit(_ingredientsUnitId);
      await _pumpCard(tester, unit);
      expect(_emphasized(tester, unit), _ingredientsExpected);
    });

    testWidgets('Push Schedule, Releasing a Shift: exactly its own six '
        'phrases render across prose and a numbered-list block',
        (tester) async {
      final unit = _unit(_pushUnitId);
      await _pumpCard(tester, unit);
      expect(_emphasized(tester, unit), _pushExpected);
    });

    testWidgets('verbatim law: the visible body text is byte-identical to '
        'the source body on all three probe cards', (tester) async {
      for (final id in [_dishesUnitId, _ingredientsUnitId, _pushUnitId]) {
        final unit = _unit(id);
        await _pumpCard(tester, unit);
        final rendered = <String>[];
        final chunks = chunksForBody(unit.body).map((c) => c.text).toList();
        for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
          final plain = rt.text.toPlainText();
          if (chunks.contains(plain)) rendered.add(plain);
        }
        expect(rendered, chunks,
            reason: '$id: styling only, never a changed word');
      }
    });
  });

  group('fallback proof: an unauthored card in these manuals still renders '
      'nothing', () {
    testWidgets('ENSALADA has no authored entry and shows no emphasis',
        (tester) async {
      final unit = _unit(_unauthoredDishesUnitId);
      // The fallback these manuals take: they are uncurated, so the
      // per-manual list is empty and an unauthored card highlights
      // nothing. Asserted through the FALLBACK lookup, which is a
      // different path from the per-card registry under test.
      //
      // Honest note from red-proofing: this particular card cannot be
      // made to fail by authoring it, because its entire one-sentence
      // body is already the chapter quiz's answer evidence and the
      // answer tier outranks key phrases. That is exactly why it
      // carries no entry. The Pay Stubs probe below is the
      // mutation-sensitive half of this pair.
      expect(barrioKeyTermsForUnit(_unauthoredDishesUnitId), isEmpty);
      await _pumpCard(tester, unit);
      expect(_emphasized(tester, unit), isEmpty,
          reason: 'partial coverage must not change an unauthored card');
    });

    testWidgets('Pay Stubs has no authored entry and shows no emphasis',
        (tester) async {
      final unit = _unit(_unauthoredPushUnitId);
      expect(barrioKeyTermsForUnit(_unauthoredPushUnitId), isEmpty);
      await _pumpCard(tester, unit);
      expect(_emphasized(tester, unit), isEmpty);
    });
  });

  group('scope: these three manuals host no tap-to-define term links', () {
    test('the two glossaries SOURCE the term registry and the SOP is '
        'neither source nor host, so no term link can eat a phrase', () {
      // Verified against the constants rather than asserted from memory:
      // the glossary titles supply the registry, and the hosts are the
      // culinary manuals. `training_doc_screen.dart` gates onTermTap on
      // exactly kHostManualIds.
      expect(BarrioTermLinks.kSourceManualIds,
          containsAll(<String>['training_latin_dishes',
            'training_latin_ingredients']));
      for (final docId in <String>[
        'training_latin_dishes',
        'training_latin_ingredients',
        'training_push_sop',
      ]) {
        expect(BarrioTermLinks.kHostManualIds.contains(docId), isFalse,
            reason: '$docId must not be a term-link host');
      }
      // And the registry really is populated, so the check above is not
      // vacuously true on an empty term set.
      expect(BarrioTermLinks.registry(), isNotEmpty);
    });
  });

  group('the rules are load-bearing (real probe cards, bad phrases)', () {
    test('a phrase reaching into the numeric pop renders NOTHING', () {
      final unit = _unit(_ingredientsUnitId);
      // '10%' is claimed whole by the numeric tier on this real card.
      expect(BarrioNumericHighlight.matchesIn(unit.body), isNotEmpty,
          reason: 'the probe card must really carry a numeric pop');
      expect(_wouldRender(unit, <String>['about 10% of these peppers']),
          isEmpty);
      // The shipped phrase that starts just past it does render.
      expect(_wouldRender(unit, <String>[_ingredientsExpected[4]]),
          <String>[_ingredientsExpected[4]]);
    });

    test('a phrase overlapping quiz answer evidence renders NOTHING', () {
      final unit = _unit(_dishesUnitId);
      final evidence = barrioAnswerEvidenceForUnit(_dishesUnitId);
      expect(evidence, isNotEmpty,
          reason: 'the probe card must really back a quiz question');
      expect(_wouldRender(unit, <String>[evidence.first]), isEmpty);
    });

    test('a phrase spanning a paragraph break renders NOTHING', () {
      final unit = _unit(_pushUnitId);
      final chunks = chunksForBody(unit.body);
      final straddle = '${chunks[0].text} ${chunks[1].text}';
      expect(unit.body.contains(chunks[0].text), isTrue);
      expect(_wouldRender(unit, <String>[straddle]), isEmpty);
    });

    test('two phrases claiming the same words: only the first renders', () {
      final unit = _unit(_dishesUnitId);
      expect(
        _wouldRender(unit, <String>[
          'vibrant and fresh Mexican',
          'fresh Mexican condiment',
        ]),
        <String>['vibrant and fresh Mexican'],
        reason: 'the fragmentation shape the per-manual lists produce',
      );
    });

    test('a phrase that is not verbatim renders NOTHING', () {
      final unit = _unit(_dishesUnitId);
      expect(_wouldRender(unit, <String>['a fresh Mexican relish']), isEmpty);
    });

    test('the mirror agrees with the widget on the shipped data', () {
      // Ties the last group back to the render probes: on all three
      // probe cards the composed mirror emits exactly the same list the
      // pumped card emphasizes, so a NOTHING above really means nothing
      // on screen.
      expect(_wouldRender(_unit(_dishesUnitId), _dishesExpected),
          _dishesExpected);
      expect(_wouldRender(_unit(_ingredientsUnitId), _ingredientsExpected),
          _ingredientsExpected);
      expect(_wouldRender(_unit(_pushUnitId), _pushExpected), _pushExpected);
    });
  });
}
