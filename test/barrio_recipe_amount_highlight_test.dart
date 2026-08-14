// A recipe card's amounts are one treatment, and no line loses its words
// to a tier collision (REC-7, 2026-08-14).
//
// THE DEFECT THIS GUARDS. On the Aji Amarillo Dressing card the reader
// accented '500mL', '50ml' and '10g' and left '1 Jar', '2 Stalks', '4
// Cloves', '4' and '¼' plain, because the general number+unit matcher in
// `barrio_numeric_highlight.dart` only knows units it lists. Three lines
// out of nine is what the operator called random. The fix is a tier that
// styles exactly the amounts the committed ingredient data names, ABOVE
// the numeric pops, painting the same style so nothing that popped before
// changes and everything that did not joins it.
//
// WHY THE TIER COLLISION NEEDS ITS OWN GUARDS. The reader's tiers run
// search wash > term links > ingredient amounts > numeric pops > quiz
// answer evidence > key terms, and a LOWER tier overlapping a higher one
// is dropped WHOLE with no error: the emphasis just never appears. That
// has cost this repo a real bug before (a numeric span swallowed its unit
// word, so a digit-free phrase beside it silently rendered nothing), which
// is why `test/barrio_card_key_sets_test.dart` exists. Adding a tier that
// claims '500mL' while the numeric tier also claims '500mL' is exactly
// that shape of change, so the three facts the precedence decision rests
// on are re-derived here from the shipped content rather than assumed:
//
//   1. no numeric token PARTIALLY overlaps an amount (so the numeric tier
//      only ever loses exact duplicates it would have drawn identically),
//   2. recipe cards carry no key terms and no quiz answer evidence (so
//      nothing below the new tier can be starved by it),
//   3. recipe ingredient cards DO carry method prose with numeric facts
//      in them (so turning the numeric tier off for recipe cards, the
//      other way this could have been done, would have lost real pops).
//
// HOW THIS STAYS AN HONEST GUARD (see
// `feedback_negative_controls_can_be_vacuous`). Every expected amount span
// below is located here, by finding the ingredient line in the card body
// and then the amount inside that line, using nothing from
// `BarrioRecipeAmountHighlight`. The rendered sweep compares that
// independent set against what the widget actually painted, as a multiset,
// so a missing amount and an extra one both fail. Every sweep counts what
// it touched and fails on zero.
//
// The numeric matcher IS used as the reference for "what the other manuals
// popped before", which is a comparison against code the renderer also
// calls. That is deliberate and limited: this slice does not touch
// `barrio_numeric_highlight.dart`, `test/barrio_numeric_highlight_test.dart`
// guards it independently, and the claim being made here is only that the
// new tier did not change what that matcher's output renders as.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_ingredients.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_recipe_amount_highlight.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

const String _kRecipesDocId = 'training_recipes';

/// Tall enough that every bullet of every recipe card is laid out, so the
/// sweep sees the whole card rather than the first screenful.
const Size _kTallPhone = Size(390, 3600);

/// Every unit of [docId] in reading order.
List<HandbookUnit> _unitsOf(String docId) => <HandbookUnit>[
      for (final chapter in kBarrioTrainingDocs[docId]!.chapters)
        ...chapter.units,
    ];

/// The recipe cards that carry an ingredient list, in reading order.
List<HandbookUnit> _ingredientCards() => <HandbookUnit>[
      for (final unit in _unitsOf(_kRecipesDocId))
        if (barrioRecipeIngredientsForUnit(unit.id).isNotEmpty) unit,
    ];

/// One [start, end) span of a card body.
class _Span {
  final int start;
  final int end;
  const _Span(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is _Span && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start,$end)';
}

/// Where every ingredient amount of [lines] sits inside [text], worked out
/// here rather than asked of the code under test.
///
/// The line is found first and the amount is found inside it, which is the
/// only way a bare '4' can be pinned to its own line. Both halves rest on
/// facts `test/barrio_recipe_ingredients_test.dart` proves against the
/// live document: `raw` is an exact substring of the body, and `amount` is
/// an exact substring of `raw`.
List<_Span> _expectedAmountSpans(String text, List<BarrioRecipeIngredient> lines) {
  final out = <_Span>[];
  for (final line in lines) {
    final amount = line.amount;
    if (amount == null || amount.isEmpty) continue;
    var from = 0;
    while (from <= text.length - line.raw.length) {
      final lineAt = text.indexOf(line.raw, from);
      if (lineAt < 0) break;
      final lineEnd = lineAt + line.raw.length;
      final beforeOk = lineAt == 0 || !_isWordChar(text[lineAt - 1]);
      final afterOk = lineEnd == text.length || !_isWordChar(text[lineEnd]);
      if (beforeOk && afterOk) {
        final at = text.indexOf(amount, lineAt);
        if (at >= 0 && at + amount.length <= lineEnd) {
          out.add(_Span(at, at + amount.length));
        }
      }
      from = lineEnd;
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

bool _isWordChar(String ch) => RegExp(r'[0-9A-Za-z]').hasMatch(ch);

/// Every rendered chunk of [unit]'s body, byte-identical to the strings
/// the card hands to its `Text` widgets.
List<String> _chunksOf(HandbookUnit unit) => <String>[
      for (final block in barrioBodyBlocks(unit.body))
        for (final row in block.rows)
          for (final cell in row.cells) cell.text,
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

/// The style the reader paints a numeric fact pop AND an ingredient amount
/// in: bold, the manual's accent, no background wash. One style for both
/// is the point of the slice, so this predicate deliberately cannot tell
/// them apart.
bool _isAccented(TextSpan s, Color accent) =>
    s.style?.color == accent &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

/// What one card actually painted: the accented run texts, and the plain
/// text of every body chunk on screen.
class _Painted {
  final List<String> accented;
  final List<String> chunkTexts;
  const _Painted(this.accented, this.chunkTexts);
}

/// Reads [unit]'s rendered body back off the screen.
///
/// Only `RichText` widgets whose whole plain text IS one of the card's body
/// chunks are read, so a title, a badge or the calculator button can never
/// be counted as body emphasis.
_Painted _readBody(WidgetTester tester, HandbookUnit unit, Color accent) {
  final chunks = _chunksOf(unit).toSet();
  final accented = <String>[];
  final seenChunks = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final plain = rich.text.toPlainText();
    if (!chunks.contains(plain)) continue;
    seenChunks.add(plain);
    for (final span in _flatten(rich.text)) {
      final text = span.text;
      if (text == null || text.isEmpty) continue;
      if (_isAccented(span, accent)) accented.add(text);
    }
  }
  return _Painted(accented, seenChunks);
}

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = _kTallPhone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HandbookLessonCard(unit: unit),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// A multiset comparison that reports what is missing and what is extra,
/// which is the difference between a useful failure and 'lists differ'.
void _expectSameMultiset(
  List<String> got,
  List<String> want, {
  required String reason,
}) {
  final gotSorted = <String>[...got]..sort();
  final wantSorted = <String>[...want]..sort();
  if (gotSorted.toString() == wantSorted.toString()) return;
  final missing = <String>[...wantSorted];
  final extra = <String>[];
  for (final item in gotSorted) {
    if (!missing.remove(item)) extra.add(item);
  }
  fail('$reason\n  missing: $missing\n  extra: $extra\n'
      '  got: $gotSorted\n  want: $wantSorted');
}

void main() {
  group('the corpus this suite sweeps is real', () {
    test('the Recipes manual is registered and carries ingredient cards',
        () {
      expect(kBarrioTrainingDocs[_kRecipesDocId], isNotNull,
          reason: 'the manual under test is not registered');
      final cards = _ingredientCards();
      expect(cards.length, greaterThan(25),
          reason: 'only ${cards.length} ingredient cards were found, so '
              'every sweep below would prove nothing');
      expect(kBarrioTrainingAccents[_kRecipesDocId], isNotNull,
          reason: 'the manual has no identity colour, so the rendered '
              'sweeps have nothing to look for');
    });

    test('the manual really mixes amounts the numeric matcher sees with '
        'amounts it does not', () {
      // THE WHOLE PREMISE. If the general matcher already saw every
      // amount, this slice would be pointless and every guard below would
      // pass without meaning anything.
      var seen = 0;
      var unseen = 0;
      final unseenExamples = <String>{};
      for (final lines in kBarrioRecipeIngredients.values) {
        for (final line in lines) {
          final amount = line.amount;
          if (amount == null) continue;
          final matches = BarrioNumericHighlight.matchesIn(amount);
          final covered = matches.any((m) => m.end - m.start == amount.length);
          if (covered) {
            seen += 1;
          } else {
            unseen += 1;
            unseenExamples.add(amount);
          }
        }
      }
      expect(seen, greaterThan(50),
          reason: 'only $seen amounts were already popped, so the claim '
              'that nothing visible changes for them is untested');
      expect(unseen, greaterThan(30),
          reason: 'only $unseen amounts were left plain, so the defect the '
              'operator reported is not in this corpus');
      // Hand-read off the Aji Amarillo Dressing card: these are amounts
      // the reader used to leave plain.
      for (final amount in <String>['1 Jar', '2 Stalks', '4 Cloves', '¼']) {
        expect(unseenExamples, contains(amount),
            reason: '"$amount" is one of the amounts the operator saw go '
                'unaccented; it is no longer in the corpus, so the fixture '
                'this suite was written against has moved');
      }
    });
  });

  group('the amount matcher finds an amount where its own line sits', () {
    test('an amount at the front of a line', () {
      const line = BarrioRecipeIngredient(
        raw: '500mL Olive Oil',
        name: 'Olive Oil',
        amount: '500mL',
        quantity: 500,
        unit: 'mL',
      );
      final got = BarrioRecipeAmountHighlight.matchesIn(
        '500mL Olive Oil',
        const <BarrioRecipeIngredient>[line],
      );
      expect(got, hasLength(1));
      expect(got.single.start, 0);
      expect(got.single.end, 5);
    });

    test('an amount that is not at the front of its line', () {
      // The one line of the manual written the other way round.
      const line = BarrioRecipeIngredient(
        raw: 'Lime 300mL',
        name: 'Lime',
        amount: '300mL',
        quantity: 300,
        unit: 'mL',
      );
      final got = BarrioRecipeAmountHighlight.matchesIn(
        'Lime 300mL',
        const <BarrioRecipeIngredient>[line],
      );
      expect(got, hasLength(1));
      expect('Lime 300mL'.substring(got.single.start, got.single.end),
          '300mL');
    });

    test('a bare number is pinned to its own line, never found elsewhere',
        () {
      // '4' would match in four places if the amount were searched for on
      // its own. It is searched for inside its line, so it matches once.
      const line = BarrioRecipeIngredient(
        raw: '4 Juiced Limes',
        name: 'Juiced Limes',
        amount: '4',
        quantity: 4,
      );
      const text = '4 Juiced Limes, 4 of them, quartered into 4';
      final got = BarrioRecipeAmountHighlight.matchesIn(
        text,
        const <BarrioRecipeIngredient>[line],
      );
      expect(got, hasLength(1));
      expect(got.single.start, 0);
      expect(got.single.end, 1);
    });

    test('a short line found inside a longer one is not an amount', () {
      // '30g Salt' sits inside '130g Salt'. Styling it would accent '30g'
      // one character into a different number.
      const line = BarrioRecipeIngredient(
        raw: '30g Salt',
        name: 'Salt',
        amount: '30g',
        quantity: 30,
        unit: 'g',
      );
      expect(
        BarrioRecipeAmountHighlight.matchesIn(
          '130g Salt',
          const <BarrioRecipeIngredient>[line],
        ),
        isEmpty,
      );
      // And the real line still matches when it really is the line.
      expect(
        BarrioRecipeAmountHighlight.matchesIn(
          '30g Salt',
          const <BarrioRecipeIngredient>[line],
        ),
        hasLength(1),
      );
    });

    test('an amount overlapping a higher tier is dropped whole', () {
      const line = BarrioRecipeIngredient(
        raw: '500mL Olive Oil',
        name: 'Olive Oil',
        amount: '500mL',
        quantity: 500,
        unit: 'mL',
      );
      expect(
        BarrioRecipeAmountHighlight.matchesIn(
          '500mL Olive Oil',
          const <BarrioRecipeIngredient>[line],
          blockedRanges: <List<int>>[
            <int>[3, 8], // a search wash straddling the end of the amount
          ],
        ),
        isEmpty,
      );
    });

    test('a card with no ingredient lines gets nothing', () {
      // The guard that keeps the other 25 manuals out of this tier.
      expect(
        BarrioRecipeAmountHighlight.matchesIn(
          '500mL Olive Oil and 10g of Ginger',
          const <BarrioRecipeIngredient>[],
        ),
        isEmpty,
      );
    });
  });

  group('the facts the precedence decision rests on', () {
    test('no numeric token partially overlaps an ingredient amount', () {
      // THE COLLISION CHECK. A numeric token wholly inside an amount is an
      // exact duplicate the amount tier redraws in the same style, so
      // dropping it costs nothing. A token wholly outside is untouched. A
      // token that STRADDLES an amount boundary would be dropped and its
      // outside half would lose its pop with no error, which is the
      // failure this whole file exists to make impossible.
      var cards = 0;
      var inside = 0;
      var outside = 0;
      for (final unit in _ingredientCards()) {
        final lines = barrioRecipeIngredientsForUnit(unit.id);
        cards += 1;
        for (final chunk in _chunksOf(unit)) {
          final amounts = _expectedAmountSpans(chunk, lines);
          for (final m in BarrioNumericHighlight.matchesIn(chunk)) {
            final within = amounts
                .any((a) => m.start >= a.start && m.end <= a.end);
            final straddles = amounts.any((a) =>
                m.start < a.end && m.end > a.start &&
                !(m.start >= a.start && m.end <= a.end));
            expect(straddles, isFalse,
                reason: '${unit.id}: the numeric token '
                    '"${chunk.substring(m.start, m.end)}" straddles an '
                    'ingredient amount, so one of them would silently '
                    'render with no emphasis');
            if (within) {
              inside += 1;
            } else {
              outside += 1;
            }
          }
        }
      }
      expect(cards, greaterThan(25), reason: 'only $cards cards were swept');
      expect(inside, greaterThan(50),
          reason: 'only $inside numeric tokens sat inside an amount, so the '
              '"exact duplicate" half of the decision is untested');
      expect(outside, greaterThan(5),
          reason: 'only $outside numeric tokens sat outside an amount, so '
              'the "the numeric tier keeps running" half is untested');
    });

    test('recipe cards carry no key terms and no quiz answer evidence', () {
      // Nothing sits BELOW the new tier on a recipe card, so nothing below
      // it can be starved by it. Stated from the two lookups the reader
      // uses, so a future authoring pass that adds either one makes this
      // go red instead of quietly dropping spans.
      var cards = 0;
      for (final unit in _unitsOf(_kRecipesDocId)) {
        cards += 1;
        expect(barrioCardKeysForUnit(unit.id), isEmpty,
            reason: '${unit.id} now carries key terms, which sit below the '
                'ingredient-amount tier and can be dropped by it');
        expect(barrioAnswerEvidenceForUnit(unit.id), isEmpty,
            reason: '${unit.id} now carries quiz answer evidence, which '
                'sits below the ingredient-amount tier');
      }
      expect(cards, greaterThan(50),
          reason: 'only $cards cards of the manual were checked');
    });

    test('ingredient cards do carry method prose with numeric facts in it',
        () {
      // WHY THE NUMERIC TIER STAYS ON FOR RECIPE CARDS. The other way to
      // make the amounts consistent was to turn the general matcher off
      // for this manual. These cards are why that would have been wrong:
      // they mix an ingredient list and method prose in one card, and the
      // prose carries real facts ('cook for 15-20 minutes').
      final prose = <String>[];
      for (final unit in _ingredientCards()) {
        final lines = barrioRecipeIngredientsForUnit(unit.id);
        for (final chunk in _chunksOf(unit)) {
          final amounts = _expectedAmountSpans(chunk, lines);
          for (final m in BarrioNumericHighlight.matchesIn(chunk)) {
            final within = amounts
                .any((a) => m.start >= a.start && m.end <= a.end);
            if (!within) prose.add(chunk.substring(m.start, m.end));
          }
        }
      }
      expect(prose.length, greaterThan(5),
          reason: 'only ${prose.length} numeric facts sat outside an '
              'ingredient amount on a recipe card, so the reason the '
              'numeric tier stays on is not in this corpus');
      // Hand-read off the Aji Panca Glaze and Fish Taco cards.
      expect(prose, contains('15-20 minutes'));
      expect(prose, contains('30-40 seconds'));
    });
  });

  group('every recipe card paints every one of its amounts', () {
    testWidgets('and paints them all in the same treatment', (tester) async {
      // THE OPERATOR-FACING CLAIM. For every ingredient card of the manual
      // the accented runs on screen are exactly: every ingredient amount,
      // plus every numeric fact that is not inside one. Compared as a
      // multiset, so an amount that went missing and a stray accent that
      // appeared both fail, and the "same treatment" claim is carried by
      // the single [_isAccented] predicate: a run painted any other way is
      // not in `got` and the card fails naming the amount it lost.
      var cards = 0;
      var amountsChecked = 0;
      for (final unit in _ingredientCards()) {
        final lines = barrioRecipeIngredientsForUnit(unit.id);
        final accent = kBarrioTrainingAccents[_kRecipesDocId]!;
        await _pumpCard(tester, unit);
        final painted = _readBody(tester, unit, accent);

        final want = <String>[];
        for (final chunk in _chunksOf(unit)) {
          final amounts = _expectedAmountSpans(chunk, lines);
          for (final a in amounts) {
            want.add(chunk.substring(a.start, a.end));
          }
          amountsChecked += amounts.length;
          for (final m in BarrioNumericHighlight.matchesIn(chunk)) {
            final within = amounts
                .any((a) => m.start >= a.start && m.end <= a.end);
            if (!within) want.add(chunk.substring(m.start, m.end));
          }
        }
        _expectSameMultiset(painted.accented, want,
            reason: '${unit.id} did not accent its amounts the way the '
                'committed ingredient data says it should');
        expect(painted.chunkTexts, isNotEmpty,
            reason: '${unit.id} rendered no body chunk at all, so nothing '
                'above was actually checked');
        expect(tester.takeException(), isNull);
        cards += 1;
      }
      expect(cards, greaterThan(25),
          reason: 'only $cards recipe cards were swept');
      expect(amountsChecked, greaterThan(150),
          reason: 'only $amountsChecked amounts were checked across the '
              'manual, so the corpus collapsed');
    });

    testWidgets('and no ingredient line loses a character of its text',
        (tester) async {
      // THE TEXT-LOSS SWEEP. Emphasis is composed as a run of spans over
      // the chunk, so a composition bug loses WORDS, not just colour. Every
      // ingredient line's full text, and every ingredient name, is
      // asserted present in the rendered plain text of the card.
      var cards = 0;
      var linesChecked = 0;
      for (final unit in _ingredientCards()) {
        final lines = barrioRecipeIngredientsForUnit(unit.id);
        await _pumpCard(tester, unit);
        final rendered = <String>[
          for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
            rich.text.toPlainText(),
        ].join('\n');
        for (final line in lines) {
          expect(rendered, contains(line.raw),
              reason: '${unit.id} lost text from "${line.raw}"');
          expect(rendered, contains(line.name),
              reason: '${unit.id} lost the name "${line.name}"');
          final amount = line.amount;
          if (amount != null) {
            expect(rendered, contains(amount),
                reason: '${unit.id} lost the amount "$amount"');
          }
          linesChecked += 1;
        }
        expect(tester.takeException(), isNull);
        cards += 1;
      }
      expect(cards, greaterThan(25),
          reason: 'only $cards recipe cards were swept');
      expect(linesChecked, greaterThan(150),
          reason: 'only $linesChecked ingredient lines were checked');
    });
  });

  group('nothing else changed', () {
    testWidgets('a recipe method card paints only its numeric facts',
        (tester) async {
      // A method card sits in the same manual, gets the same accent, and
      // carries no ingredient lines. What it paints must still be exactly
      // what the general matcher finds.
      final methods = <HandbookUnit>[
        for (final unit in _unitsOf(_kRecipesDocId))
          if (barrioRecipeIngredientsForUnit(unit.id).isEmpty) unit,
      ];
      expect(methods.length, greaterThan(20),
          reason: 'only ${methods.length} method cards were found');
      final accent = kBarrioTrainingAccents[_kRecipesDocId]!;
      var withAPop = 0;
      var checked = 0;
      for (final unit in methods.take(12)) {
        await _pumpCard(tester, unit);
        final painted = _readBody(tester, unit, accent);
        final want = <String>[
          for (final chunk in _chunksOf(unit))
            for (final m in BarrioNumericHighlight.matchesIn(chunk))
              chunk.substring(m.start, m.end),
        ];
        _expectSameMultiset(painted.accented, want,
            reason: '${unit.id} is a method card and must paint exactly the '
                'numeric facts it always did');
        if (want.isNotEmpty) withAPop += 1;
        expect(tester.takeException(), isNull);
        checked += 1;
      }
      expect(checked, 12);
      expect(withAPop, greaterThan(2),
          reason: 'only $withAPop of the method cards swept had a numeric '
              'pop at all, so the comparison was mostly empty vs empty');
    });

    testWidgets('the other manuals paint exactly what they always painted',
        (tester) async {
      // The tier is gated on the card's own ingredient lookup, which is
      // empty everywhere outside the Recipes manual. Proved by rendering
      // rather than by reading the gate: for each sampled card the
      // accented runs must equal the general matcher's output exactly, so
      // one leaked amount span shows up as an extra.
      //
      // EVERY other manual is swept, not a hand-picked few: the tier is
      // wired into the one card widget the whole reader uses, so "no other
      // manual changed" is a claim about all of them. The doc list is read
      // off the registry, so a manual added later is swept without anyone
      // remembering to add it here.
      //
      // The cards WITHIN a manual are chosen rather than taken off the
      // front: most cards carry no number at all, and comparing empty
      // against empty would pass against a renderer that had stopped
      // painting. So each manual contributes up to four cards that really
      // do carry a numeric fact, plus up to two that carry none (the tier
      // must not invent one either).
      final otherDocIds = <String>[
        for (final docId in kBarrioTrainingDocs.keys)
          if (docId != _kRecipesDocId) docId,
      ];
      expect(otherDocIds.length, greaterThanOrEqualTo(24),
          reason: 'only ${otherDocIds.length} other manuals are registered, '
              'so this is not the sweep it claims to be');
      var manualsWithAPop = 0;
      var withAPop = 0;
      var withoutAPop = 0;
      var popsCompared = 0;
      for (final docId in otherDocIds) {
        final accent = kBarrioTrainingAccents[docId];
        expect(accent, isNotNull, reason: '$docId has no identity colour');
        final popped = <HandbookUnit>[];
        final quiet = <HandbookUnit>[];
        for (final unit in _unitsOf(docId)) {
          final facts = <String>[
            for (final chunk in _chunksOf(unit))
              for (final m in BarrioNumericHighlight.matchesIn(chunk))
                chunk.substring(m.start, m.end),
          ];
          if (facts.isNotEmpty && popped.length < 4) {
            popped.add(unit);
          } else if (facts.isEmpty && quiet.length < 2) {
            quiet.add(unit);
          }
        }
        if (popped.isNotEmpty) manualsWithAPop += 1;
        for (final unit in <HandbookUnit>[...popped, ...quiet]) {
          expect(barrioRecipeIngredientsForUnit(unit.id), isEmpty,
              reason: '${unit.id} is outside the Recipes manual');
          await _pumpCard(tester, unit);
          final painted = _readBody(tester, unit, accent!);
          final want = <String>[
            for (final chunk in _chunksOf(unit))
              for (final m in BarrioNumericHighlight.matchesIn(chunk))
                chunk.substring(m.start, m.end),
          ];
          _expectSameMultiset(painted.accented, want,
              reason: '${unit.id} no longer paints what the general numeric '
                  'matcher finds, so this slice changed a manual it must '
                  'not touch');
          if (want.isEmpty) {
            withoutAPop += 1;
          } else {
            withAPop += 1;
            popsCompared += want.length;
          }
          expect(tester.takeException(), isNull);
        }
      }
      expect(manualsWithAPop, greaterThan(15),
          reason: 'only $manualsWithAPop manuals contributed a card with a '
              'numeric fact, so most of the sweep was empty vs empty');
      expect(withAPop, greaterThan(40),
          reason: 'only $withAPop cards carrying a numeric fact were swept');
      expect(withoutAPop, greaterThan(20),
          reason: 'only $withoutAPop quiet cards were swept, so "the tier '
              'invents nothing" is barely tested');
      expect(popsCompared, greaterThan(100),
          reason: 'only $popsCompared numeric pops were compared, so the '
              'sweep would have passed against a renderer that had stopped '
              'painting them');
    });

    test('no card outside the Recipes manual can reach the tier at all', () {
      // The rendered sweep above covers the registered training manuals.
      // The Company Handbook is not one of them but renders through the
      // same card, so the GATE is asserted for every card of the app that
      // is not a recipe: the lookup the tier is switched on by answers
      // empty, and the matcher returns nothing when it does (proved
      // separately above, on a string full of amounts).
      var checked = 0;
      final outside = <HandbookUnit>[
        for (final chapter in handbookChapters) ...chapter.units,
        for (final entry in kBarrioTrainingDocs.entries)
          if (entry.key != _kRecipesDocId)
            for (final chapter in entry.value.chapters) ...chapter.units,
      ];
      expect(outside.length, greaterThan(400),
          reason: 'only ${outside.length} cards outside the Recipes manual '
              'were found, so the app content did not load');
      for (final unit in outside) {
        expect(barrioRecipeIngredientsForUnit(unit.id), isEmpty,
            reason: '${unit.id} is not a recipe but answers with ingredient '
                'lines, so the amount tier would switch on there');
        checked += 1;
      }
      expect(checked, outside.length);
      // And the Company Handbook really was in that list.
      expect(handbookChapters.expand((c) => c.units).length, greaterThan(20),
          reason: 'the Company Handbook contributed nothing to the sweep');
    });
  });
}
