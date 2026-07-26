// Numeric fact pop (visual-first pass rec #3, 2026-07-24).
//
// Pure-Dart, render-time detection of number+unit fact tokens inside
// training card body prose, so consumers can style them (bold + manual
// accent) WITHOUT touching the verbatim string. The text itself is
// never altered: [BarrioNumericMatch] carries [start, end) offsets
// into the original chunk, styling only (verbatim law).
//
// DELIBERATELY CONSERVATIVE. A number is only a fact token when an
// explicit unit sits right next to it:
//   * temperatures: '165 F', '4 degrees C', '40-140°F',
//     '71 degrees C - 80 degrees C' (two tokens), 'degrees Celsius'
//   * durations: '25 seconds', '2 minutes', '30 days', '3 to 6
//     seconds', '6hrs', '30-minute'
//   * percentages: '5%', '40 percent'
//   * measurements with explicit units: oz, ml, g, kg, lb(s), ppm,
//     cup(s), bar(s)
// NEVER matched: bare integers ('42'), years and dates ('1915',
// 'in 2012'), chapter/step numbers ('Chapter 3', 'Step 2'), and
// name-like uses ("4 C's", '3 pillars') — no unit, no token; the
// (?!['’\w]) guard kills "4 C's" specifically.
//
// Overlap rule (composition with existing span styling): the caller
// passes the ranges already claimed by search highlights and
// tap-to-define term links as [blockedRanges]; any numeric token that
// overlaps a blocked range is dropped whole. Text inside a term link
// or a search highlight is therefore never re-styled by this matcher.

/// One numeric fact token inside a text chunk: [start, end) offsets
/// index the chunk string itself.
class BarrioNumericMatch {
  final int start;
  final int end;
  const BarrioNumericMatch(this.start, this.end);
}

/// Conservative number+unit tokenizer for render-time styling.
class BarrioNumericHighlight {
  BarrioNumericHighlight._();

  /// A number: '165', '2.5', '8.57', '1,000'.
  static const String _num = r'\d+(?:[.,]\d+)?';

  /// Optional range tail directly after the leading number:
  /// '40-140', '40 - 140', '3 to 6'. The unit then closes the token.
  static const String _range = '(?:\\s*-\\s*$_num|\\s+to\\s+$_num)?';

  /// Guard after a unit word/letter: not mid-word and not a
  /// possessive ("4 C's" is a name, not a temperature).
  static const String _tail = r"(?!['’\w])";

  /// Temperature letter units. Case-SENSITIVE on purpose: a bare
  /// lowercase 'c'/'f' after a number is never a temperature here.
  static final RegExp _temperature = RegExp(
    '\\b$_num$_range'
    '(?:'
    '\\s?[°º]\\s?[CF]$_tail' // 140°F, 40 °C
    '|\\s[CF]$_tail' // 165 F
    ')',
  );

  /// Word/abbreviation units. Case-insensitive: the word gives the
  /// context, so case adds no safety.
  static final RegExp _wordUnit = RegExp(
    '\\b$_num$_range'
    '(?:'
    // 4 degrees C, 40 degrees Fahrenheit, 20 degrees Celsius
    '[\\s-]degrees?\\s(?:celsius|fahrenheit|[cf])$_tail'
    // 5%, 40 percent
    '|\\s?%'
    '|[\\s-]percent$_tail'
    // 25 seconds, 2 minutes, 30 days, 8.57 weeks, 30-minute
    '|[\\s-](?:seconds?|minutes?|hours?|days?|weeks?)$_tail'
    // 6hrs, 50 hrs, 5 min, 15 secs (abbreviations may sit tight)
    '|\\s?(?:hrs?|mins?|secs?)$_tail'
    // 12oz, 341 ml, 2.5 kg, 200 ppm (abbreviations may sit tight)
    '|\\s?(?:oz|ml|g|kg|lbs?|ppm)$_tail'
    // 2 cups, 9 bars
    '|[\\s-](?:cups?|bars?)$_tail'
    ')',
    caseSensitive: false,
  );

  static final RegExp _anyDigit = RegExp(r'\d');

  /// Finds the numeric fact tokens to style inside one text chunk.
  ///
  /// [blockedRanges] are [start, end) ranges already claimed by other
  /// styling (search highlights, term links); an overlapping token is
  /// dropped whole. Returned matches are sorted and non-overlapping.
  static List<BarrioNumericMatch> matchesIn(
    String text, {
    List<List<int>> blockedRanges = const [],
  }) {
    if (text.isEmpty || !text.contains(_anyDigit)) {
      return const <BarrioNumericMatch>[];
    }
    final candidates = <BarrioNumericMatch>[
      for (final m in _temperature.allMatches(text))
        BarrioNumericMatch(m.start, m.end),
      for (final m in _wordUnit.allMatches(text))
        BarrioNumericMatch(m.start, m.end),
    ];
    if (candidates.isEmpty) return const <BarrioNumericMatch>[];
    // Earliest first; at the same start the longer token wins.
    candidates.sort((a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : b.end.compareTo(a.end));
    final accepted = <BarrioNumericMatch>[];
    for (final match in candidates) {
      if (accepted.isNotEmpty && match.start < accepted.last.end) continue;
      if (_intersectsAny(match, blockedRanges)) continue;
      accepted.add(match);
    }
    return accepted;
  }

  static bool _intersectsAny(
      BarrioNumericMatch match, List<List<int>> ranges) {
    for (final range in ranges) {
      if (match.start < range[1] && match.end > range[0]) return true;
    }
    return false;
  }
}
