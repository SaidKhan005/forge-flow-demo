// 7.58.cross-axis.0: sibling catalog to LeverCards for the
// CPLH x SPLH cross-axis pair pattern.
//
// Authority:
//   * docs/contracts/phase_7_58_primary_driver_contract.md
//     "Depth Surfaces" addendum (locked catalog: 4 entries).
//   * docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md
//     Chapter 07 (CPLH and SPLH Together): source matrix.
//   * docs/Knowledge_graph_docs/Bold By Design.md Chapter 10:
//     productivity curve and lever framework.
//
// Mirrors the LeverCardData shape so consumer widgets can resolve a
// pair entry the same way they resolve a single-axis lever entry.
// The single-axis catalog (LeverCards.all) stays the source of truth
// for all single-axis surfaces; this sibling catalog activates only
// when the cross-axis analyzer detects a recurring CPLH x SPLH pair
// pattern in the closed-shift HistoryPatternRecord set.
//
// LOCKED at 4 entries for V1. Adding a 5th entry requires a contract
// revision PR (same gate as LeverCards). Zero em dashes anywhere in
// this file: use period, colon, or middot. The history_cross_axis
// pattern test pins the rule across the whole file.

import 'app_defaults.dart';

class CrossAxisPairData {
  /// Stable id matching CrossAxisPairRecord.pairId.
  final String id;

  /// Headline copy. Equivalent role to LeverCardData.metric.
  final String metric;

  /// Cause category badge: equivalent to LeverCardData.causeCategory.
  final String causeCategory;

  /// Side affinity (FOH-only, BOH-only, or both). Equivalent to
  /// LeverCardData.side.
  final LeverSide side;

  /// Direction (favorable vs unfavorable). Equivalent to
  /// LeverCardData.direction.
  final LeverDirection direction;

  /// What the operator is looking at: equivalent to
  /// LeverCardData.whatHappened.
  final String whatHappened;

  /// Operator action: equivalent to LeverCardData.whatToDo.
  final String whatToDo;

  /// Teaching note: equivalent to LeverCardData.teachingNote.
  final String teachingNote;

  /// Short badge label: equivalent to LeverCardData.shortLabel.
  final String shortLabel;

  /// True when the pair is favorable (green); false when unfavorable
  /// (red). Equivalent to LeverCardData.isFavorable.
  final bool isFavorable;

  const CrossAxisPairData({
    required this.id,
    required this.metric,
    required this.causeCategory,
    required this.side,
    required this.direction,
    required this.whatHappened,
    required this.whatToDo,
    required this.teachingNote,
    required this.shortLabel,
    required this.isFavorable,
  });

  /// Side label (mirrors LeverCardData.sideLabel).
  String get sideLabel {
    switch (side) {
      case LeverSide.foh:
        return 'FOH ONLY';
      case LeverSide.boh:
        return 'BOH ONLY';
      case LeverSide.both:
        return 'BOTH SIDES';
    }
  }
}

class CrossAxisPairs {
  static const cplhBelowSplhAbove = CrossAxisPairData(
    id: 'cplh_below_splh_above',
    metric: 'FORECAST WAS LOW. TEAM EXECUTED.',
    causeCategory: 'FORECAST',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'CPLH ran below target. SPLH ran above target. Fewer covers came in '
        'than the schedule was built for, but every guest who walked in spent '
        'generously. The team executed well on the volume that arrived. The '
        'restaurant was carrying more FOH hours than the actual cover pace '
        'required.',
    whatToDo:
        'Adjust the cover forecast for next week before you build the FOH '
        'schedule. The fix is in the forecast, not on the floor. Pull the '
        'pattern back to your weekly forecast review and re-anchor covers to '
        'what the restaurant is actually doing.',
    teachingNote:
        'Jim Taylor Ch. 7: CPLH below + SPLH above is a volume problem, not '
        'an execution problem. If this repeats in the same dayparts, the '
        'forecast is running high and the schedule is being built above '
        'actual demand. Fix the forecast input. Protect the team that '
        'executed.',
    shortLabel: 'FORECAST',
    isFavorable: false,
  );

  static const cplhOnSplhBelow = CrossAxisPairData(
    id: 'cplh_on_splh_below',
    metric: 'KITCHEN SLOWED. DINING ROOM HELD.',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'CPLH landed on target. SPLH ran below target. The dining room '
        'matched the plan: covers came in at forecast and FOH hours flexed '
        'to volume. The kitchen did not keep pace: sales per BOH labor hour '
        'fell short of model. The leak is on the back of the house.',
    whatToDo:
        'Pull the kitchen ticket-time logs and BOH hours against actual '
        'sales for this daypart. If ticket times were clean, BOH was '
        'overstaffed for the volume. If ticket times slipped, throughput is '
        'the constraint. They are different problems with different fixes.',
    teachingNote:
        'Jim Taylor Ch. 7: when only the kitchen axis moves and the dining '
        'room held, the diagnosis lives in BOH deployment or throughput. If '
        'this repeats in the same BOH dayparts, inspect station load and '
        'prep readiness there. FOH does not need attention this round.',
    shortLabel: 'KITCHEN',
    isFavorable: false,
  );

  static const cplhAboveSplhBelow = CrossAxisPairData(
    id: 'cplh_above_splh_below',
    metric: 'TEAM RAN LEAN. KITCHEN SLOWED.',
    causeCategory: 'CROSS AXIS',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'CPLH ran above target. SPLH ran below target. The dining room '
        'covered more guests with fewer hours: FOH was efficient. The '
        'kitchen lagged: sales per BOH labor hour came in under model. The '
        'two sides moved in opposite directions on the same shift.',
    whatToDo:
        'Cross-check PPA before you call this a win. If PPA held, the FOH '
        'configuration is your benchmark: document the deployment. The BOH '
        'side needs a separate look: pull ticket times and station '
        'assignments. Fix the kitchen leak without dismantling the FOH '
        'pattern that worked.',
    teachingNote:
        'Jim Taylor Ch. 7: opposite-axis movement is two stories on one '
        'shift. Treat the lean FOH side as a benchmark candidate. Treat the '
        'slow kitchen side as a leak that needs its own root cause. Do not '
        'average them into a single take.',
    shortLabel: 'CROSS AXIS',
    isFavorable: false,
  );

  static const bothBelow = CrossAxisPairData(
    id: 'both_below',
    metric: 'DEMAND WAS SOFT.',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'CPLH ran below target. SPLH ran below target. Fewer covers came in '
        'and the guests who did come in spent less than usual. Both sides '
        'of the house carried more hours than the volume needed. The leak '
        'is upstream of execution.',
    whatToDo:
        'Check the external context first: weather, a competing event, a '
        'day-of-week anomaly. If the cause is external, log the soft '
        'daypart and protect the schedule pattern for the next normal '
        'week. If demand is softening structurally, re-anchor next week\'s '
        'forecast and trim FOH and BOH hours together.',
    teachingNote:
        'Jim Taylor Ch. 7: when both axes drop together, the question is '
        'whether the cause is external (one-off) or structural (forecast '
        'is stale). Tag the external cause when you can. If the soft '
        'daypart repeats without an external explanation, the forecast is '
        'overstating demand.',
    shortLabel: 'DEMAND',
    isFavorable: false,
  );

  /// Locked catalog: 4 entries for V1. Adding a 5th entry requires a
  /// contract revision PR.
  static const List<CrossAxisPairData> all = [
    cplhBelowSplhAbove,
    cplhOnSplhBelow,
    cplhAboveSplhBelow,
    bothBelow,
  ];

  /// Resolve a pair id to its catalog entry. Returns null for unknown
  /// or empty input. Mirrors LeverCards.lookup semantics.
  static CrossAxisPairData? lookup(String? id) {
    if (id == null || id.isEmpty) return null;
    final normalized = id.toLowerCase();
    for (final entry in all) {
      if (entry.id == normalized) return entry;
    }
    return null;
  }
}
