// The recipe calculator's arithmetic, guarded against the four ways it
// could quietly hand a cook a wrong number:
//
//   1. a line with a number does not move when the batch changes,
//   2. a line with NO number is given one,
//   3. the multiplier comes off the wrong ingredient,
//   4. rounding turns a real amount into nothing.
//
// HOW THIS STAYS AN HONEST GUARD (see
// `feedback_negative_controls_can_be_vacuous`): no expected value below is
// produced by the code under test.
//
//   * The recipe tables in the `_expectRecipe` calls were worked out BY
//     HAND from the committed ingredient lines, amount by amount. A scaler
//     that multiplies by the wrong factor, freezes the wrong lines, or
//     reorders anything disagrees with a literal.
//   * The rounding cases are hand-written literals for hand-chosen inputs,
//     never a comparison of the formatter with itself.
//   * The corpus sweeps assert PROPERTIES ('a real amount never prints as
//     nothing', 'a line with no number never gets one', 'the output is an
//     amount and never a sentence') whose reference is the committed data
//     plus this file's own arithmetic.
//   * Every loop carries a counter and every counter is asserted non-zero,
//     so a sweep that iterated nothing fails instead of passing quietly.
//
// The tie between this data and the words a cook actually reads on the
// card is `test/barrio_recipe_ingredients_test.dart`; it is not re-proved
// here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_ingredients.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_models.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_scaler.dart';

/// Aji Amarillo Dressing: a jar, stalks, cloves, a fraction glyph and a
/// line with no number at all, all on one card.
const String _kDressing = 'training_recipes_c0_u0';

/// Pickled Beets: carries '8-10lbs of beets', a range with its unit on the
/// high side only.
const String _kBeets = 'training_recipes_c3_u0';

/// Beef Skewer Topping: carries '235 Pumpkin Seeds', one of the two lines
/// whose unit the OPERATOR confirmed because the recipe prints none.
const String _kSkewerTopping = 'training_recipes_c8_u0';

/// Fish Taco: carries '½ Cup cornstarch', a fraction written as a glyph.
const String _kFishTaco = 'training_recipes_c16_u0';

/// Guacamole: carries '1/4 Bunch cilantro', a fraction written out.
const String _kGuacamole = 'training_recipes_c19_u0';

/// Soft Boiled Eggs: one line, '12 Eggs', and nothing else.
const String _kSoftBoiledEggs = 'training_recipes_c22_u0';

/// Pico de Gallo: carries 'Lime 300mL', the one line of the manual that
/// writes its amount after the ingredient, plus three lines with no
/// number.
const String _kPico = 'training_recipes_c30_u0';

/// Shrimp Stock: carries '2kg-2.5kg Shrimp Shells', a range with its unit
/// on BOTH sides.
const String _kShrimpStock = 'training_recipes_c31_u0';

/// Tortilla Chips: one line, '2 Bags Yellow Corn Tortilla'.
const String _kTortillaChips = 'training_recipes_c32_u0';

/// Pumpkin Seed Salsa: carries '9-10 Roma Tomatoes' (a range with no unit)
/// and the habanero line the parser deliberately leaves alone.
const String _kSeedSalsa = 'training_recipes_c27_u0';

/// Ten to the power of [exponent], written out here so the tolerance check
/// below borrows nothing from the code it is checking.
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
/// amount for a line that carries a number, null for a line that carries
/// none.
void _expectRecipe(
  String unitId, {
  required String anchorRaw,
  required double amount,
  required double expectedMultiplier,
  required Map<String, String?> expected,
}) {
  final lines = _linesOf(unitId);
  final anchor = _lineNamed(unitId, anchorRaw);
  final multiplier =
      barrioRecipeMultiplier(anchor: anchor, amount: amount);

  expect(multiplier, closeTo(expectedMultiplier, 1e-12),
      reason: '$unitId: $amount of "$anchorRaw" is $expectedMultiplier times '
          'the written recipe');

  // The table has to name every line exactly once, or a silently changed
  // amount could slip past unasserted.
  expect(lines.map((line) => line.raw).toSet(), expected.keys.toSet(),
      reason: '$unitId: the hand-written table must cover every line of the '
          'card exactly once');
  expect(lines, hasLength(expected.length),
      reason: '$unitId prints a line twice, so a table keyed by line text '
          'cannot pin every row');

  for (final line in lines) {
    final want = expected[line.raw];
    final got = barrioScaledAmount(line, multiplier);
    if (want == null) {
      expect(got, isNull,
          reason: '$unitId: "${line.raw}" carries no number, but the '
              'calculator produced $got');
    } else {
      expect(got, want,
          reason: '$unitId: "${line.raw}" at $expectedMultiplier times must '
              'read $want');
    }
  }
}

/// The shape of every string the calculator is allowed to produce: digits,
/// a fraction glyph, amount punctuation, and at most the unit word or two
/// a range repeats. Hand-written, so a sentence sneaking back into the
/// arithmetic layer fails against a rule this file states for itself.
final RegExp _kAmountShape = RegExp(
  r'^(?:\d+(?:\.\d+)?(?:/\d+)?|[¼½¾⅓⅔])\s?[A-Za-z]*'
  r'(?:-(?:\d+(?:\.\d+)?)\s?[A-Za-z]*)?$',
);

void main() {
  group('the corpus this suite sweeps is real', () {
    test('there are lines with numbers, lines without, and ranges', () {
      // NON-VACUITY. Every sweep below is trivially true against an empty
      // or one-sided corpus, so prove each branch exists first.
      expect(kBarrioRecipeIngredients, isNotEmpty);
      final all = kBarrioRecipeIngredients.values
          .expand((lines) => lines)
          .toList(growable: false);
      expect(all.length, greaterThan(100),
          reason: 'the Recipes manual parses to hundreds of lines; a corpus '
              'this small means the data was gutted');
      expect(all.where((line) => line.scales).length, greaterThan(100),
          reason: 'nothing to scale means the scaling sweeps prove nothing');
      expect(all.where((line) => !line.scales), isNotEmpty,
          reason: 'no line without a number means the leave-it-alone sweeps '
              'prove nothing');
      expect(all.where((line) => line.quantityHigh != null), isNotEmpty,
          reason: 'no range means the both-numbers-move sweeps prove '
              'nothing');
      expect(
          all.where((line) =>
              line.unit != null && !line.raw.contains(line.unit!)),
          isNotEmpty,
          reason: 'no line takes its unit from the operator, so the arm that '
              'appends one is never reached');
    });

    test('the cards this suite names are the shapes it claims', () {
      // Each hand-written table below depends on the card still having the
      // shape it was written against.
      expect(_lineNamed(_kBeets, '8-10lbs of beets').quantityHigh, 10.0,
          reason: '$_kBeets is the unit-on-the-high-side range case');
      expect(_lineNamed(_kShrimpStock, '2kg-2.5kg Shrimp Shells').quantityHigh,
          2.5,
          reason: '$_kShrimpStock is the unit-on-both-sides range case');
      expect(_lineNamed(_kSeedSalsa, '9-10 Roma Tomatoes').unit, isNull,
          reason: '$_kSeedSalsa is the range-with-no-unit case');
      expect(_lineNamed(_kPico, 'Lime 300mL').amount, '300mL',
          reason: '$_kPico is the amount-written-last case');
      expect(_lineNamed(_kFishTaco, '½ Cup cornstarch seasoned with salt')
          .quantity, 0.5,
          reason: '$_kFishTaco is the fraction-glyph case');
      expect(_lineNamed(_kGuacamole, '1/4 Bunch cilantro').quantity, 0.25,
          reason: '$_kGuacamole is the written-fraction case');
      final confirmed = _lineNamed(_kSkewerTopping, '235 Pumpkin Seeds');
      expect(confirmed.unit, 'g');
      expect(confirmed.raw.contains('g'), isFalse,
          reason: '$_kSkewerTopping is the unit-the-recipe-never-printed '
              'case, which only holds while the line prints no unit');
    });

    test('a range is not something to type an amount against, but every '
        'other numbered line is', () {
      // The sheet offers these lines. A range is two numbers, so an amount
      // typed against '8-10lbs' would not say which one it meant.
      var checked = 0;
      var rangesSkipped = 0;
      var blanksSkipped = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        final anchors = barrioAnchorLines(entry.value).toSet();
        for (final line in entry.value) {
          if (line.quantityHigh != null) {
            expect(anchors.contains(line), isFalse,
                reason: '${entry.key}: "${line.raw}" is a range');
            rangesSkipped += 1;
          } else if (!line.scales) {
            expect(anchors.contains(line), isFalse,
                reason: '${entry.key}: "${line.raw}" has no number');
            blanksSkipped += 1;
          } else {
            expect(anchors.contains(line), isTrue,
                reason: '${entry.key}: "${line.raw}" carries a number, so a '
                    'cook must be able to start from it');
            checked += 1;
          }
        }
      }
      expect(checked, greaterThan(100),
          reason: 'the offered-lines sweep covered $checked lines');
      expect(rangesSkipped, greaterThan(0),
          reason: 'the range branch was never reached');
      expect(blanksSkipped, greaterThan(0),
          reason: 'the no-number branch was never reached');
    });
  });

  group('every line with a number moves', () {
    test('the operator\'s own example: 2.4 times reads 4.8 Stalks', () {
      // THE POINT OF REC-6, from real data. 24g of ginger is 2.4 times the
      // dressing. Worked by hand: 500 -> 1200, 1 -> 2.4, 50 -> 120,
      // 2 -> 4.8, 4 -> 9.6, 0.25 -> 0.6, 10 -> 24, 4 -> 9.6.
      _expectRecipe(
        _kDressing,
        anchorRaw: '10g Ginger',
        amount: 24,
        expectedMultiplier: 2.4,
        expected: const <String, String?>{
          '500mL Olive Oil': '1200mL',
          '1 Jar Aji Amarillo': '2.4 Jar',
          '50ml Water ( Add to jar and shake)': '120ml',
          '2 Stalks Celery': '4.8 Stalks',
          '4 Cloves of garlic': '9.6 Cloves',
          '¼ Red Onion': '0.6',
          '10g Ginger': '24g',
          '4 Juiced Limes': '9.6',
          'Salt TT': null,
        },
      );
    });

    test('anchoring the same recipe on its oil gives the same answers', () {
      // THE WRONG-ANCHOR CONTROL. 1250mL of oil is 2.5 times the recipe. A
      // scaler that read its multiplier off the first line regardless
      // would make the ginger test above 24/500 and print 24mL of oil.
      _expectRecipe(
        _kDressing,
        anchorRaw: '500mL Olive Oil',
        amount: 1250,
        expectedMultiplier: 2.5,
        expected: const <String, String?>{
          '500mL Olive Oil': '1250mL',
          '1 Jar Aji Amarillo': '2.5 Jar',
          '50ml Water ( Add to jar and shake)': '125ml',
          '2 Stalks Celery': '5 Stalks',
          '4 Cloves of garlic': '10 Cloves',
          '¼ Red Onion': '0.625',
          '10g Ginger': '25g',
          '4 Juiced Limes': '10',
          'Salt TT': null,
        },
      );
    });

    test('two anchors that mean different batches give different answers',
        () {
      // The pair above could both pass if the multiplier were pinned
      // somehow. 30g of ginger is 3 times the recipe, not 2.4 or 2.5.
      final multiplier = barrioRecipeMultiplier(
        anchor: _lineNamed(_kDressing, '10g Ginger'),
        amount: 30,
      );
      expect(multiplier, closeTo(3.0, 1e-12));
      expect(
        barrioScaledAmount(
            _lineNamed(_kDressing, '500mL Olive Oil'), multiplier),
        '1500mL',
        reason: '500mL of oil at 3 times the recipe is 1500mL',
      );
      expect(
        barrioScaledAmount(
            _lineNamed(_kDressing, '2 Stalks Celery'), multiplier),
        '6 Stalks',
      );
    });

    test('a fraction written as a glyph scales as the number it means', () {
      // 18oz of cod is 3 times the taco. Worked by hand: 6 -> 18,
      // 0.5 -> 1.5, 1 -> 3, 2 -> 6. The glyph line is the point: '½ Cup'
      // reads '1.5 Cup', not '1½ Cup' and not '½ Cup' unchanged.
      _expectRecipe(
        _kFishTaco,
        anchorRaw: '6oz Cod , Bite sized cubes',
        amount: 18,
        expectedMultiplier: 3,
        expected: const <String, String?>{
          '6oz Cod , Bite sized cubes': '18oz',
          '½ Cup cornstarch seasoned with salt': '1.5 Cup',
          '1 cup slaw': '3 cup',
          '2 Tortillas': '6',
        },
      );
    });

    test('a fraction written out scales too', () {
      // 750mL of lime juice is 1.5 times the guacamole. Worked by hand:
      // 15 -> 22.5, 500 -> 750, 5 -> 7.5, 0.25 -> 0.375, 1 -> 1.5. The two
      // 'TT' lines have no number and stay exactly as the card wrote them.
      _expectRecipe(
        _kGuacamole,
        anchorRaw: '500mL Lime Juice',
        amount: 750,
        expectedMultiplier: 1.5,
        expected: const <String, String?>{
          '15 Avocados': '22.5',
          '500mL Lime Juice': '750mL',
          '5 jalapeños (Deseeded)': '7.5',
          '1/4 Bunch cilantro': '0.375 Bunch',
          '1 Large Red Onion Small Dice': '1.5',
          'L5S TT': null,
          'Salt TT': null,
        },
      );
    });

    test('an amount written after the ingredient scales like any other',
        () {
      // 600mL of lime is 2 times the pico. Worked by hand: 12 -> 24,
      // 3 -> 6, 300 -> 600, 0.25 -> 0.5. Three lines carry no number and
      // print exactly as the card printed them.
      _expectRecipe(
        _kPico,
        anchorRaw: 'Lime 300mL',
        amount: 600,
        expectedMultiplier: 2,
        expected: const <String, String?>{
          '12 Tomatoes': '24',
          '3 Banana Peppers Small Dice': '6',
          'One Large Onion Red Small Dice': null,
          'Lime 300mL': '600mL',
          'Salt TT': null,
          'L5S TT': null,
          '¼ Bunch Cilantro': '0.5 Bunch',
        },
      );
    });

    test('a unit the recipe never printed comes along with the number', () {
      // Worked by hand at 2 times: 470 -> 940, 235 -> 470, 180 -> 360
      // twice, 35 -> 70. The pumpkin seeds are the point: the card prints
      // '235 Pumpkin Seeds' with no unit at all, so the confirmed gram is
      // added after the number.
      _expectRecipe(
        _kSkewerTopping,
        anchorRaw: '470g Corn Nuts',
        amount: 940,
        expectedMultiplier: 2,
        expected: const <String, String?>{
          '470g Corn Nuts': '940g',
          '235 Pumpkin Seeds': '470 g',
          '180g Sunflower Seeds': '360g',
          '180g White/Black Sesame Seed (90g each)': '360g',
          '35g Maldon Salt': '70g',
        },
      );
    });

    test('the cook can start from the line whose unit was confirmed', () {
      // The same batch, read off the confirmed line instead. 470g of
      // pumpkin seeds is 2 times a 235 line, so every amount matches the
      // test above.
      _expectRecipe(
        _kSkewerTopping,
        anchorRaw: '235 Pumpkin Seeds',
        amount: 470,
        expectedMultiplier: 2,
        expected: const <String, String?>{
          '470g Corn Nuts': '940g',
          '235 Pumpkin Seeds': '470 g',
          '180g Sunflower Seeds': '360g',
          '180g White/Black Sesame Seed (90g each)': '360g',
          '35g Maldon Salt': '70g',
        },
      );
    });

    test('a one-line recipe of pure count scales', () {
      _expectRecipe(
        _kSoftBoiledEggs,
        anchorRaw: '12 Eggs',
        amount: 18,
        expectedMultiplier: 1.5,
        expected: const <String, String?>{'12 Eggs': '18'},
      );
    });

    test('a container count scales too', () {
      // 5 bags is 2.5 times a 2 bag recipe. The operator was shown that
      // this reads as a fractional container at other multipliers and
      // chose it anyway.
      _expectRecipe(
        _kTortillaChips,
        anchorRaw: '2 Bags Yellow Corn Tortilla',
        amount: 5,
        expectedMultiplier: 2.5,
        expected: const <String, String?>{
          '2 Bags Yellow Corn Tortilla': '5 Bags',
        },
      );
    });
  });

  group('a range scales on both of its numbers', () {
    test('a range with its unit on the high side', () {
      // 6L of water is 2 times the beets. Worked by hand: 8 and 10 both
      // double, 3 -> 6, 200 -> 400, 70 -> 140.
      _expectRecipe(
        _kBeets,
        anchorRaw: '3L Water',
        amount: 6,
        expectedMultiplier: 2,
        expected: const <String, String?>{
          '8-10lbs of beets': '16-20lbs',
          '3L Water': '6L',
          '200mL Red Wine Vinegar': '400mL',
          '70g Salt ( 1.75% weight of beets)': '140g',
        },
      );
    });

    test('a range with its unit on both sides keeps both', () {
      // 14L of water is 2 times the stock, so 2kg-2.5kg becomes 4kg-5kg
      // and the shape of the line survives.
      _expectRecipe(
        _kShrimpStock,
        anchorRaw: '7L Water',
        amount: 14,
        expectedMultiplier: 2,
        expected: const <String, String?>{
          '2kg-2.5kg Shrimp Shells': '4kg-5kg',
          '7L Water': '14L',
          '670g Tomato Quartered': '1340g',
          '335g White Onion (Large Dice)': '670g',
          '150g Celery ( Large Dice)': '300g',
          '170g Cilantro Stems': '340g',
          '120g Salt': '240g',
          '50g Garlic Cloves': '100g',
          '4g Black Peppercorn': '8g',
          '1g Coriander Seeds': '2g',
          '8 Bay Leaves': '16',
        },
      );
    });

    test('a range with no unit, and the one line left deliberately alone',
        () {
      // 375g of pumpkin seed is half the salsa. Worked by hand:
      // 750 -> 375, 210 -> 105, 9 and 10 -> 4.5 and 5, 225 -> 112.5 which
      // prints 113 at that magnitude, 135 -> 67.5, 90 -> 45, 42 -> 21,
      // 75 -> 37.5, 30 -> 15.
      //
      // The habanero line carries a parenthesised weight AND a count of
      // peppers, so no rule reads one without leaving the other lying. It
      // prints exactly as written, with nothing said about it.
      _expectRecipe(
        _kSeedSalsa,
        anchorRaw: '750g Pumpkin Seeds',
        amount: 375,
        expectedMultiplier: 0.5,
        expected: const <String, String?>{
          '750g Pumpkin Seeds': '375g',
          '210g Unhulled Seeds': '105g',
          '9-10 Roma Tomatoes': '4.5-5',
          '225g White Onion': '113g',
          '135g Lime Juice': '67.5g',
          '90g Orange Juice': '45g',
          '42g Cilantro': '21g',
          '(30g) 4-5 Habanero Peppers (deseeded and deribbed)': null,
          '75g Garlic': '37.5g',
          '30g Salt': '15g',
        },
      );
    });
  });

  group('a line with no number never gets one', () {
    test('no numberless line anywhere in the manual produces an amount, at '
        'any multiplier', () {
      // THE SWEEP, over the whole corpus rather than one card, because the
      // rule has to hold for lines this suite never names by hand.
      const multipliers = <double>[0.25, 0.5, 1, 2, 2.4, 7.5, 100];
      var blankSeen = 0;
      var numberedSeen = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          for (final multiplier in multipliers) {
            final got = barrioScaledAmount(line, multiplier);
            if (line.quantity == null) {
              expect(got, isNull,
                  reason: '${entry.key}: "${line.raw}" carries no number, '
                      'but at $multiplier times it produced "$got"');
              blankSeen += 1;
              continue;
            }
            expect(got, isNotNull,
                reason: '${entry.key}: "${line.raw}" carries a number but '
                    'the calculator refused to move it');
            numberedSeen += 1;
          }
        }
      }
      expect(blankSeen, greaterThan(0),
          reason: 'no numberless line was reached, so this guard proved '
              'nothing');
      expect(numberedSeen, greaterThan(500),
          reason: 'only $numberedSeen numbered checks ran, so the corpus or '
              'the multiplier list collapsed');
    });

    test('the multiplier is 1 for anything that is not a batch size', () {
      final anchor = _lineNamed(_kDressing, '500mL Olive Oil');
      for (final amount in <double?>[
        null,
        0,
        -250,
        double.nan,
        double.infinity,
      ]) {
        expect(barrioRecipeMultiplier(anchor: anchor, amount: amount), 1.0,
            reason: 'an amount of $amount is not a batch size');
      }
      expect(barrioRecipeMultiplier(anchor: null, amount: 500), 1.0,
          reason: 'with no ingredient picked there is nothing to scale from');
      expect(
        barrioRecipeMultiplier(
          anchor: _lineNamed(_kBeets, '8-10lbs of beets'),
          amount: 20,
        ),
        1.0,
        reason: 'a range is two numbers, so an amount typed against it does '
            'not say which one it meant',
      );
      expect(
        barrioRecipeMultiplier(
          anchor: _lineNamed(_kDressing, 'Salt TT'),
          amount: 20,
        ),
        1.0,
        reason: 'a line with no number cannot be a starting point',
      );
    });
  });

  group('the calculator only ever says an amount', () {
    test('every string it produces is an amount, never a sentence', () {
      // THE NO-VERBIAGE GUARD at the arithmetic layer (operator direction,
      // REC-6). The shape is stated in this file, by hand, so a hold
      // reason, a unit note, or any other prose reintroduced downstream
      // fails here rather than reaching a cook.
      const multipliers = <double>[0.5, 1, 2.4, 12];
      var checked = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          for (final multiplier in multipliers) {
            final got = barrioScaledAmount(line, multiplier);
            if (got == null) continue;
            expect(_kAmountShape.hasMatch(got), isTrue,
                reason: '${entry.key}: "${line.raw}" at $multiplier times '
                    'produced "$got", which is not an amount');
            checked += 1;
          }
        }
      }
      expect(checked, greaterThan(500),
          reason: 'only $checked strings were checked, so the corpus '
              'collapsed and this proved nothing');
    });

    test('the multiplier readout is a number', () {
      expect(barrioFormatMultiplier(2.5), '2.5');
      expect(barrioFormatMultiplier(0.4), '0.4');
      expect(barrioFormatMultiplier(3), '3');
      expect(barrioFormatMultiplier(1), '1');
      expect(barrioFormatMultiplier(1 / 3), '0.333');
      for (final multiplier in <double>[0.4, 1, 2.4, 100]) {
        expect(RegExp(r'^\d+(\.\d+)?$')
            .hasMatch(barrioFormatMultiplier(multiplier)), isTrue,
            reason: 'the readout must be digits, not words');
      }
    });
  });

  group('an amount is spaced and worded the way its own line wrote it', () {
    test('at one times the recipe every line reprints its own amount', () {
      // A calculator that printed '1TSP' where the card printed '1 TSP' is
      // showing a cook something they did not read. At a multiplier of 1
      // the amount is the literal text the line printed, with no exception
      // for a fraction (REC-7, 2026-08-14: the operator writes '¼ Red
      // Onion' and an untouched calculator has to say '¼' back), and the
      // only addition anywhere is a unit the operator confirmed that the
      // card itself does not print.
      var literal = 0;
      var operatorUnits = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          final amount = line.amount;
          if (amount == null) continue;
          final got = barrioScaledAmount(line, 1.0);
          final unit = line.unit;
          if (unit != null && !amount.contains(unit)) {
            operatorUnits += 1;
            expect(got, '$amount $unit',
                reason: '${entry.key}: "${line.raw}" prints no unit of its '
                    'own, so the confirmed unit is added after the number '
                    'the card printed');
            continue;
          }
          literal += 1;
          expect(got, amount,
              reason: '${entry.key}: at one times the recipe "${line.raw}" '
                  'must reprint its own amount, not "$got"');
        }
      }
      expect(literal, greaterThan(100),
          reason: 'the sweep must cover the manual, not a handful of lines');
      expect(operatorUnits, greaterThan(0),
          reason: 'the confirmed-unit branch was never reached, so its '
              'assertion proved nothing');
    });

    test('a fraction the operator wrote is still that fraction at one times '
        'the recipe', () {
      // NON-VACUITY FOR THE SWEEP ABOVE, and the defect REC-7 fixes. That
      // sweep would pass on a manual with no fractions in it at all, so
      // the fraction lines are named here by hand, read off the card
      // bodies, each one beside the decimal it used to print. Both halves
      // are asserted: the glyph is what shows, and the decimal is what
      // does not.
      const fractions = <String, String>{
        // amount as the card writes it : the decimal it must NOT print as
        '¼': '0.25',
        '½ Bunch': '0.5 Bunch',
        '½ Cup': '0.5 Cup',
        '1/4 Bunch': '0.25 Bunch',
        '¼ Bunch': '0.25 Bunch',
      };
      final seen = <String>{};
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          final amount = line.amount;
          if (amount == null) continue;
          final decimal = fractions[amount];
          if (decimal == null) continue;
          seen.add(amount);
          final got = barrioScaledAmount(line, 1.0);
          expect(got, amount,
              reason: '${entry.key}: "${line.raw}" is written as a fraction '
                  'and an untouched calculator must say it back that way');
          expect(got, isNot(decimal),
              reason: '${entry.key}: "${line.raw}" printed the decimal the '
                  'card never wrote');
        }
      }
      expect(seen, fractions.keys.toSet(),
          reason: 'the hand-written fraction table no longer matches the '
              'fractions the manual writes, so this guard proved nothing');
    });

    test('a fraction scaled off one times the recipe shows the number', () {
      // The other half of the one rule: untouched shows the recipe's own
      // text, scaled shows the number. No glyph is invented on the way
      // back, so twice a quarter onion is '0.5', not '½'.
      //
      // Hand-built lines, not read out of the manual, so the arithmetic is
      // checked against numbers written here.
      const quarter = BarrioRecipeIngredient(
        raw: '¼ Red Onion',
        name: 'Red Onion',
        amount: '¼',
        quantity: 0.25,
      );
      const halfCup = BarrioRecipeIngredient(
        raw: '½ Cup cornstarch',
        name: 'cornstarch',
        amount: '½ Cup',
        quantity: 0.5,
        unit: 'Cup',
      );
      // 0.25 x 2.4 = 0.6; 0.25 x 2 = 0.5; 0.5 x 3 = 1.5.
      expect(barrioScaledAmount(quarter, 2.4), '0.6');
      expect(barrioScaledAmount(quarter, 2), '0.5');
      expect(barrioScaledAmount(halfCup, 3), '1.5 Cup');
      // And at exactly one times, both are the card's own text again.
      expect(barrioScaledAmount(quarter, 1.0), '¼');
      expect(barrioScaledAmount(halfCup, 1.0), '½ Cup');
    });

    test('the number an empty box shows is the number the card wrote', () {
      // What the calculator puts in an untouched amount box. Hand-written
      // triples: the amount as the manual prints it, its unit, and the
      // number that opens it. The unit is not in the answer, because the
      // box shows it separately.
      const cases = <List<String?>>[
        <String?>['500mL', 'mL', '500'],
        <String?>['2 Stalks', 'Stalks', '2'],
        <String?>['¼', null, '¼'],
        <String?>['½ Cup', 'Cup', '½'],
        <String?>['1/4 Bunch', 'Bunch', '1/4'],
        <String?>['8-10lbs', 'lbs', '8'],
        <String?>['235', 'g', '235'],
      ];
      for (final row in cases) {
        final line = BarrioRecipeIngredient(
          raw: '${row[0]} Something',
          name: 'Something',
          amount: row[0],
          quantity: 1,
          unit: row[1],
        );
        expect(barrioWrittenNumber(line), row[2],
            reason: '"${row[0]}" opens with "${row[2]}"');
      }
      // A line with no amount has no number to show.
      expect(
        barrioWrittenNumber(
          const BarrioRecipeIngredient(raw: 'Salt TT', name: 'Salt TT'),
        ),
        isNull,
      );
    });

    test('every line of the manual opens its box with its own characters',
        () {
      // Swept, so a line shape nobody thought of cannot slip past the
      // hand-written cases above. The expected value is derived from the
      // line's own amount here, never asked of the scaler.
      final digitOrGlyph = RegExp(r'^(?:[¼½¾⅓⅔⅛⅜⅝⅞]|\d)');
      var checked = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          final amount = line.amount;
          final shown = barrioWrittenNumber(line);
          if (amount == null) {
            expect(shown, isNull, reason: '${entry.key}: "${line.raw}"');
            continue;
          }
          checked += 1;
          expect(shown, isNotNull, reason: '${entry.key}: "${line.raw}"');
          expect(amount.startsWith(shown!), isTrue,
              reason: '${entry.key}: "${line.raw}" opens its box with '
                  '"$shown", which is not how its amount "$amount" starts');
          expect(digitOrGlyph.hasMatch(shown), isTrue,
              reason: '${entry.key}: "$shown" is not a number');
        }
      }
      expect(checked, greaterThan(150),
          reason: 'only $checked lines were checked, so the corpus '
              'collapsed and this proved nothing');
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

    test('a count is not rounded to a whole thing', () {
      // The operator was shown this reading and chose it: 2 stalks at 2.4
      // times is 4.8 stalks, and how to round that is the cook's call.
      expect(barrioFormatRecipeAmount(2 * 2.4), '4.8');
      expect(barrioFormatRecipeAmount(1 * 2.5), '2.5');
      expect(barrioFormatRecipeAmount(4 * 2.4), '9.6');
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
      // Property sweep. The reference is the committed quantity times this
      // file's own multiplier, and the check is on the STRING the cook
      // would read, parsed back with the language's own parser.
      const multipliers = <double>[
        0.01, 0.05, 0.1, 0.25, 1 / 3, 0.5, 1, 2, 7.5, 100,
      ];
      var checked = 0;
      for (final entry in kBarrioRecipeIngredients.entries) {
        for (final line in entry.value) {
          for (final number in <double?>[line.quantity, line.quantityHigh]) {
            if (number == null) continue;
            for (final multiplier in multipliers) {
              final exact = number * multiplier;
              final printed = barrioFormatRecipeAmount(exact);
              final read = double.parse(printed);
              expect(read, greaterThan(0),
                  reason: '${entry.key}: "${line.raw}" at $multiplier times '
                      'is $exact, which printed as "$printed"');
              // And it is still the same amount. The bar is the definition
              // of correct rounding, read off the STRING rather than off
              // the code: whatever precision it chose to show, the number
              // must be within half of its own last digit. That catches a
              // multiplier applied twice, a dropped digit, or a
              // truncation, at every magnitude, without this test having
              // to know which rung the rule picked.
              final shown = printed.contains('.')
                  ? printed.length - printed.indexOf('.') - 1
                  : 0;
              final tolerance = 0.5 * _tenTo(-shown);
              expect((read - exact).abs(),
                  lessThanOrEqualTo(tolerance * 1.000001),
                  reason: '${entry.key}: "${line.raw}" at $multiplier times '
                      'is $exact but printed as "$printed", which is further '
                      'than half of its own last digit');
              checked += 1;
            }
          }
        }
      }
      expect(checked, greaterThan(500),
          reason: 'the sweep must actually cover the manual; $checked '
              'checks means the corpus or the multiplier list collapsed');
    });
  });
}
