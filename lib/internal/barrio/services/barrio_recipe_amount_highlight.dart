// Ingredient-amount emphasis on recipe cards (REC-7, 2026-08-14).
//
// WHY THIS EXISTS. On a recipe card every ingredient line opens with an
// amount, but only some of those amounts carried emphasis: the general
// number+unit matcher in `barrio_numeric_highlight.dart` popped '500mL',
// '50ml' and '10g' and left '1 Jar', '2 Stalks', '4 Cloves', '4' and the
// fraction glyph plain, because those amounts print no unit the general
// matcher recognises. Three accented lines out of nine reads as arbitrary,
// and the operator said so. This matcher makes a recipe card's amounts one
// treatment: all of them, or none.
//
// PRECISE, NOT WIDER. Nothing here loosens the general numeric matcher,
// which would change all 26 manuals. This matcher only ever styles a span
// the committed ingredient data already names as an amount, so it cannot
// fire outside the Recipes manual and cannot invent a token.
//
// HOW A SPAN IS FOUND. Every [BarrioRecipeIngredient.raw] is an exact
// substring of the card body it belongs to and every
// [BarrioRecipeIngredient.amount] is an exact substring of that raw line,
// both re-proved against the live document by
// `test/barrio_recipe_ingredients_test.dart`. So the amount is located by
// finding the LINE first and then the amount inside it: a bare '4' can
// never be styled somewhere else on the card, and 'Lime 300mL' (the one
// line of the manual whose amount is not at the front) is found where it
// actually sits.
//
// A line occurrence only counts when the characters either side of it are
// not letters or digits. The reader hands this matcher one rendered chunk
// with its '- ' bullet already stripped, so a real line sits alone in its
// chunk; the guard is what stops a short line ('30g Salt') being found
// inside a longer one ('130g Salt') and styling an amount one character
// off.
//
// PRECEDENCE, AND WHY IT SITS WHERE IT DOES. The reader's tiers are, from
// highest:
//
//     search wash > term links > INGREDIENT AMOUNTS > numeric pops >
//     quiz answer evidence > key terms
//
// A lower tier that overlaps a higher one is dropped WHOLE and renders no
// emphasis at all, so where this tier goes is a real decision, not a
// detail. It sits ABOVE the numeric pops on purpose:
//
//   * '500mL' is claimed once, by this tier, and the numeric candidate
//     covering the same characters is dropped as the duplicate it is. The
//     span renders in exactly the style it rendered in before, so a card
//     that already popped '500mL' looks unchanged and every other amount
//     joins it.
//   * '2kg-2.5kg' is ONE amount but TWO numeric tokens ('2kg' and
//     '2.5kg'), so the wider span has to win or the hyphen would sit
//     unaccented between two pops.
//   * The numeric tier keeps running on the rest of the card. Four recipe
//     cards carry method prose in the same card as their ingredient list
//     ('cook for 15-20 minutes'), and those facts must keep their pop.
//     Turning the numeric tier off for recipe cards would have lost them.
//
// Nothing below this tier loses anything today: recipe cards carry no
// curated key terms and no quiz answer evidence, and across all 31
// ingredient cards no numeric token PARTIALLY overlaps an amount (every
// one is either wholly inside an amount or wholly outside it), so no
// numeric pop is dropped except the exact duplicates described above.
// `test/barrio_recipe_amount_highlight_test.dart` re-proves each of those
// three facts from the shipped content rather than taking them on trust.
//
// The text itself is never altered: [BarrioRecipeAmountMatch] carries
// [start, end) offsets into the chunk, styling only (verbatim law).

import '../content/recipes/barrio_recipe_models.dart';

/// One ingredient amount inside a rendered text chunk: [start, end)
/// offsets index the chunk string itself.
class BarrioRecipeAmountMatch {
  final int start;
  final int end;
  const BarrioRecipeAmountMatch(this.start, this.end);
}

/// Locates a recipe card's own ingredient amounts inside a rendered chunk.
class BarrioRecipeAmountHighlight {
  BarrioRecipeAmountHighlight._();

  /// The [start, end) span of every ingredient amount [lines] names inside
  /// [text], sorted and non-overlapping.
  ///
  /// [lines] are the card's own committed ingredient lines; an empty list
  /// (every card of every other manual, and every method card) returns
  /// nothing, so no other manual can change.
  ///
  /// [blockedRanges] are ranges already claimed by a higher tier (the
  /// search wash, a term link); an amount overlapping one is dropped whole,
  /// exactly as every other tier drops an overlap.
  static List<BarrioRecipeAmountMatch> matchesIn(
    String text,
    List<BarrioRecipeIngredient> lines, {
    List<List<int>> blockedRanges = const [],
  }) {
    if (text.isEmpty || lines.isEmpty) {
      return const <BarrioRecipeAmountMatch>[];
    }
    final candidates = <BarrioRecipeAmountMatch>[
      for (final line in lines) ..._spansOfLine(text, line),
    ];
    if (candidates.isEmpty) return const <BarrioRecipeAmountMatch>[];
    // Earliest first; at the same start the longer amount wins, which is
    // how one line that is a prefix of another cannot shorten the span.
    candidates.sort((a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : b.end.compareTo(a.end));
    return _acceptNonOverlapping(candidates, blockedRanges);
  }

  /// Where [line]'s amount sits inside [text], once per occurrence of the
  /// whole line. Unsorted; the caller orders and de-overlaps them.
  static List<BarrioRecipeAmountMatch> _spansOfLine(
    String text,
    BarrioRecipeIngredient line,
  ) {
    final amount = line.amount;
    if (amount == null || amount.isEmpty || line.raw.isEmpty) {
      return const <BarrioRecipeAmountMatch>[];
    }
    final spans = <BarrioRecipeAmountMatch>[];
    var from = 0;
    while (from <= text.length - line.raw.length) {
      final lineAt = text.indexOf(line.raw, from);
      if (lineAt < 0) break;
      final lineEnd = lineAt + line.raw.length;
      final amountAt = _standsAlone(text, lineAt, lineEnd)
          ? text.indexOf(amount, lineAt)
          : -1;
      if (amountAt >= 0 && amountAt + amount.length <= lineEnd) {
        spans.add(
          BarrioRecipeAmountMatch(amountAt, amountAt + amount.length),
        );
      }
      from = lineEnd;
    }
    return spans;
  }

  /// The sorted [candidates] thinned to a mutually non-overlapping run,
  /// with anything a higher tier already claimed dropped whole.
  static List<BarrioRecipeAmountMatch> _acceptNonOverlapping(
    List<BarrioRecipeAmountMatch> candidates,
    List<List<int>> blockedRanges,
  ) {
    final accepted = <BarrioRecipeAmountMatch>[];
    for (final match in candidates) {
      if (accepted.isNotEmpty && match.start < accepted.last.end) continue;
      if (_intersectsAny(match, blockedRanges)) continue;
      accepted.add(match);
    }
    return accepted;
  }

  /// True when `text[start, end)` is a whole line rather than a run found
  /// inside a longer one: the characters either side are not letters or
  /// digits.
  static bool _standsAlone(String text, int start, int end) {
    if (start > 0 && _isWordChar(text.codeUnitAt(start - 1))) return false;
    if (end < text.length && _isWordChar(text.codeUnitAt(end))) return false;
    return true;
  }

  static bool _isWordChar(int code) =>
      (code >= 0x30 && code <= 0x39) || // 0-9
      (code >= 0x41 && code <= 0x5A) || // A-Z
      (code >= 0x61 && code <= 0x7A); // a-z

  static bool _intersectsAny(
      BarrioRecipeAmountMatch match, List<List<int>> ranges) {
    for (final range in ranges) {
      if (match.start < range[1] && match.end > range[0]) return true;
    }
    return false;
  }
}
