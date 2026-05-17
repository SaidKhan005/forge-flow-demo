// ─── MoneySentiment - global sign + sentiment convention (V2-2) ─────────────
//
// Single source of truth for the Variance Coaching V2 sign / sentiment
// rule. Binding spec: docs/contracts/phase_7_58_primary_driver_contract.md
// "V2-2. Sign + sentiment convention (global, explicit)" and the
// reconciliation memo docs/_audits/variance_coaching_v2/
// driver_logic_reconciliation.md Subject 5b.
//
// Rule (verbatim from the contract):
//   - A loss reads as a negative dollar value, in red, with "below" /
//     "lost" language. Glyph: minus sign `−` (U+2212).
//   - A profit reads as a positive dollar value, in green, with "above"
//     language. Glyph: plus sign `+`.
//   - Color is driven by a favorable / unfavorable flag, NEVER by the
//     raw arithmetic sign of the underlying number. The sign glyph and
//     the favorable flag are decided together from the SAME sentiment
//     source, so the displayed sign and the color never disagree.
//
// This type is the only place that maps a sentiment decision onto a
// `(color, glyph)` pair. Renderers MUST construct it from a sentiment
// source (`LeverCardData.isFavorable` / `CrossAxisPairData.isFavorable` /
// `LaborModel.isFavorableLever` for lever-keyed rows, or an explicit
// loss-vs-gain predicate for the hero / dollar-impact projection rows)
// and MUST NOT re-derive color from `value > 0`.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MoneySentiment {
  /// True when the value is favorable to the operator (a gain): green, `+`.
  /// False when unfavorable (a loss): red, `−` (U+2212).
  final bool favorable;

  const MoneySentiment._(this.favorable);

  /// Construct from a sentiment decision already made by the caller
  /// (e.g. a catalog `isFavorable` flag or `LaborModel.isFavorableLever`).
  /// The boolean IS the sentiment source; color + glyph follow it.
  const MoneySentiment.fromFavorable(bool isFavorable)
      : favorable = isFavorable;

  /// Explicit loss-vs-gain predicate for the hero and the dollar-impact
  /// projection rows. A positive dollar gap is an over-model amount the
  /// operator LOST (unfavorable); a non-positive gap is at-or-under the
  /// best-possible floor (favorable). This is an operator-meaning
  /// predicate, not a raw `value > 0` color rule: the glyph and color
  /// are both produced from this single decision below.
  factory MoneySentiment.fromDollarGap(double gap) =>
      MoneySentiment._(gap <= 0);

  /// Sentiment for a per-axis dollar-attribution contribution. The
  /// engine (`LaborModel.attributeDollarImpactByAxis`) pre-encodes
  /// sentiment in the SIGN of the contribution: positive = adverse,
  /// negative = favorable. We capture that single model decision here
  /// so the renderer's color and glyph come from one source and the
  /// twin independent `value > 0` derivation (Subject 5b) is removed.
  /// The engine is unchanged; this only reads its existing sign.
  factory MoneySentiment.fromAxisImpact(double contribution) =>
      MoneySentiment._(contribution <= 0);

  /// Red for a loss, green for a gain. Driven by [favorable], never by
  /// the arithmetic sign of any number.
  Color get color => favorable ? AppColors.positive : AppColors.negative;

  /// `+` for a gain, `−` (U+2212) for a loss. Decided together with
  /// [color] from the same [favorable] source so they never disagree.
  String get sign => favorable ? '+' : '−';
}
