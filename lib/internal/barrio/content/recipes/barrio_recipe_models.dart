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

  /// Whether this line has a number to multiply.
  bool get scales => quantity != null;
}

/// The ingredient lines carried by one reading card, or an empty list for
/// any card that has none (every method card, and every manual that is not
/// Recipes).
List<BarrioRecipeIngredient> barrioRecipeIngredientsForUnit(String unitId) =>
    kBarrioRecipeIngredients[unitId] ?? const <BarrioRecipeIngredient>[];
