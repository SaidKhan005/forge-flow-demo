// Structured view of the Recipes manual's ingredient lines.
//
// WHY A SECOND VIEW EXISTS. The reading card shows a recipe's ingredients
// as verbatim text, which is everything a cook needs at the bench. A
// scaling calculator needs the same lines as data: which part of the line
// is the number, what that number measures, what the ingredient is, and,
// most importantly, whether multiplying that number is honest.
//
// This file holds the shape. The data itself is generated into
// `barrio_recipe_ingredients.dart` by
// `tool/barrio_recipe_ingredients_generator.py`, which reads the GENERATED
// card bodies, so every [BarrioRecipeIngredient.raw] is lifted
// character-for-character out of the body the reader actually sees.
// `test/barrio_recipe_ingredients_test.dart` re-proves that tie against
// the live document and proves the parse covers every ingredient line, so
// the reader and a calculator can never show two different numbers.
//
// Nothing here restates a body. The verbatim law is untouched: this is an
// index onto the text, never a copy of it.

import 'package:flutter/foundation.dart';

import 'barrio_recipe_ingredients.dart';

/// Why a parsed ingredient line must not be multiplied.
///
/// A line is scalable only when it carries exactly one number and that
/// number is attached to a unit of mass or volume, because those divide
/// cleanly at any multiplier: half of 500mL is 250mL. Every other line is
/// held back for one of the reasons below and is carried through to the
/// cook unchanged.
enum BarrioIngredientHold {
  /// The line opens with no number at all, so there is nothing to
  /// multiply: 'Salt TT', 'The Peel of One Orange'.
  noQuantity,

  /// The number counts containers, and no shelf sells 2.5 of them:
  /// '1 Jar Aji Amarillo', '2 Bags Yellow Corn Tortilla'.
  containerCount,

  /// The number counts whole items, where a fraction is nonsense at the
  /// bench: '4 Cloves of garlic', '2 Stalks Celery', '1 Bunch Thyme'.
  wholeItemCount,

  /// The line carries a number but never says what that number measures,
  /// so scaling it would be a guess: '15 Avocados', '654 Canola Oil'.
  noUnit,

  /// The operator wrote a range, which is a judgement call rather than a
  /// quantity: '8-10lbs of beets', '2kg-2.5kg Shrimp Shells'.
  range,
}

/// One ingredient line of one recipe, as data.
@immutable
class BarrioRecipeIngredient {
  const BarrioRecipeIngredient({
    required this.raw,
    required this.name,
    required this.scalable,
    this.quantity,
    this.unit,
    this.hold,
  });

  /// The line exactly as the card body prints it, bullet stripped. This is
  /// what a calculator shows when it may not scale the line, and it is an
  /// exact substring of the card's body.
  final String raw;

  /// What the line is an amount OF, with the quantity taken off the front
  /// (and a leading 'of ' dropped, so '8-10lbs of beets' names 'beets').
  /// Derived for display and lookup; the source of truth stays [raw].
  final String name;

  /// Whether multiplying [quantity] is honest. See [BarrioIngredientHold]
  /// for every reason this is false.
  final bool scalable;

  /// The number read off the front of the line, when there is one. Present
  /// on many held lines too, so a calculator can SHOW it; [scalable] is
  /// what decides whether it may be multiplied.
  final double? quantity;

  /// The unit word attached to [quantity], when the line carries one that
  /// the parser recognises, spelled exactly as the source spells it (the
  /// kitchen writes both 'mL' and 'ml', and both survive).
  final String? unit;

  /// Why this line is held back, or null when [scalable] is true.
  final BarrioIngredientHold? hold;
}

/// The ingredient lines carried by one reading card, or an empty list for
/// any card that has none (every method card, and every manual that is not
/// Recipes).
List<BarrioRecipeIngredient> barrioRecipeIngredientsForUnit(String unitId) =>
    kBarrioRecipeIngredients[unitId] ?? const <BarrioRecipeIngredient>[];
