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
//     is authored once per lever with the V2-4 markup inline, and is the
//     ONLY string literal in this file. No em dash (U+2014) / en dash
//     (U+2013) appears in any literal.
//   - A lever id with no entry degrades cleanly: `emphasize` returns the
//     plain string unchanged and `readlineFor` returns null (the card
//     simply omits the read-line). The degraded `LeverCardNotYetAvailable`
//     path never reaches this map.

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

  // The `.readline` narrative (mockup `.readline`). Render-time
  // presentation copy, NOT catalog. Markup is inline. No em/en dash.
  static const Map<String, String> _readline = {
    'covers_up':
        'Manage the variance, not the percentage. A good week that hides a soft CPLH is [[bad:luck, not design]].',
    'covers_down':
        'Light covers with hours that did not flex is the most common bleed. [[bad:Cut hours in real time]], do not wait for close.',
    'ppa_up':
        'PPA rises when the team has the floor to sell. [[good:Bank the staffing level]] that produced it.',
    'ppa_down':
        'Before you talk training, check CPLH. A team [[bad:run too lean cannot sell]].',
    'cplh_up':
        'Efficient is only a win [[good:inside the zone]]. Above the ceiling the team was stretched even if the number looked good.',
    'cplh_down':
        'Build FOH hours from [[good:covers divided by your CPLH target]], not from last week\'s sheet.',
    'splh_up':
        'A clean kitchen shift is worth copying. [[good:Write the BOH lineup down]] before the next roster goes out.',
    'splh_down':
        'Clean tickets mean overstaffing, slow tickets mean throughput. [[bad:Different problems, different fixes]].',
    'foh_wage_up':
        'The hours were right, the [[bad:cost on them was not]]. This is a deployment fix, not a performance talk.',
    'foh_wage_down':
        'A favorable wage mix is a [[good:deployment pattern worth banking]]. Replicate the role mix next week.',
    'boh_wage_up':
        'Off-classification coverage drove the rate up. The fix is [[bad:smarter pre-shift BOH deployment]].',
    'boh_wage_down':
        'Kitchen deployment matched volume without premium hours. [[good:Bank this configuration]].',
    'foh_hours_over':
        'The floor carried [[bad:hours the covers never needed]]. Cut before you open, not after you find out at close.',
    'foh_hours_under':
        'Lean is favorable until it crosses the ceiling. [[bad:Check PPA]] before you call it a win.',
    'boh_hours_over':
        'The kitchen carried [[bad:hours the volume did not need]]. Build BOH from forecast sales divided by target SPLH.',
    'boh_hours_under':
        'Lean kitchen hours are a win only if [[good:throughput held]]. Check SPLH and ticket times.',
  };

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
  static String? readlineFor(String leverId) => _readline[leverId];

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
