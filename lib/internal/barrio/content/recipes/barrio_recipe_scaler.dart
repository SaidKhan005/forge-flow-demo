// Scaling a recipe from the one ingredient the cook is holding.
//
// WHAT THIS IS FOR. A cook has 3kg of pork belly and the recipe was
// written for 2.5kg. They should not have to work the multiplier out in
// their head. They name the line they are starting from, type the
// amount they actually have, and every other amount that CAN move
// follows. The multiplier is derived from that one anchor, never typed.
//
// NO UNIT CONVERSION, ON PURPOSE. Every line stays in the unit it was
// already written in, and the typed amount is read in the anchor's own
// unit. A gram never becomes a kilogram here. Converting is a whole
// class of wrong-number bugs, and it is not what was asked for: the
// recipe says 500mL, so the cook types millilitres.
//
// HONESTY IS THE POINT. 44 of the manual's 203 ingredient lines cannot
// be multiplied at all (see [BarrioIngredientHold]). Those lines are
// carried through UNCHANGED, never hidden and never quietly scaled, each
// with a reason a cook can act on. A calculator that silently turned
// '1 Jar Aji Amarillo' into '2.5 Jar' would be worse than no calculator.
//
// A REASON HAS TO BE TRUE, NOT JUST CAUTIOUS. Holding a line is only
// honest while the sentence beside it is honest. 14 countable lines used
// to be held with 'the recipe does not say what this number measures',
// printed next to '12 Eggs', which reads as a broken app rather than as
// a judgement left to the cook. They are counts now, and they say so.
// See the removal note in `barrio_recipe_models.dart`.
//
// Nothing here reads or writes anything. It is arithmetic and
// formatting over the data in `barrio_recipe_ingredients.dart`, so it is
// testable on its own, and `test/barrio_recipe_scaler_test.dart` derives
// every expected value by hand rather than asking this file what it did.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'barrio_recipe_models.dart';

/// One ingredient line after scaling.
///
/// [scaledQuantity] is null for every line the recipe does not allow to
/// be multiplied; [BarrioRecipeIngredient.hold] on [line] says why, and
/// [barrioHoldReason] turns that into words for the cook.
@immutable
class BarrioScaledIngredient {
  const BarrioScaledIngredient({required this.line, this.scaledQuantity});

  /// The source line, untouched. [BarrioRecipeIngredient.raw] is what a
  /// held line shows, character for character as the card printed it.
  final BarrioRecipeIngredient line;

  /// The multiplied amount, or null when the line is held back.
  final double? scaledQuantity;

  /// Whether this line moved with the cook's amount.
  bool get scaled => scaledQuantity != null;

  /// The new amount with its unit, ready to show ('1250mL'), or null on
  /// a held line.
  String? get scaledText => scaledQuantity == null
      ? null
      : barrioAmountWithUnit(scaledQuantity!, line);

  /// The amount the recipe was written with, with its unit ('500mL'), or
  /// null when the line never carried a quantity at all. A cook has to
  /// be able to see what changed, so this stays next to [scaledText].
  String? get originalText =>
      line.quantity == null ? null : barrioAmountWithUnit(line.quantity!, line);

  /// Whether scaling actually moved this line's printed amount. False at
  /// a multiplier of 1, and false when the change is too small to show,
  /// which is exactly when repeating the old amount would be noise.
  bool get changed =>
      scaled && originalText != null && scaledText != originalText;
}

/// A whole recipe scaled from one anchor.
@immutable
class BarrioRecipeScale {
  const BarrioRecipeScale({
    required this.multiplier,
    required this.anchor,
    required this.lines,
  });

  /// How many times the written recipe this is. Derived from the anchor,
  /// never typed. Exactly 1.0 whenever the cook has not given a usable
  /// amount, so the honest default is the recipe as written.
  final double multiplier;

  /// The line the cook is starting from, or null when the recipe has
  /// nothing that may be scaled.
  final BarrioRecipeIngredient? anchor;

  /// Every line of the recipe, in the card's own order, scalable and
  /// held alike. Nothing is dropped.
  final List<BarrioScaledIngredient> lines;

  /// True when this is the recipe exactly as written.
  bool get isAsWritten => multiplier == 1.0;
}

/// Scales [lines] so that [anchor] comes out at [amount] of its own unit.
///
/// The multiplier is `amount / anchor.quantity`, which is the whole idea:
/// the cook says what they have of ONE ingredient and the rest follows.
/// An anchor that may not be scaled, a missing amount, and any amount
/// that is not a real number above zero all fall back to a multiplier of
/// 1, so a half-typed number never shows a half-invented recipe.
BarrioRecipeScale barrioScaleRecipe({
  required List<BarrioRecipeIngredient> lines,
  BarrioRecipeIngredient? anchor,
  double? amount,
}) {
  final anchorQuantity = anchor?.quantity;
  final usable = anchor != null &&
      anchor.scalable &&
      anchorQuantity != null &&
      anchorQuantity > 0 &&
      amount != null &&
      amount.isFinite &&
      amount > 0;
  final multiplier = usable ? amount / anchorQuantity : 1.0;
  return BarrioRecipeScale(
    multiplier: multiplier,
    anchor: anchor,
    lines: <BarrioScaledIngredient>[
      for (final line in lines)
        BarrioScaledIngredient(
          line: line,
          // The hold is what decides. A line that may not be multiplied
          // gets no scaled amount at all, at any multiplier, so there is
          // no path by which a jar count can be quietly moved.
          scaledQuantity: line.scalable && line.quantity != null
              ? line.quantity! * multiplier
              : null,
        ),
    ],
  );
}

/// The lines of [lines] the cook may start from.
List<BarrioRecipeIngredient> barrioScalableLines(
  List<BarrioRecipeIngredient> lines,
) =>
    <BarrioRecipeIngredient>[
      for (final line in lines)
        if (line.scalable && (line.quantity ?? 0) > 0) line,
    ];

/// Why a line did not move, in words a cook can act on.
///
/// Every reason ends with what to DO, because a held line is not an
/// error: it is a judgement the recipe left to the person cooking.
String barrioHoldReason(BarrioIngredientHold hold) {
  return switch (hold) {
    BarrioIngredientHold.noQuantity =>
      'No amount to scale. Go by taste and by eye.',
    BarrioIngredientHold.containerCount =>
      'Counted in containers. Round it yourself.',
    BarrioIngredientHold.wholeItemCount =>
      'Counted as whole items. Round it yourself.',
    BarrioIngredientHold.range =>
      'The recipe gives a range. Pick a number inside it.',
  };
}

/// Where a line's unit came from, when it did not come from the recipe.
///
/// Two lines of the manual are weights the operator wrote as a bare
/// number, and confirmed as grams on 2026-08-13. The card still prints
/// them without a unit, because the manual is reproduced word for word.
/// So the calculator shows a unit the page does not, and a cook who
/// noticed that deserves the one sentence that explains it rather than
/// being left to wonder which of the two is wrong.
///
/// Null for every ordinary line, where the unit is right there on the
/// page and saying so would be noise.
String? barrioUnitSourceNote(BarrioRecipeIngredient line) {
  final unit = line.unit;
  if (!line.unitFromOperator || unit == null) return null;
  return 'The recipe prints no unit here. The operator confirmed '
      '${_unitInWords(unit)}.';
}

/// A unit said the way a cook would say it out loud.
///
/// Only the units an operator confirmation actually uses are spelled out.
/// Anything else falls back to the unit as written, which still reads
/// true; inventing wording for units no line carries would be wording
/// nothing can test.
String _unitInWords(String unit) => switch (unit.toLowerCase()) {
      'g' => 'grams',
      _ => unit,
    };

/// A number and its unit, spaced the way the source line spaced it
/// ('500mL' stays closed up, '1 TSP' keeps its space).
String barrioAmountWithUnit(double value, BarrioRecipeIngredient line) {
  final amount = barrioFormatRecipeAmount(value);
  final unit = line.unit;
  if (unit == null || unit.isEmpty) return amount;
  return _unitIsSpaced(line.raw) ? '$amount $unit' : '$amount$unit';
}

/// The derived multiplier as a cook would say it: '2.5', '0.5', '3'.
String barrioFormatMultiplier(double multiplier) =>
    barrioFormatRecipeAmount(multiplier);

/// ROUNDING RULE (decided 2026-08-13, kitchen sense over arithmetic).
///
/// Three clauses, applied in this order:
///
///   1. PRECISION FOLLOWS MAGNITUDE. 100 and up prints whole; 10 up to
///      100 prints at most one decimal; 1 up to 10 prints at most two;
///      below 1 prints at most three. Every rung keeps about three
///      meaningful digits, which is roughly what the source lines carry
///      (one to three), so the calculator never invents precision the
///      recipe never had. This is the clause that stops a third of 500mL
///      reading '166.66666666666666mL': it prints '167mL', which is what
///      a cook would measure anyway. The bottom rung is why a quarter cup
///      cut to a twentieth of a batch still prints '0.025 Cup' instead of
///      collapsing to '0.03 Cup'.
///   2. TRAILING ZEROS COME OFF. '250.0' is noise; '250' is an amount.
///   3. A REAL AMOUNT NEVER ROUNDS DOWN TO NOTHING. If the value is
///      above zero but the budget above would print '0', the budget grows
///      one digit at a time until the amount is visible. Printing '0g'
///      for 0.2g would tell a cook to leave the ingredient out, which is
///      the one rounding mistake that changes the dish. The growth stops
///      at twelve decimals purely so the loop is bounded; nothing in the
///      manual comes near it at any batch size a kitchen would key in,
///      which `test/barrio_recipe_scaler_test.dart` sweeps for.
///
/// WHAT WAS DELIBERATELY NOT DONE: a hard cap at the source line's own
/// decimal count. It reads well ('never more precision than the source')
/// until you halve '1g Coriander Seeds': the source carries no decimals,
/// so 0.5 would print as '1g', which is twice the right answer. Clause 1
/// gives the same protection where it matters (big coarse numbers) and
/// keeps small amounts honest.
String barrioFormatRecipeAmount(double value) {
  if (!value.isFinite) return '0';
  var decimals = _decimalsForMagnitude(value);
  var rounded = _roundTo(value, decimals);
  // Clause 3: grow the budget rather than tell a cook to leave it out.
  while (rounded == 0 && value != 0 && decimals < 12) {
    decimals += 1;
    rounded = _roundTo(value, decimals);
  }
  return _trimTrailingZeros(rounded.toStringAsFixed(decimals));
}

/// Clause 1 of the rounding rule.
int _decimalsForMagnitude(double value) {
  final size = value.abs();
  if (size >= 100) return 0;
  if (size >= 10) return 1;
  if (size >= 1) return 2;
  return 3;
}

/// Rounds half away from zero, so half a gram is not quietly dropped by
/// whichever way the platform's formatter happens to break a tie.
double _roundTo(double value, int decimals) {
  final factor = math.pow(10, decimals).toDouble();
  return (value * factor).round() / factor;
}

/// Clause 2 of the rounding rule.
String _trimTrailingZeros(String fixed) {
  if (!fixed.contains('.')) return fixed;
  var end = fixed.length;
  while (end > 0 && fixed[end - 1] == '0') {
    end -= 1;
  }
  if (end > 0 && fixed[end - 1] == '.') end -= 1;
  return fixed.substring(0, end);
}

/// Whether the source line put a space between its number and its unit.
/// Read off [raw] so the calculator spaces an amount the way the card
/// the cook just read spaced it.
bool _unitIsSpaced(String raw) {
  final match = _leadingNumberPattern.firstMatch(raw);
  if (match == null) return true;
  final rest = raw.substring(match.end);
  return rest.isEmpty || rest.startsWith(' ');
}

/// The number a line opens with: a kitchen fraction glyph, a decimal, or
/// a written fraction such as '1/2'.
final RegExp _leadingNumberPattern =
    RegExp(r'^\s*(?:[¼½¾⅓⅔]|'
        r'\d+(?:\.\d+)?(?:/\d+(?:\.\d+)?)?)');
