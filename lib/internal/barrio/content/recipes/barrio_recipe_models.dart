// Structured view of the Recipes manual's ingredient lines.
//
// WHY A SECOND VIEW EXISTS. The reading card shows a recipe's ingredients
// as verbatim text, which is everything a cook needs at the bench. A
// calculator needs the same lines as data: which part of the line is the
// amount, what number is inside it, and what the ingredient is.
//
// This file holds the shape. The data itself is generated into
// `barrio_recipe_ingredients.dart` by
// `tool/barrio_recipe_ingredients_generator.py`, which reads the GENERATED
// card bodies, so every [BarrioRecipeIngredient.raw] is lifted
// character-for-character out of the body the reader actually sees.
// `test/barrio_recipe_ingredients_test.dart` re-proves that tie against
// the live document and proves the parse covers every ingredient line, so
// the reader and the calculator can never show two different numbers.
//
// Nothing here restates a body. The verbatim law is untouched: this is an
// index onto the text, never a copy of it.
//
// ONE RULE, AND IT IS THE WHOLE RULE (operator direction, REC-6,
// 2026-08-13): a line that carries a number can be multiplied, and a line
// that carries no number cannot. There is no category of number that is
// held back and no sentence explaining one. An earlier release sorted the
// numbers into containers, whole items and ranges and refused to move
// them; the operator chose plain arithmetic instead, knowing that '2
// Stalks Celery' at 2.4 times reads '4.8 Stalks'. Rounding a jar count is
// the cook's call, and it does not need saying.
//
// EVERY number on the line, not just the one in the amount column
// (REC-8, 2026-08-14). Five lines write a second number into the
// ingredient itself, and a line that moved one number and not the other
// was printing two amounts that meant different batches. See
// [BarrioRecipeIngredient.nameNumbers] for the rule and its two
// exceptions.

import 'package:flutter/foundation.dart';

import 'barrio_recipe_ingredients.dart';

/// One ingredient line of one recipe, as data.
@immutable
class BarrioRecipeIngredient {
  const BarrioRecipeIngredient({
    required this.raw,
    required this.name,
    this.amount,
    this.quantity,
    this.quantityHigh,
    this.unit,
    this.nameNumbers = const <double?>[],
  });

  /// The line exactly as the card body prints it, bullet stripped. An
  /// exact substring of the card's body.
  final String raw;

  /// What the line is an amount OF: [raw] with [amount] taken out (and a
  /// leading 'of ' dropped, so '8-10lbs of beets' names 'beets'). On a
  /// line that carries no number this is the whole line, which is how a
  /// calculator prints such a line exactly as written.
  final String name;

  /// The part of [raw] that is the amount, sliced out of the line itself:
  /// '500mL', '2 Stalks', '12', '8-10lbs', '2kg-2.5kg'. Null when the line
  /// carries no number.
  ///
  /// Scaling rewrites the numbers INSIDE this text and leaves every other
  /// character alone, which is why a scaled line keeps the spacing and the
  /// wording the card used ('500mL' stays closed up, '1 TSP' keeps its
  /// space, a range keeps its hyphen).
  final String? amount;

  /// The number in [amount], or the FIRST number when the line is a range.
  /// Null when the line carries no number, which is the only reason a line
  /// cannot be scaled.
  final double? quantity;

  /// The second number of a range ('8-10lbs of beets' carries 8 and 10),
  /// or null. Both numbers scale.
  final double? quantityHigh;

  /// The unit word attached to the number, spelled exactly as the source
  /// spells it (the kitchen writes both 'mL' and 'ml', and both survive).
  ///
  /// Almost always a word [amount] already contains. Two lines of the
  /// manual are weights written as a bare number ('235 Pumpkin Seeds',
  /// '654 Canola Oil'); both sit among gram lines in their own recipe and
  /// the operator confirmed both as grams on 2026-08-13, so those two
  /// carry a unit their own text does not print.
  final String? unit;

  /// One entry per number written inside [name], in the order the line
  /// writes them: the value that number scales from, or null when it
  /// stays exactly as written. Empty for the great majority of lines,
  /// whose ingredient is words only.
  ///
  /// WHY AN INGREDIENT NAME CARRIES NUMBERS AT ALL. [amount] is not the
  /// only place a recipe line writes one. The operator writes '180g
  /// White/Black Sesame Seed (90g each)', and the parenthesis is the
  /// split between the two seeds, not decoration. Moving [amount] and
  /// leaving that behind puts two numbers on one line that mean
  /// different batches, and a cook weighing to the parenthesis puts in
  /// half of what the dish needs.
  ///
  /// So every number on the line moves together, with two exceptions
  /// this list records as null: a percentage ('70g Salt ( 1.75% weight
  /// of beets)') is a ratio between two amounts of the same recipe and
  /// scaling both leaves it exactly where it was, and a digit inside a
  /// word ('L5S TT') is part of the ingredient's name rather than a
  /// number at all.
  ///
  /// The entries line up one-for-one with the numbers [barrioScaledName]
  /// finds in [name]; `test/barrio_recipe_ingredients_test.dart` re-reads
  /// both off the live manual and fails if they ever fall out of step.
  final List<double?> nameNumbers;

  /// Whether this line has a number to multiply.
  bool get scales => quantity != null;
}

/// The ingredient lines carried by one reading card, or an empty list for
/// any card that has none (every method card, and every manual that is not
/// Recipes).
List<BarrioRecipeIngredient> barrioRecipeIngredientsForUnit(String unitId) =>
    kBarrioRecipeIngredients[unitId] ?? const <BarrioRecipeIngredient>[];
