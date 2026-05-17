// === LearnEmphasisMap : Variance Coaching V2 (Lane R-LRN) ==================
// The render-time inline-emphasis map for the Learn story-frame cards
// (Recurring Leak / Repeatable Wins 3-frame stories + the Cross-Axis
// 4-pair cards).
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md V2-4
// ("Inline-emphasis markup convention") + the approved mockup
// docs/f&f Coaching/variance_tab_v2_mockup.html `#learn` (`.lc` frame
// cards: `.em-bad` / `.em-good` causal emphasis spans inside the body
// prose, e.g. `... and you paid for [[bad:hours the volume never
// used]]. The kitchen was fine ...`).
//
// V2-4 hard rules honoured here (mirrors the This Week
// `LeverEmphasisMap` discipline; this is the file-disjoint Learn-lane
// sibling so the two lanes stay parallel-safe):
//
//   - Catalog strings stay byte-for-byte PLAIN. This map carries NO
//     copy of the catalog prose. It only names exact substrings that
//     already exist in the plain catalog `whatHappened` / `whatToDo` /
//     `teachingNote` string for a lever id or a cross-axis pair id,
//     plus the V2-4 token each span is promoted to. `emphasize*` wraps
//     those spans at RENDER time; it never adds, drops, or reorders a
//     word, so
//     `InlineEmphasisMarkup.stripMarkup(emphasizeWhatHappened(id, p))`
//     is provably equal to `p`. The Learn frame TEXT is therefore
//     byte-identical to today's catalog-derived content; only emphasis
//     is added.
//   - Only the four V2-4 causal tokens are produced (`[[bad:` /
//     `[[good:`); chips are not span-wrapped into catalog prose. No
//     string literal in this file is operator-facing copy: every
//     literal is either an exact substring of the locked catalog
//     (`lib/domain/constants/app_defaults.dart` `LeverCards`,
//     `lib/domain/constants/cross_axis_pair_catalog.dart`
//     `CrossAxisPairs`) or a V2-4 token. No em dash (U+2014) / en dash
//     (U+2013) appears in any literal.
//   - An id with no entry, or a span phrase not present in the passed
//     string, degrades cleanly: the plain string is returned unchanged.
//     The honest-fallback frames (`NO PATTERNS YET` /
//     `NO REPEATABLE WINS YET`) never reach this map.

import '../variance/inline_emphasis_text.dart';

/// One causal span to promote inside an already-plain catalog sentence.
/// [phrase] MUST be an exact, unique substring of the target catalog
/// string; [token] is the V2-4 markup the renderer wraps it in.
class _Span {
  const _Span(this.phrase, this.token);

  /// The verbatim substring as it appears in the plain catalog string.
  final String phrase;

  /// The V2-4 open token for this span: `[[bad:` / `[[good:`.
  final String token;
}

/// Render-time emphasis source for the Learn frames. Keyed by the same
/// ids the Learn wiring already resolves: `LeverCards.<id>` for the
/// Recurring Leak / Repeatable Wins stories, `CrossAxisPairs.<id>` for
/// the Cross-Axis pair cards.
class LearnEmphasisMap {
  const LearnEmphasisMap._();

  // ── Recurring Leak / Repeatable Wins (single-axis LeverCards) ──────────
  //
  // Each phrase is an exact substring of the corresponding
  // `LeverCards.<id>` field in lib/domain/constants/app_defaults.dart.
  // The Learn wiring renders:
  //   Frame 1 body = card.whatHappened
  //   Frame 2 body = card.teachingNote
  //   Frame 3 body + THE PLAY = card.whatToDo
  // so all three fields carry a map.

  static const Map<String, List<_Span>> _whatHappened = {
    'covers_down': [
      _Span('Fewer guests walked in than the schedule was built for',
          '[[bad:'),
      _Span('not a team problem', '[[good:'),
    ],
    'covers_up': [
      _Span('the team carried them on the hours already scheduled',
          '[[good:'),
      _Span('the volume did work the schedule should have done',
          '[[bad:'),
    ],
    'ppa_down': [
      _Span('check-backs stop and upsells die', '[[bad:'),
    ],
    'ppa_up': [
      _Span('the OPZ working as designed', '[[good:'),
    ],
    'cplh_down': [
      _Span('paid for hours the volume never used', '[[bad:'),
      _Span('BOH is unaffected', '[[good:'),
    ],
    'cplh_up': [
      _Span('FOH labor landed below model', '[[good:'),
    ],
    'splh_down': [
      _Span('the leak is back of house', '[[bad:'),
    ],
    'splh_up': [
      _Span('right-sized for what came in', '[[good:'),
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
      _Span('fewer servers covered more guests', '[[good:'),
    ],
    'boh_hours_over': [
      _Span('driving labor above theoretical', '[[bad:'),
    ],
    'boh_hours_under': [
      _Span('fewer hours covered more output', '[[good:'),
    ],
  };

  static const Map<String, List<_Span>> _teachingNote = {
    'covers_down': [
      _Span('the most common bleed', '[[bad:'),
    ],
    'covers_up': [
      _Span('luck, not a system', '[[bad:'),
      _Span('the leak is the schedule', '[[bad:'),
    ],
    'ppa_down': [
      _Span('a staffing pattern, not a people problem', '[[bad:'),
    ],
    'ppa_up': [
      _Span('protect the staffing level that left room to sell',
          '[[good:'),
    ],
    'cplh_down': [
      _Span('Fix the schedule input, not the team', '[[good:'),
    ],
    'cplh_up': [
      _Span('only a win inside the zone', '[[bad:'),
    ],
    'splh_down': [
      _Span('inspect station load and throughput there', '[[bad:'),
    ],
    'splh_up': [
      _Span('protect that setup', '[[good:'),
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

  static const Map<String, List<_Span>> _whatToDo = {
    'covers_down': [
      _Span('cut hours in real time', '[[good:'),
    ],
    'covers_up': [
      _Span('that is a benchmark', '[[good:'),
    ],
    'ppa_down': [
      _Span('the fix is staffing level, not a coaching conversation',
          '[[good:'),
    ],
    'ppa_up': [
      _Span('This is a benchmark shift', '[[good:'),
    ],
    'cplh_down': [
      _Span('That number is your required FOH hours', '[[good:'),
      _Span('not from last week\'s sheet', '[[bad:'),
    ],
    'cplh_up': [
      _Span('that is your replicable setup', '[[good:'),
    ],
    'splh_down': [
      _Span('Different problems, different fixes', '[[bad:'),
    ],
    'splh_up': [
      _Span('That is your replicable kitchen setup', '[[good:'),
    ],
    'foh_wage_up': [
      _Span('not a performance conversation', '[[good:'),
    ],
    'foh_wage_down': [
      _Span('Replicate the deployment pattern next week', '[[good:'),
    ],
    'boh_wage_up': [
      _Span('smarter pre-shift BOH deployment', '[[good:'),
    ],
    'boh_wage_down': [
      _Span('It is your benchmark kitchen configuration', '[[good:'),
    ],
    'foh_hours_over': [
      _Span('cut before you open, not after you find out at close',
          '[[good:'),
    ],
    'foh_hours_under': [
      _Span('it is your benchmark', '[[good:'),
      _Span('the floor was too lean to sell', '[[bad:'),
    ],
    'boh_hours_over': [
      _Span('tighten there', '[[good:'),
    ],
    'boh_hours_under': [
      _Span('that is your replicable setup', '[[good:'),
      _Span('the kitchen was stretched too thin', '[[bad:'),
    ],
  };

  // ── Cross-Axis pair cards (CrossAxisPairs) ─────────────────────────────
  //
  // Each phrase is an exact substring of the corresponding
  // `CrossAxisPairs.<id>` field in
  // lib/domain/constants/cross_axis_pair_catalog.dart. The Cross-Axis
  // card renders all three labelled blocks (What happened / What to do /
  // What to study -> whatHappened / whatToDo / teachingNote).

  static const Map<String, List<_Span>> _xWhatHappened = {
    'cplh_below_splh_above': [
      _Span('everyone who came spent well and was served right',
          '[[good:'),
      _Span('This is not an execution miss', '[[good:'),
    ],
    'cplh_on_splh_below': [
      _Span('The kitchen did not keep pace', '[[bad:'),
    ],
    'cplh_above_splh_below': [
      _Span('The dining room covered more guests with fewer hours',
          '[[good:'),
      _Span('The kitchen lagged on sales per BOH hour', '[[bad:'),
    ],
    'both_below': [
      _Span('Both sides carried more hours than the volume needed',
          '[[bad:'),
    ],
  };

  static const Map<String, List<_Span>> _xWhatToDo = {
    'cplh_below_splh_above': [
      _Span('Fix the forecast, not the floor', '[[good:'),
    ],
    'cplh_on_splh_below': [
      _Span('Different problems, different fixes', '[[bad:'),
    ],
    'cplh_above_splh_below': [
      _Span('it is a benchmark', '[[good:'),
    ],
    'both_below': [
      _Span('Check the outside world first', '[[good:'),
    ],
  };

  static const Map<String, List<_Span>> _xTeachingNote = {
    'cplh_below_splh_above': [
      _Span('a volume problem, not a people problem', '[[bad:'),
    ],
    'cplh_on_splh_below': [
      _Span('the diagnosis lives in BOH deployment or throughput',
          '[[bad:'),
    ],
    'cplh_above_splh_below': [
      _Span('two stories on one shift', '[[bad:'),
    ],
    'both_below': [
      _Span('look outside the building first', '[[good:'),
    ],
  };

  /// Wrap the named V2-4 spans for the Recurring Leak / Repeatable Wins
  /// lever [leverId] into [plain] (the verbatim catalog `whatHappened`
  /// string) and return the marked-up string. Words are preserved
  /// byte-for-byte: only the first occurrence of each exact phrase is
  /// wrapped; an unknown id / a phrase not present is a no-op.
  static String emphasizeWhatHappened(String leverId, String plain) =>
      _apply(_whatHappened[leverId], plain);

  /// As [emphasizeWhatHappened] but for the catalog `teachingNote`
  /// (Frame 2 / WHY IT MATTERS body).
  static String emphasizeTeachingNote(String leverId, String plain) =>
      _apply(_teachingNote[leverId], plain);

  /// As [emphasizeWhatHappened] but for the catalog `whatToDo`
  /// (Frame 3 / WHAT TO DO body + THE PLAY).
  static String emphasizeWhatToDo(String leverId, String plain) =>
      _apply(_whatToDo[leverId], plain);

  /// Cross-Axis pair card: emphasise the `whatHappened` block.
  static String emphasizeCrossWhatHappened(String pairId, String plain) =>
      _apply(_xWhatHappened[pairId], plain);

  /// Cross-Axis pair card: emphasise the `whatToDo` block.
  static String emphasizeCrossWhatToDo(String pairId, String plain) =>
      _apply(_xWhatToDo[pairId], plain);

  /// Cross-Axis pair card: emphasise the `teachingNote` (What to study)
  /// block.
  static String emphasizeCrossTeachingNote(String pairId, String plain) =>
      _apply(_xTeachingNote[pairId], plain);

  static String _apply(List<_Span>? spans, String plain) {
    if (spans == null || spans.isEmpty) return plain;
    var out = plain;
    for (final span in spans) {
      final idx = out.indexOf(span.phrase);
      if (idx < 0) continue; // phrase not present -> prose untouched
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

  /// Test/diagnostic helper: assert every named span for a single-axis
  /// [leverId] round-trips (the wrapped string strips back to the
  /// input) across all three rendered fields.
  static bool leverRoundTrips(
    String leverId,
    String whatHappened,
    String teachingNote,
    String whatToDo,
  ) {
    final wh = emphasizeWhatHappened(leverId, whatHappened);
    final tn = emphasizeTeachingNote(leverId, teachingNote);
    final wd = emphasizeWhatToDo(leverId, whatToDo);
    return InlineEmphasisMarkup.stripMarkup(wh) == whatHappened &&
        InlineEmphasisMarkup.stripMarkup(tn) == teachingNote &&
        InlineEmphasisMarkup.stripMarkup(wd) == whatToDo;
  }

  /// Test/diagnostic helper: assert every named span for a Cross-Axis
  /// [pairId] round-trips across all three rendered blocks.
  static bool crossRoundTrips(
    String pairId,
    String whatHappened,
    String whatToDo,
    String teachingNote,
  ) {
    final wh = emphasizeCrossWhatHappened(pairId, whatHappened);
    final wd = emphasizeCrossWhatToDo(pairId, whatToDo);
    final tn = emphasizeCrossTeachingNote(pairId, teachingNote);
    return InlineEmphasisMarkup.stripMarkup(wh) == whatHappened &&
        InlineEmphasisMarkup.stripMarkup(wd) == whatToDo &&
        InlineEmphasisMarkup.stripMarkup(tn) == teachingNote;
  }
}
