// The recipe calculator's arithmetic, guarded against the three ways it
// could quietly hand a cook a wrong number:
//
//   1. a line that MAY NOT be multiplied gets multiplied anyway,
//   2. the multiplier comes off the wrong ingredient,
//   3. rounding turns a real amount into nothing.
//
// HOW THIS STAYS AN HONEST GUARD (see
// `feedback_negative_controls_can_be_vacuous`): no expected value below
// is produced by the code under test.
//
//   * The recipe tables in `_kExpected*` were READ OFF the committed
//     ingredient data by hand and typed in here, amount by amount. A
//     scaler that multiplies by the wrong factor, holds the wrong lines,
//     or reorders anything disagrees with a literal.
//   * The rounding cases are hand-written literals for hand-chosen
//     inputs, never a comparison of the formatter with itself.
//   * The corpus sweeps assert PROPERTIES ('a real amount never prints
//     as nothing', 'a held line never carries a scaled amount') whose
//     reference is the committed data plus this file's own arithmetic.
//   * Every loop carries a counter and every counter is asserted
//     non-zero, so a sweep that iterated nothing fails instead of
//     passing quietly.
//
// The tie between this data and the words a cook actually reads on the
// card is `test/barrio_recipe_ingredients_test.dart`; it is not
// re-proved here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_ingredients.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_models.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_scaler.dart';

/// Aji Amarillo Dressing: the first recipe card of the manual. Two
/// scalable lines besides the anchor, six lines held for four different
/// reasons.
const String _kDressing = 'training_recipes_c0_u0';

/// Braised Pork Belly: the only card whose anchor is written with a
/// decimal ('2.5kg'), so it proves a fractional anchor quantity.
const String _kPorkBelly = 'training_recipes_c26_u0';

/// Shrimp Stock: carries '1g Coriander Seeds' (an anchor of exactly 1)
/// and the manual's only 'range' hold.
const String _kShrimpStock = 'training_recipes_c31_u0';

/// Guacamole: the one card with exactly ONE scalable line, so scaling it
/// moves that line and nothing else.
const String _kGuacamole = 'training_recipes_c19_u0';

/// Cards with no scalable line at all.
const String _kSoftBoiledEggs = 'training_recipes_c22_u0';
const String _kTortillaChips = 'training_recipes_c30_u0';

/// Ten to the power of [exponent], written out here so the tolerance
/// check below borrows nothing from the code it is checking.
double _tenTo(int exponent) {
  var value = 1.0;
  for (var i = 0; i < exponent.abs(); i++) {
    value *= 10;
  }
  return exponent < 0 ? 1 / value : value;
}

/// The lines of one recipe card, or a failure naming the card.
List<BarrioRecipeIngredient> _linesOf(String unitId) {
  final lines = barrioRecipeIngredientsForUnit(unitId);
  expect(lines, isNotEmpty,
      reason: '$unitId carries no ingredient data, so every expectation '
          'written against it would pass without testing anything');
  return lines;
}

/// The line of [unitId] whose printed text is exactly [raw].
BarrioRecipeIngredient _lineNamed(String unitId, String raw) {
  final matches = _linesOf(unitId).where((line) => line.raw == raw).toList();
  expect(matches, hasLength(1),
      reason: '$unitId no longer carries exactly one line reading "$raw"; '
          'the hand-written table in this test is stale');
  return matches.single;
}

/// What [unitId] must read as, keyed by the line's printed text: the new
/// amount for a line that scales, null for a line that must not move.
void _expectRecipe(
  String unitId, {
  required String anchorRaw,
  required double amount,
  required double expectedMultiplier,
  required Map<String, String?> expected,
}) {
  final lines = _linesOf(unitId);
  final scale = barrioScaleRecipe(
    lines: lines,
    anchor: _lineNamed(unitId, anchorRaw),
    amount: amount,
  );

  expect(scale.multiplier, closeTo(expectedMultiplier, 1e-12),
      reason: '$unitId: $amount of "$anchorRaw" is $expectedMultiplier times '
          'the written recipe');

  // Nothing is dropped and nothing is reordered: a calculator that hid a
  // line it could not handle would be the dishonest failure.
  expect(scale.lines.map((entry) => entry.line.raw).toList(),
      lines.map((line) => line.raw).toList(),
      reason: '$unitId: every ingredient line must come back, in the '
          "card's own order");

  // The table has to name every line, or a silently changed amount could
  // slip past unasserted.
  expect(expected.keys.toSet(), lines.map((line) => line.raw).toSet(),
      reason: '$unitId: the hand-written table must cover every line of '
          'the card exactly once');

  for (final entry in scale.lines) {
    final want = expected[entry.line.raw];
    if (want == null) {
      expect(entry.scaled, isFalse,
          reason: '$unitId: "${entry.line.raw}" may not be multiplied, but '
              'the calculator produced ${entry.scaledText}');
      expect(entry.scaledText, isNull);
      expect(entry.scaledQuantity, isNull);
    } else {
      expect(entry.scaledText, want,
          reason: '$unitId: "${entry.line.raw}" at $expectedMultiplier times '
              'must read $want');
    }
  }
}

void main() {
  group('the corpus this suite sweeps is real', () {
    test('there are scalable lines, held lines, and every hold reason', () {
      // NON-VACUITY. Every sweep below is trivially true against an empty
      // or one-sided corpus, so prove both branches exist first.
      expect(kBarrioRecipeIngredients, isNotEmpty);
      final all = kBarrioRecipeIngredients.values
          .expand((lines) => lines)
          .toList(growable: false);
      expect(all.length, greaterThan(100),
          reason: 'the Recipes manual parses to hundreds of lines; a corpus '
              'this small means the data was gutted');

      final scalable = all.where((line) => line.scalable).length;
      final held = all.length - scalable;
      expect(scalable, greaterThan(0),
          reason: 'nothing to scale means the scaling sweeps prove nothing');
      expect(held, greaterThan(0),
          reason: 'nothing held means the hold sweeps prove nothing');

      // Each of the five reasons has to be reached by real data, or
      // `barrioHoldReason` is only tested against invented inputs.
      final reasons = all.map((line) => line.hold).whereType<BarrioIngredientHold>().toSet();
      expect(reasons, BarrioIngredientHold.values.toSet(),
          reason: 'a hold reason no live line uses is untested wording');
    });

    test('the cards this suite names are the shapes it claims', () {
      // Each hand-written table below depends on the card still having
      // the shape it was written against.
      expect(barrioScalableLines(_linesOf(_kGuacamole)), hasLength(1),
          reason: '$_kGuacamole is the one-scalable-line case');
      expect(_lineNamed(_kPorkBelly, '2.5kg Pork Belly ( Half a Slab)').quantity,
          2.5,
          reason: '$_kPorkBelly is the fractional-anchor case');
      expect(_lineNamed(_kShrimpStock, '1g Coriander Seeds').quantity, 1.0,
          reason: '$_kShrimpStock is the anchor-of-one case');
      for (final unitId in <String>[_kSoftBoiledEggs, _kTortillaChips]) {
        expect(barrioScalableLines(_linesOf(unitId)), isEmpty,
            reason: '$unitId is an every-line-is-held case');
      }
    });
  });

  group('the multiplier comes off the anchor the cook picked', () {
    test('anchoring the dressing on its oil at 1250mL is 2.5 times', () {
      // Hand-read from training_recipes_c0_u0 and multiplied by hand:
      // 500 -> 1250, 50 -> 125, 10 -> 25.
      _expectRecipe(
        _kDressing,
        anchorRaw: '500mL Olive Oil',
        amount: 1250,
        expectedMultiplier: 2.5,
        expected: const <String, String?>{
          '500mL Olive Oil': '1250mL',
          '1 Jar Aji Amarillo': null,
          '50ml Water ( Add to jar and shake)': '125ml',
          '2 Stalks Celery': null,
          '4 Cloves of garlic': null,
          '¼ Red Onion': null,
          '10g Ginger': '25g',
          '4 Juiced Limes': null,
          'Salt TT': null,
        },
      );
    });

    test('anchoring the SAME recipe on its ginger at 25g gives the SAME '
        'answer', () {
      // THE WRONG-ANCHOR CONTROL. 25g of ginger is also 2.5 times the
      // recipe. A scaler that read its multiplier off the first scalable
      // line would make this 25/500 = 0.05 and print 25mL of oil.
      _expectRecipe(
        _kDressing,
        anchorRaw: '10g Ginger',
        amount: 25,
        expectedMultiplier: 2.5,
        expected: const <String, String?>{
          '500mL Olive Oil': '1250mL',
          '1 Jar Aji Amarillo': null,
          '50ml Water ( Add to jar and shake)': '125ml',
          '2 Stalks Celery': null,
          '4 Cloves of garlic': null,
          '¼ Red Onion': null,
          '10g Ginger': '25g',
          '4 Juiced Limes': null,
          'Salt TT': null,
        },
      );
    });

    test('two anchors that mean different batches give different answers',
        () {
      // The pair above could both pass if the multiplier were pinned at
      // 2.5 somehow. 30g of ginger is 3 times the recipe, not 2.5.
      final lines = _linesOf(_kDressing);
      final scale = barrioScaleRecipe(
        lines: lines,
        anchor: _lineNamed(_kDressing, '10g Ginger'),
        amount: 30,
      );
      expect(scale.multiplier, closeTo(3.0, 1e-12));
      final oil = scale.lines
          .firstWhere((entry) => entry.line.raw == '500mL Olive Oil');
      expect(oil.scaledText, '1500mL',
          reason: '500mL of oil at 3 times the recipe is 1500mL');
    });

    test('an anchor written with a decimal scales the rest cleanly', () {
      // FRACTIONAL MULTIPLIER, from real data: 1kg of a 2.5kg slab is
      // 0.4 times the recipe. 250 -> 100, 200 -> 80, 50 -> 20, 60 -> 24,
      // 30 -> 12, 10 -> 4, all worked by hand.
      _expectRecipe(
        _kPorkBelly,
        anchorRaw: '2.5kg Pork Belly ( Half a Slab)',
        amount: 1,
        expectedMultiplier: 0.4,
        expected: const <String, String?>{
          '2.5kg Pork Belly ( Half a Slab)': '1kg',
          '250g Soy Sauce': '100g',
          '200g Orange Juice': '80g',
          '50g Ginger': '20g',
          '60g Green Onion': '24g',
          '30g Sesame Oil': '12g',
          '10g Black Peppercorn': '4g',
          '8 piece Star Anise': null,
          '6 piece Cinnamon Sticks': null,
          '1 Bunch Thyme': null,
        },
      );
    });

    test('an anchor of exactly 1 halves the recipe without rounding itself '
        'back up', () {
      // ANCHOR OF ONE, from real data. 0.5g of coriander is half the
      // stock. The anchor's own line is the trap: rounded to the source
      // line's zero decimals it would print '1g', which is the amount
      // the cook explicitly said they did NOT have.
      // Worked by hand: 7 -> 3.5, 670 -> 335, 335 -> 167.5 (prints 168 at
      // this magnitude), 150 -> 75, 170 -> 85, 120 -> 60, 50 -> 25,
      // 4 -> 2, 1 -> 0.5.
      _expectRecipe(
        _kShrimpStock,
        anchorRaw: '1g Coriander Seeds',
        amount: 0.5,
        expectedMultiplier: 0.5,
        expected: const <String, String?>{
          '2kg-2.5kg Shrimp Shells': null,
          '7L Water': '3.5L',
          '670g Tomato Quartered': '335g',
          '335g White Onion (Large Dice)': '168g',
          '150g Celery ( Large Dice)': '75g',
          '170g Cilantro Stems': '85g',
          '120g Salt': '60g',
          '50g Garlic Cloves': '25g',
          '4g Black Peppercorn': '2g',
          '1g Coriander Seeds': '0.5g',
          '8 Bay Leaves': null,
        },
      );
    });

    test('scaling the one scalable line of a recipe moves nothing else', () {
      // 750mL of lime juice is 1.5 times the guacamole, and every other
      // line of that card is held.
      _expectRecipe(
        _kGuacamole,
        anchorRaw: '500mL Lime Juice',
        amount: 750,
        expectedMultiplier: 1.5,
        expected: const <String, String?>{
          '15 Avocados': null,
          '500mL Lime Juice': '750mL',
          '5 jalapeños (Deseeded)': null,
          '1/4 Bunch cilantro': null,
          '1 Large Red Onion Small Dice': null,
          'L5S TT': null,
          'Salt TT': null,
        },
      );
    });
  });

  group('a held line is never multiplied', () {
    test('no held line anywhere in the manual carries a scaled amount, at '
        'any multiplier', () {
      // THE HOLD CONTROL, swept over the whole corpus rather than one
      // card, because the rule has to hold for reasons this suite never
      // names by hand.
      var heldSeen = 0;
      var scaledSeen = 0;
      final reasonsSeen = <BarrioIngredientHold>{};
      for (final entry in kBarrioRecipeIngredients.entries) {
        final lines = entry.value;
        final anchors = barrioScalableLines(lines);
        // Try every anchor the sheet would offer, at a batch up and a
        // batch down, plus the no-anchor case a fully held card gets.
        final attempts = <({BarrioRecipeIngredient? anchor, double? amount})>[
          (anchor: null, amount: null),
          for (final anchor in anchors) ...<({
            BarrioRecipeIngredient? anchor,
            double? amount
          })>[
            (anchor: anchor, amount: anchor.quantity! * 4),
            (anchor: anchor, amount: anchor.quantity! / 4),
          ],
        ];
        for (final attempt in attempts) {
          final scale = barrioScaleRecipe(
            lines: lines,
            anchor: attempt.anchor,
            amount: attempt.amount,
          );
          expect(scale.lines, hasLength(lines.length),
              reason: '${entry.key}: lines went missing');
          for (final scaled in scale.lines) {
            if (scaled.line.scalable) {
              scaledSeen += 1;
              expect(scaled.scaled, isTrue,
                  reason: '${entry.key}: "${scaled.line.raw}" is scalable but '
                      'the calculator refused to move it');
              continue;
            }
            heldSeen += 1;
            reasonsSeen.add(scaled.line.hold!);
            expect(scaled.scaledQuantity, isNull,
                reason: '${entry.key}: "${scaled.line.raw}" is held '
                    '(${scaled.line.hold}) but was multiplied to '
                    '${scaled.scaledQuantity}');
            expect(scaled.scaledText, isNull);
            expect(scaled.changed, isFalse);
          }
        }
      }
      expect(heldSeen, greaterThan(0),
          reason: 'no held line was reached, so this guard proved nothing');
      expect(scaledSeen, greaterThan(0),
          reason: 'no scalable line was reached, so this guard could pass '
              'against a calculator that scales nothing at all');
      expect(reasonsSeen, BarrioIngredientHold.values.toSet(),
          reason: 'the sweep must exercise all five hold reasons');
    });

    test('a recipe where every line is held scales to itself', () {
      for (final unitId in <String>[_kSoftBoiledEggs, _kTortillaChips]) {
        final lines = _linesOf(unitId);
        expect(barrioScalableLines(lines), isEmpty);
        final scale = barrioScaleRecipe(lines: lines);
        expect(scale.anchor, isNull);
        expect(scale.multiplier, 1.0);
        expect(scale.isAsWritten, isTrue);
        expect(scale.lines.map((entry) => entry.line.raw).toList(),
            lines.map((line) => line.raw).toList(),
            reason: '$unitId: a card with nothing to scale still shows every '
                'line it printed');
        expect(scale.lines.every((entry) => !entry.scaled), isTrue);
      }
    });

    test('every hold reason is its own sentence a cook can act on', () {
      final said = <String>{};
      for (final hold in BarrioIngredientHold.values) {
        final reason = barrioHoldReason(hold);
        expect(reason.trim(), isNotEmpty, reason: '$hold says nothing');
        expect(said.add(reason), isTrue,
            reason: '$hold repeats another reason word for word, so a cook '
                'cannot tell the two situations apart');
        expect(reason.contains('—'), isFalse,
            reason: 'UX no-em-dash law');
      }
      expect(said, hasLength(BarrioIngredientHold.values.length));
    });
  });

  group('rounding is kitchen sense', () {
    test('precision follows magnitude', () {
      // Hand-written pairs. The first is the operator-named case: a third
      // of 500mL must not read as sixteen digits.
      expect(barrioFormatRecipeAmount(500 / 3), '167');
      expect(barrioFormatRecipeAmount(1250), '1250');
      expect(barrioFormatRecipeAmount(166.4), '166');
      expect(barrioFormatRecipeAmount(33.333333333), '33.3');
      expect(barrioFormatRecipeAmount(10 / 3), '3.33');
      expect(barrioFormatRecipeAmount(99.99), '100');
      expect(barrioFormatRecipeAmount(0.125), '0.125');
      expect(barrioFormatRecipeAmount(0.0256), '0.026');
    });

    test('trailing zeros come off', () {
      expect(barrioFormatRecipeAmount(250), '250');
      expect(barrioFormatRecipeAmount(3.5), '3.5');
      expect(barrioFormatRecipeAmount(24.0), '24');
      expect(barrioFormatRecipeAmount(0.5), '0.5');
      expect(barrioFormatRecipeAmount(0.1), '0.1');
    });

    test('a real amount never rounds down to nothing', () {
      // THE ZERO CONTROL. Under the magnitude budget alone every one of
      // these prints '0', which tells a cook to leave the ingredient out.
      expect(barrioFormatRecipeAmount(0.2), '0.2');
      expect(barrioFormatRecipeAmount(0.02), '0.02');
      expect(barrioFormatRecipeAmount(0.004), '0.004');
      // Below the bottom rung the budget grows one digit at a time and
      // stops the moment the amount is visible at all.
      expect(barrioFormatRecipeAmount(0.00025), '0.0003');
      expect(barrioFormatRecipeAmount(0.0000004), '0.0000004');
      expect(barrioFormatRecipeAmount(0), '0',
          reason: 'nothing really is nothing');
    });

    test('no real line of the manual ever prints as nothing, at any batch '
        'size a kitchen would key in', () {
      // Property sweep. The reference is the committed quantity times
      // this file's own multiplier, and the check is on the STRING the
      // cook would read, parsed back with the language's own parser.
      const multipliers = <double>[
        0.01, 0.05, 0.1, 0.25, 1 / 3, 0.5, 1, 2, 7.5, 100,
      ];
      var checked = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in barrioScalableLines(entry.value)) {
          for (final multiplier in multipliers) {
            final exact = line.quantity! * multiplier;
            final printed = barrioFormatRecipeAmount(exact);
            final read = double.parse(printed);
            expect(read, greaterThan(0),
                reason: '${entry.key}: "${line.raw}" at $multiplier times is '
                    '$exact, which printed as "$printed"');
            // And it is still the same amount. The bar is the definition
            // of correct rounding, read off the STRING rather than off
            // the code: whatever precision it chose to show, the number
            // must be within half of its own last digit. That catches a
            // multiplier applied twice, a dropped digit, or a truncation,
            // at every magnitude, without this test having to know which
            // rung the rule picked.
            final shown = printed.contains('.')
                ? printed.length - printed.indexOf('.') - 1
                : 0;
            final tolerance = 0.5 * _tenTo(-shown);
            expect((read - exact).abs(), lessThanOrEqualTo(tolerance * 1.000001),
                reason: '${entry.key}: "${line.raw}" at $multiplier times is '
                    '$exact but printed as "$printed", which is further than '
                    'half of its own last digit');
            checked += 1;
          }
        }
      }
      expect(checked, greaterThan(500),
          reason: 'the sweep must actually cover the manual; $checked '
              'checks means the corpus or the multiplier list collapsed');
    });

    test('the multiplier is said the same way an amount is', () {
      expect(barrioFormatMultiplier(2.5), '2.5');
      expect(barrioFormatMultiplier(0.4), '0.4');
      expect(barrioFormatMultiplier(3), '3');
      expect(barrioFormatMultiplier(1 / 3), '0.333');
    });
  });

  group('an amount is spaced the way its own line spaced it', () {
    test('at one times the recipe every scalable line reprints its own '
        'opening', () {
      // A calculator that printed '1TSP' where the card printed '1 TSP'
      // is showing a cook something they did not read. At a multiplier of
      // 1 the scaled text must be the literal head of the source line,
      // except where the source wrote the number as a fraction glyph.
      var matched = 0;
      var glyphs = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        final lines = entry.value;
        final scale = barrioScaleRecipe(lines: lines);
        expect(scale.multiplier, 1.0);
        for (final scaled in scale.lines.where((line) => line.scaled)) {
          final text = scaled.scaledText!;
          if (RegExp(r'^[¼½¾⅓⅔]')
              .hasMatch(scaled.line.raw)) {
            // '1/2 Cup' written as a glyph cannot reprint its own
            // opening; it prints the decimal the parse read.
            glyphs += 1;
            expect(text.startsWith('0.5 '), isTrue,
                reason: '${entry.key}: "${scaled.line.raw}" should read as a '
                    'decimal amount, not "$text"');
            continue;
          }
          expect(scaled.line.raw.startsWith(text), isTrue,
              reason: '${entry.key}: at one times the recipe "${scaled.line.raw}" '
                  'must reprint as its own opening, not "$text"');
          matched += 1;
        }
      }
      expect(matched, greaterThan(100),
          reason: 'the sweep must cover the manual, not a handful of lines');
      expect(glyphs, greaterThan(0),
          reason: 'the fraction-glyph branch was never reached, so its '
              'assertion proved nothing');
    });
  });

  group('a half-typed number never shows a half-invented recipe', () {
    test('no amount, zero, a negative, and nonsense all leave the recipe as '
        'written', () {
      final lines = _linesOf(_kDressing);
      final anchor = _lineNamed(_kDressing, '500mL Olive Oil');
      for (final amount in <double?>[null, 0, -250, double.nan, double.infinity]) {
        final scale =
            barrioScaleRecipe(lines: lines, anchor: anchor, amount: amount);
        expect(scale.multiplier, 1.0,
            reason: 'an amount of $amount is not a batch size');
        expect(scale.isAsWritten, isTrue);
        final oil = scale.lines
            .firstWhere((entry) => entry.line.raw == '500mL Olive Oil');
        expect(oil.scaledText, '500mL');
        expect(oil.changed, isFalse,
            reason: 'the written amount is the new amount, so there is '
                'nothing to show as a "was"');
      }
    });

    test('a held line can never become the anchor', () {
      // The sheet only offers scalable lines, but the arithmetic must not
      // depend on the sheet behaving.
      final lines = _linesOf(_kDressing);
      final scale = barrioScaleRecipe(
        lines: lines,
        anchor: _lineNamed(_kDressing, '1 Jar Aji Amarillo'),
        amount: 3,
      );
      expect(scale.multiplier, 1.0,
          reason: 'three jars is not a batch size the recipe can be scaled '
              'by, so the recipe stays as written');
      final oil =
          scale.lines.firstWhere((entry) => entry.line.raw == '500mL Olive Oil');
      expect(oil.scaledText, '500mL');
    });

    test('the written amount is kept beside the new one whenever it '
        'changed', () {
      final lines = _linesOf(_kDressing);
      final scale = barrioScaleRecipe(
        lines: lines,
        anchor: _lineNamed(_kDressing, '500mL Olive Oil'),
        amount: 1250,
      );
      for (final entry in scale.lines.where((line) => line.scaled)) {
        expect(entry.changed, isTrue,
            reason: '"${entry.line.raw}" moved, so the cook must be able to '
                'see what it was');
      }
      expect(
        scale.lines
            .firstWhere((entry) => entry.line.raw == '10g Ginger')
            .originalText,
        '10g',
      );
    });
  });
}
