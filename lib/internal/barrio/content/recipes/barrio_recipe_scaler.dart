// The arithmetic behind the recipe calculator.
//
// WHAT THIS IS FOR. A cook has 3kg of pork belly and the recipe was
// written for 2.5kg. They should not have to work the multiplier out in
// their head. They pick the line they are starting from, type the amount
// they actually have, and every other amount follows. The multiplier is
// derived from that one anchor, never typed.
//
// NO UNIT CONVERSION, ON PURPOSE. Every line stays in the unit it was
// already written in, and the typed amount is read in the anchor's own
// unit. A gram never becomes a kilogram here. Converting is a whole class
// of wrong-number bugs, and it is not what was asked for: the recipe says
// 500mL, so the cook types millilitres.
//
// ONE RULE. A line with a number scales; a line without one prints as
// written, and nothing is said about it. See the note in
// `barrio_recipe_models.dart` for why the old held/scalable split and its
// four explanations were deleted rather than hidden.
//
// AND IT IS EVERY NUMBER ON THE LINE, not just the one in the amount
// column: see [barrioScaledName].
//
// PLAIN ARITHMETIC, NO CATEGORIES. Counts are multiplied like anything
// else, so '2 Stalks Celery' at 2.4 times reads '4.8 Stalks'. Rounding
// that back to a whole stalk is the cook's call and the calculator does
// not make it for them.
//
// Nothing here reads or writes anything. It is arithmetic and formatting
// over the data in `barrio_recipe_ingredients.dart`, so it is testable on
// its own, and `test/barrio_recipe_scaler_test.dart` derives every
// expected value by hand rather than asking this file what it did.

import 'dart:math' as math;

import 'barrio_recipe_models.dart';

/// How many times the written recipe the cook is making.
///
/// [amount] is read in [anchor]'s own unit, so the multiplier is
/// `amount / anchor.quantity`: the cook says what they have of ONE
/// ingredient and the rest follows. A missing anchor, a range (which is
/// two numbers, so an amount typed against it would be ambiguous), a
/// missing amount, and anything that is not a real number above zero all
/// give exactly 1, so a half-typed number never shows a half-invented
/// recipe.
double barrioRecipeMultiplier({
  BarrioRecipeIngredient? anchor,
  double? amount,
}) {
  final written = anchor?.quantity;
  if (anchor == null ||
      written == null ||
      written <= 0 ||
      anchor.quantityHigh != null ||
      amount == null ||
      !amount.isFinite ||
      amount <= 0) {
    return 1.0;
  }
  return amount / written;
}

/// The lines of [lines] a cook may start from.
///
/// Every line with a number except a range: a range is two numbers, and an
/// amount typed against '8-10lbs of beets' would not say which one it
/// meant. Ranges still scale when some other line is the anchor.
List<BarrioRecipeIngredient> barrioAnchorLines(
  List<BarrioRecipeIngredient> lines,
) =>
    <BarrioRecipeIngredient>[
      for (final line in lines)
        if ((line.quantity ?? 0) > 0 && line.quantityHigh == null) line,
    ];

/// [line]'s amount exactly as the card printed it, or null when the line
/// has no amount at all.
///
/// The operator writes kitchen fractions ('¼ Red Onion', '½ Cup', '1/4
/// Bunch cilantro'), and untouched the calculator has to be the recipe:
/// what the card wrote, character for character, glyph and all. Rewriting
/// the number would turn '¼' into '0.25' before the cook has typed
/// anything.
///
/// The one line shape that needs more than the text is a unit the recipe
/// never printed: '235 Pumpkin Seeds' carries the operator-confirmed 'g'
/// in [BarrioRecipeIngredient.unit] and nowhere in its own text, so the
/// unit is appended. That is the same rule [barrioScaledAmount] applies,
/// stated once and used by both.
String? barrioWrittenAmount(BarrioRecipeIngredient line) {
  final amount = line.amount;
  if (amount == null) return null;
  return _withUnit(amount, line.unit);
}

/// The number [line]'s amount opens with, exactly as the card wrote it:
/// '500', '2', '¼', '1/4', '8'. Null when the line carries no amount.
///
/// This is what an empty amount box shows, so an untouched box reads back
/// the recipe's own number rather than a decimal the card never printed.
/// The unit is NOT included: the box shows it separately, and doubling it
/// would read '¼ Bunch' beside 'Bunch'.
String? barrioWrittenNumber(BarrioRecipeIngredient line) {
  final amount = line.amount;
  if (amount == null) return null;
  return _numberInAnAmount.firstMatch(amount)?.group(0);
}

/// [line]'s amount at [multiplier], or null when the line has no number.
///
/// At exactly one times the recipe nothing is rewritten: the line prints
/// [barrioWrittenAmount], which is the card's own text. That is the whole
/// of the fraction rule. A cook who has typed nothing, and a cook who has
/// typed the amount the recipe already says, are both looking at the
/// recipe as written, and '¼ Red Onion' has to read '¼' for them both.
/// Once the multiplier really moves the computed number is the honest
/// answer and it is shown: a quarter onion at 2.4 times is '0.6', not a
/// glyph invented to look like the source.
///
/// The scaled text is [BarrioRecipeIngredient.amount] with its numbers
/// rewritten and every other character left alone, so '500mL' becomes
/// '1250mL', '1 TSP' becomes '2.5 TSP', '8-10lbs' becomes '16-20lbs', and
/// '2kg-2.5kg' becomes '4kg-5kg'. A range scales on both of its numbers.
///
/// The one line shape that needs more than a rewrite is a unit the recipe
/// never printed: '235 Pumpkin Seeds' carries the operator-confirmed 'g'
/// in [BarrioRecipeIngredient.unit] and nowhere in its own text, so the
/// unit is appended. Every other line already spells its unit inside the
/// amount.
String? barrioScaledAmount(BarrioRecipeIngredient line, double multiplier) {
  final amount = line.amount;
  final quantity = line.quantity;
  if (amount == null || quantity == null) return null;
  if (multiplier == 1.0) return barrioWrittenAmount(line);
  final scaled = <double>[
    quantity * multiplier,
    if (line.quantityHigh != null) line.quantityHigh! * multiplier,
  ];
  var index = 0;
  final rewritten = amount.replaceAllMapped(_numberInAnAmount, (match) {
    final source = match.group(0)!;
    if (index >= scaled.length) return source;
    final value = scaled[index];
    index += 1;
    return barrioFormatRecipeAmount(value);
  });
  return _withUnit(rewritten, line.unit, source: amount);
}

/// [line]'s ingredient text at [multiplier]: the same words the card
/// wrote, with any number inside them moved by the same factor the amount
/// moved.
///
/// WHY AN INGREDIENT'S OWN TEXT HAS TO MOVE (REC-8, 2026-08-14). '180g
/// White/Black Sesame Seed (90g each)' at twice the batch used to print
/// '360g White/Black Sesame Seed (90g each)': two numbers on one line
/// saying different batches, with nothing to tell a cook which one to
/// weigh to. The parenthesis is the operator's split between the two seed
/// types, so a cook following it puts in half of what the dish needs. Now
/// it reads '(180g each)' and the line agrees with itself.
///
/// WHICH NUMBERS MOVE is decided once, by the generator, and recorded in
/// [BarrioRecipeIngredient.nameNumbers]: a null entry stays exactly as
/// written (a percentage is a ratio; a digit inside a word is part of the
/// word). Nothing is re-decided here, so this function cannot disagree
/// with the data about what a number means.
///
/// At exactly one times the recipe the name is returned untouched, which
/// is the same rule [barrioScaledAmount] follows: an untouched calculator
/// is the recipe as it was written, character for character. A line whose
/// data records fewer numbers than its text holds leaves the extra ones
/// alone rather than guessing at them.
String barrioScaledName(BarrioRecipeIngredient line, double multiplier) {
  final numbers = line.nameNumbers;
  if (multiplier == 1.0 || numbers.isEmpty) return line.name;
  var index = 0;
  return line.name.replaceAllMapped(_numberInAnAmount, (match) {
    final source = match.group(0)!;
    final base = index < numbers.length ? numbers[index] : null;
    index += 1;
    if (base == null) return source;
    return barrioFormatRecipeAmount(base * multiplier);
  });
}

/// [text] with [unit] appended, unless the amount already spells it.
///
/// [source] is the amount the decision is made against, which is the
/// line's own text: a scaled '235' still needs its 'g' even though the
/// number changed, and '500mL' still must not gain a second 'mL'.
String _withUnit(String text, String? unit, {String? source}) {
  if (unit == null || (source ?? text).contains(unit)) return text;
  return '$text $unit';
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
/// NO COUNT ROUNDING, DELIBERATELY. A count is not rounded to a whole
/// number here: '2 Stalks' at 2.4 times prints '4.8 Stalks'. Snapping it
/// to 5 would be the calculator deciding how much celery goes in, and the
/// operator chose to leave that with the cook.
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

/// A number inside an amount: a kitchen fraction glyph, a decimal, or a
/// written fraction such as '1/2'. The generator guarantees an amount
/// holds exactly one of these, or two when the line is a range.
final RegExp _numberInAnAmount = RegExp(r'[¼½¾⅓⅔⅛⅜⅝⅞]|'
    r'\d+(?:\.\d+)?(?:/\d+(?:\.\d+)?)?');
