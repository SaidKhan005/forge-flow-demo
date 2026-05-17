// === LeverEmphasisMap : Variance Coaching V2 (Lane TW) =====================
// The per-lever inline-emphasis map for the This Week Primary Driver card.
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md V2-4
// ("Inline-emphasis markup convention") + the approved mockup
// docs/f&f Coaching/variance_tab_v2_mockup.html `.driver` block
// (`.em-bad` / `.em-good` causal emphasis + the `.readline` narrative).
//
// V2-4 hard rules honoured here:
//
//   - Catalog strings (lib/domain/constants/app_defaults.dart `LeverCards`)
//     stay byte-for-byte PLAIN. This map carries NO copy of the catalog
//     prose. It only names exact substrings that already exist in the
//     plain catalog `whatHappened` / `teachingNote` string for a lever
//     id, plus the token each span is promoted to. `applyEmphasis` wraps
//     those spans at RENDER time; it never adds, drops, or reorders a
//     word, so `InlineEmphasisMarkup.stripMarkup(applyEmphasis(plain))`
//     is provably equal to `plain`.
//   - The `.readline` narrative is render-time presentation copy (it is
//     NOT one of the 21 locked catalog states and is not persisted). It
//     is BUILT per render from a per-lever lead maxim + close maxim plus
//     a dollar clause whose chips carry the REAL signed per-axis
//     attribution the card already computes (no hardcoded amount), so
//     it reads as the FULL approved-mockup `.readline` sentence. The
//     string literals here are those maxims + axis phrasings; no em
//     dash (U+2014) / en dash (U+2013) appears in any literal.
//   - A lever id with no maxim entry degrades cleanly: `emphasize`
//     returns the plain string unchanged and `readlineFor` returns
//     null (the card simply omits the read-line). With a maxim entry
//     but no attribution map (legacy surfaces / tests) the read-line
//     degrades to `lead + close` with no fabricated chips. The degraded
//     `LeverCardNotYetAvailable` path never reaches this map.

import '../../utils/formatters.dart';
import 'inline_emphasis_text.dart';

/// One causal span to promote inside an already-plain catalog sentence.
/// [phrase] MUST be an exact, unique substring of the target catalog
/// string; [token] is the V2-4 markup the renderer wraps it in.
class _Span {
  const _Span(this.phrase, this.token);

  /// The verbatim substring as it appears in the plain catalog string.
  final String phrase;

  /// The V2-4 open token for this span: `[[bad:` / `[[good:`.
  /// (Chips are only used in the read-line literals, not span-wrapped
  /// into catalog prose, so only the causal tokens appear here.)
  final String token;
}

/// One axis's signed dollar contribution for the read-line dollar
/// clause. [signedId] is the populated lever id; [value] is the model's
/// signed amount (positive = adverse / loss, negative = favorable /
/// gain). Pure carrier; no math.
class _AxisAmount {
  const _AxisAmount(this.signedId, this.value);
  final String signedId;
  final double value;
}

class LeverEmphasisMap {
  const LeverEmphasisMap._();

  // Per-lever spans for the catalog `whatHappened` string. Each phrase
  // is an exact substring of the corresponding `LeverCards.<id>`
  // whatHappened in lib/domain/constants/app_defaults.dart.
  static const Map<String, List<_Span>> _whatHappened = {
    'covers_up': [
      _Span('check CPLH', '[[bad:'),
      _Span('the volume did work the schedule should have done', '[[bad:'),
    ],
    'covers_down': [
      _Span('the hours did not come down to meet the lighter volume',
          '[[bad:'),
      _Span('not a team problem', '[[good:'),
    ],
    'ppa_up': [
      _Span('the OPZ working as designed', '[[good:'),
    ],
    'ppa_down': [
      _Span('check-backs stop and upsells die', '[[bad:'),
      _Span('it is CPLH', '[[bad:'),
    ],
    'cplh_up': [
      _Span('landed below model', '[[good:'),
    ],
    'cplh_down': [
      _Span('paid for hours the volume never used', '[[bad:'),
    ],
    'splh_up': [
      _Span('right-sized for what came in', '[[good:'),
    ],
    'splh_down': [
      _Span('the leak is back of house', '[[bad:'),
    ],
    'foh_wage_up': [
      _Span('the cost on those hours was not', '[[bad:'),
    ],
    'foh_wage_down': [
      _Span('without sacrificing floor quality', '[[good:'),
    ],
    'boh_wage_up': [
      _Span('logging hours at a higher rate', '[[bad:'),
    ],
    'boh_wage_down': [
      _Span('without overtime or off-classification coverage', '[[good:'),
    ],
    'foh_hours_over': [
      _Span('the excess shows up as labor above model', '[[bad:'),
    ],
    'foh_hours_under': [
      _Span('check PPA before you call it a win', '[[bad:'),
    ],
    'boh_hours_over': [
      _Span('driving labor above theoretical', '[[bad:'),
    ],
    'boh_hours_under': [
      _Span('check SPLH and tickets', '[[bad:'),
    ],
  };

  // Per-lever spans for the catalog `teachingNote` (WHAT TO STUDY).
  static const Map<String, List<_Span>> _teachingNote = {
    'covers_up': [
      _Span('luck, not a system', '[[bad:'),
      _Span('the leak is the schedule', '[[bad:'),
    ],
    'covers_down': [
      _Span('the most common bleed', '[[bad:'),
    ],
    'ppa_up': [
      _Span('protect the staffing level that left room to sell', '[[good:'),
    ],
    'ppa_down': [
      _Span('a staffing pattern, not a people problem', '[[bad:'),
    ],
    'cplh_up': [
      _Span('only a win inside the zone', '[[bad:'),
    ],
    'cplh_down': [
      _Span('Fix the schedule input, not the team', '[[good:'),
    ],
    'splh_up': [
      _Span('protect that setup', '[[good:'),
    ],
    'splh_down': [
      _Span('inspect station load and throughput there', '[[bad:'),
    ],
    'foh_wage_up': [
      _Span('a roster pattern to fix', '[[bad:'),
    ],
    'foh_wage_down': [
      _Span('a deployment pattern worth banking', '[[good:'),
    ],
    'boh_wage_up': [
      _Span('a deployment pattern, not a general kitchen problem',
          '[[bad:'),
    ],
    'boh_wage_down': [
      _Span('study where it repeats', '[[good:'),
    ],
    'foh_hours_over': [
      _Span('the covers-down bleed seen from the hours side', '[[bad:'),
    ],
    'foh_hours_under': [
      _Span('where efficiency turns into understaffing', '[[bad:'),
    ],
    'boh_hours_over': [
      _Span('built above what the sales forecast supports there',
          '[[bad:'),
    ],
    'boh_hours_under': [
      _Span('where efficiency turns into understaffing', '[[bad:'),
    ],
  };

  // ── `.readline` narrative (mockup `.readline`) ─────────────────────
  // Render-time presentation copy, NOT catalog. Markup is inline. No
  // em/en dash. Drift fix (C): the read-line is now the FULL mockup
  // sentence with the inline colored dollar CHIPS fed the REAL per-axis
  // attribution (favourable axis → `[[chipg:+$N]]` green, unfavourable
  // → `[[chip:−$N]]` red) plus the net clause, exactly like the mockup
  // `.readline`. The mockup `#week` read-line (verbatim, `covers_up`):
  //
  //   Manage the variance, not the percentage. Covers were worth
  //   +$686 to the floor, but a soft CPLH cost −$462 and the kitchen's
  //   SPLH cost −$406. Net you finish −$247 below best possible, a
  //   loss this week. A good week that hides a soft CPLH is luck, not
  //   design.
  //
  // The read-line is built per render in three pieces so the chip
  // dollars come from REAL data and never a hardcoded amount:
  //
  //   1. lead maxim    — per-lever authored opener (`_leadMaxim`).
  //   2. dollar clause — built from the live per-axis attribution map:
  //      the dominant FAVOURABLE axis as a green chip + up to two
  //      dominant UNFAVOURABLE axes as red chips, then the signed net
  //      vs best possible as a red/green emphasised clause.
  //   3. closing maxim — per-lever authored close (`_closeMaxim`),
  //      carrying the V2-4 `[[bad:/[[good:` causal emphasis.
  //
  // When the card has no attribution map (legacy surfaces / tests with
  // no active target profile) the read-line degrades to lead + close
  // only (no fabricated chips) so word-preservation and the
  // non-rendering fallback stay intact.

  // Per-lever lead maxim (mockup read-line opener). Plain prose; no
  // markup needed (the emphasis lives in the dollar clause + close).
  static const Map<String, String> _leadMaxim = {
    'covers_up': 'Manage the variance, not the percentage.',
    'covers_down': 'Light covers with hours that did not flex is the most common bleed.',
    'ppa_up': 'PPA rises when the team has the floor to sell.',
    'ppa_down': 'Before you talk training, check CPLH.',
    'cplh_up': 'Efficient is only a win inside the zone.',
    'cplh_down': 'The schedule input is the lever, not the team.',
    'splh_up': 'A clean kitchen shift is worth copying.',
    'splh_down': 'Clean tickets mean overstaffing, slow tickets mean throughput.',
    'foh_wage_up': 'The hours were right, the cost on them was not.',
    'foh_wage_down': 'A favorable wage mix is a pattern, not an accident.',
    'boh_wage_up': 'Off-classification coverage drove the rate up.',
    'boh_wage_down': 'Kitchen deployment matched volume without premium hours.',
    'foh_hours_over': 'The floor carried hours the covers never needed.',
    'foh_hours_under': 'Lean is favorable until it crosses the ceiling.',
    'boh_hours_over': 'The kitchen carried hours the volume did not need.',
    'boh_hours_under': 'Lean kitchen hours are a win only if throughput held.',
  };

  // Per-lever closing maxim (mockup read-line close), V2-4 markup
  // inline. Mirrors the prior authored read-line tails.
  static const Map<String, String> _closeMaxim = {
    'covers_up': 'A good week that hides a soft CPLH is [[bad:luck, not design]].',
    'covers_down': '[[bad:Cut hours in real time]], do not wait for close.',
    'ppa_up': '[[good:Bank the staffing level]] that produced it.',
    'ppa_down': 'A team [[bad:run too lean cannot sell]].',
    'cplh_up': 'Above the ceiling the team was stretched even if the number looked good.',
    'cplh_down': 'Build FOH hours from [[good:covers divided by your CPLH target]], not from last week\'s sheet.',
    'splh_up': '[[good:Write the BOH lineup down]] before the next roster goes out.',
    'splh_down': '[[bad:Different problems, different fixes]].',
    'foh_wage_up': 'This is a deployment fix, not a performance talk.',
    'foh_wage_down': 'Replicate the [[good:role mix]] next week.',
    'boh_wage_up': 'The fix is [[bad:smarter pre-shift BOH deployment]].',
    'boh_wage_down': '[[good:Bank this configuration]].',
    'foh_hours_over': 'Cut before you open, not after you find out at close.',
    'foh_hours_under': '[[bad:Check PPA]] before you call it a win.',
    'boh_hours_over': 'Build BOH from forecast sales divided by target SPLH.',
    'boh_hours_under': 'Check SPLH and ticket times.',
  };

  // Axis display label for the dollar clause (mockup phrasing). Keyed
  // by the populated signed lever id.
  static const Map<String, String> _axisPhrase = {
    'covers_up': 'Covers',
    'covers_down': 'Covers',
    'ppa_up': 'PPA',
    'ppa_down': 'PPA',
    'cplh_up': 'CPLH',
    'cplh_down': 'a soft CPLH',
    'splh_up': "the kitchen's SPLH",
    'splh_down': "the kitchen's SPLH",
    'foh_wage_up': 'the FOH wage mix',
    'foh_wage_down': 'the FOH wage mix',
    'boh_wage_up': 'the BOH wage mix',
    'boh_wage_down': 'the BOH wage mix',
    'foh_hours_over': 'extra FOH hours',
    'foh_hours_under': 'lean FOH hours',
    'boh_hours_over': 'extra BOH hours',
    'boh_hours_under': 'lean BOH hours',
  };

  // The signed lever-id pairs, mirroring the attribution-section axes.
  // `attributeDollarImpactByAxis` populates at most one half of each
  // pair; summing yields the signed per-axis contribution (positive =
  // adverse, negative = favorable — the model's own convention).
  static const List<List<String>> _axisPairs = [
    ['covers_down', 'covers_up'],
    ['ppa_down', 'ppa_up'],
    ['cplh_down', 'cplh_up'],
    ['splh_down', 'splh_up'],
    ['foh_wage_down', 'foh_wage_up'],
    ['boh_wage_down', 'boh_wage_up'],
    ['foh_hours_under', 'foh_hours_over'],
    ['boh_hours_under', 'boh_hours_over'],
  ];

  /// Wrap the named V2-4 spans for [leverId] into [plain] (the verbatim
  /// catalog `whatHappened` string) and return the marked-up string.
  /// Words are preserved byte-for-byte: only the first occurrence of
  /// each exact phrase is wrapped, and an unknown id / a phrase that is
  /// not present is a no-op (the plain string is returned unchanged).
  static String emphasizeWhatHappened(String leverId, String plain) =>
      _apply(_whatHappened[leverId], plain);

  /// As [emphasizeWhatHappened] but for the catalog `teachingNote`
  /// (WHAT TO STUDY) string.
  static String emphasizeTeachingNote(String leverId, String plain) =>
      _apply(_teachingNote[leverId], plain);

  /// The render-time `.readline` narrative for [leverId] with V2-4
  /// markup inline, or null when the lever has no read-line (the card
  /// then omits the block). Never returns catalog prose.
  ///
  /// Drift fix (C): when [dollarImpactByAxis] is supplied (the live
  /// Primary Driver card always passes it), the read-line is the FULL
  /// mockup sentence — lead maxim + a per-axis dollar clause whose
  /// chips carry the REAL signed attribution (favourable axis green
  /// `[[chipg:+$N]]`, unfavourable axes red `[[chip:−$N]]`) + the
  /// signed net-vs-best-possible clause + the per-lever closing maxim.
  /// Chip dollars are read from [dollarImpactByAxis] only; nothing is
  /// hardcoded. With no map (legacy surfaces / tests) it degrades to
  /// `lead + close` so the non-rendering fallback stays clean.
  static String? readlineFor(
    String leverId, {
    Map<String, double>? dollarImpactByAxis,
  }) {
    final lead = _leadMaxim[leverId];
    final close = _closeMaxim[leverId];
    if (lead == null || close == null) return null;

    final map = dollarImpactByAxis;
    if (map == null) {
      // No attribution available → lead + close only (no fabricated
      // chips). Word-preservation + stripMarkup fallback unaffected.
      return '$lead $close';
    }

    // Signed per-axis contributions (positive = adverse / loss,
    // negative = favorable / gain — the model's own convention, the
    // same the attribution bars + arrow chain consume; no new math).
    final perAxis = <_AxisAmount>[];
    double net = 0;
    for (final pair in _axisPairs) {
      final v = (map[pair[0]] ?? 0) + (map[pair[1]] ?? 0);
      net += v;
      if (v.abs() < 1.0) continue; // ignore sub-$1 rounding noise (UX.1)
      // The populated signed id is the half whose sign matches: a
      // positive (adverse) value carries the `pair[1]` (`*_up` /
      // `*_over`) id for covers-style pairs, but the map only ever
      // populates one half, so pick the id whose value is non-zero.
      final signedId = (map[pair[1]] ?? 0) != 0 ? pair[1] : pair[0];
      perAxis.add(_AxisAmount(signedId, v));
    }

    // Dominant favourable axis (most negative) → green chip; the two
    // dominant adverse axes (most positive) → red chips. Mirrors the
    // mockup's "Covers worth +$686 ... soft CPLH cost −$462 and ...
    // SPLH cost −$406" structure, but driven by the live numbers.
    final favourable = perAxis.where((a) => a.value < 0).toList()
      ..sort((a, b) => a.value.compareTo(b.value)); // most negative first
    final adverse = perAxis.where((a) => a.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // most positive first

    final clauses = <String>[];
    if (favourable.isNotEmpty) {
      final f = favourable.first;
      final amt = Fmt.dollars(f.value.abs());
      // Favourable: shown as a green `+$N` chip (model negative =
      // favorable = a gain to the operator).
      clauses.add(
          '${_axisPhrase[f.signedId] ?? f.signedId} was worth [[chipg:+\$$amt]] to the floor');
    }
    final adverseClauses = <String>[];
    for (final a in adverse.take(2)) {
      final amt = Fmt.dollars(a.value.abs());
      // Adverse: shown as a red `−$N` chip (model positive = adverse =
      // a cost to the operator).
      adverseClauses.add(
          '${_axisPhrase[a.signedId] ?? a.signedId} cost [[chip:−\$$amt]]');
    }
    if (adverseClauses.isNotEmpty) {
      final joined = adverseClauses.length == 1
          ? adverseClauses.first
          : '${adverseClauses.first} and ${adverseClauses[1]}';
      clauses.add(clauses.isEmpty ? joined : 'but $joined');
    }

    // Net vs best possible. The model's net sign convention: positive
    // net = dollars LOST above best possible (a loss); non-positive =
    // at or under best possible (a win). Same predicate the hero +
    // arrow-chain result node use; no new math.
    final netAmt = Fmt.dollars(net.abs());
    final String netClause;
    if (net > 0) {
      netClause =
          'Net you finish [[bad:−\$$netAmt below best possible]], a loss this week.';
    } else {
      netClause =
          'Net you finish [[good:+\$$netAmt above best possible]], a win this week.';
    }

    final dollarSentence =
        clauses.isEmpty ? '' : '${clauses.join(', ')}. ';
    return '$lead $dollarSentence$netClause $close';
  }

  static String _apply(List<_Span>? spans, String plain) {
    if (spans == null || spans.isEmpty) return plain;
    var out = plain;
    for (final span in spans) {
      final idx = out.indexOf(span.phrase);
      if (idx < 0) continue; // phrase not present → leave prose untouched
      // Wrap only this one occurrence. The inner text is the verbatim
      // phrase; `InlineEmphasisMarkup.stripMarkup` restores it exactly.
      out = out.replaceRange(
        idx,
        idx + span.phrase.length,
        '${span.token}${span.phrase}]]',
      );
    }
    return out;
  }

  /// Test/diagnostic helper: assert every named span for [leverId]
  /// round-trips (the wrapped string strips back to the input). Returns
  /// true when the markup is non-destructive for both maps.
  static bool roundTrips(String leverId, String whatHappened,
      String teachingNote) {
    final wh = emphasizeWhatHappened(leverId, whatHappened);
    final ws = emphasizeTeachingNote(leverId, teachingNote);
    return InlineEmphasisMarkup.stripMarkup(wh) == whatHappened &&
        InlineEmphasisMarkup.stripMarkup(ws) == teachingNote;
  }
}
