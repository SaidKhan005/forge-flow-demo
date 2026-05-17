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
    metric: 'Forecast was low. The team executed.',
    causeCategory: 'FORECAST',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Fewer guests walked in than the schedule was built for, but everyone who came spent well and was served right. This is not an execution miss. The floor did its job on the volume that showed up.',
    whatToDo:
        'Fix the forecast, not the floor. Re-anchor next week’s covers to what the restaurant is actually doing, then build FOH hours from covers divided by your CPLH target. Leave the team that executed alone.',
    teachingNote:
        'CPLH below with SPLH above is a volume problem, not a people problem. If it repeats in the same dayparts, the forecast is running high and the schedule is built above real demand.',
    shortLabel: 'FORECAST',
    isFavorable: false,
  );

  static const cplhOnSplhBelow = CrossAxisPairData(
    id: 'cplh_on_splh_below',
    metric: 'Kitchen slowed. Dining room held.',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Covers came in at forecast and FOH flexed to them. The kitchen did not keep pace: sales per BOH hour fell short. The leak is on the back of the house only.',
    whatToDo:
        'Pull kitchen ticket times and BOH hours against actual sales for this daypart. Clean tickets mean BOH was overstaffed for the volume. Slow tickets mean throughput is the constraint. Different problems, different fixes. FOH needs nothing this round.',
    teachingNote:
        'When only the kitchen axis moves, the diagnosis lives in BOH deployment or throughput. Watch station load and prep readiness in the dayparts where it repeats.',
    shortLabel: 'KITCHEN',
    isFavorable: false,
  );

  static const cplhAboveSplhBelow = CrossAxisPairData(
    id: 'cplh_above_splh_below',
    metric: 'Floor ran lean. Kitchen slowed.',
    causeCategory: 'CROSS AXIS',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The dining room covered more guests with fewer hours, which is efficient. The kitchen lagged on sales per BOH hour. Two different stories on the same shift, moving opposite ways.',
    whatToDo:
        'Check PPA before you call the floor a win. If PPA held, document the FOH deployment: it is a benchmark. Then look at the kitchen on its own: ticket times and station assignments. Fix the kitchen without breaking the FOH pattern that worked.',
    teachingNote:
        'Opposite-axis movement is two stories on one shift. Bank the lean FOH side as a benchmark. Treat the slow kitchen as its own root cause. Do not average them into one take.',
    shortLabel: 'CROSS AXIS',
    isFavorable: false,
  );

  static const bothBelow = CrossAxisPairData(
    id: 'both_below',
    metric: 'Demand was soft.',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Fewer covers came in and the guests who did spent less. Both sides carried more hours than the volume needed. The leak is upstream of execution.',
    whatToDo:
        'Check the outside world first: weather, a nearby event, a day-of-week anomaly. If it was external, log the soft daypart and protect the schedule for the next normal week. If demand is softening for real, re-anchor the forecast and trim FOH and BOH hours together.',
    teachingNote:
        'Both axes down together is the one case you look outside the building first. A one-off external cause, tag it and move on. Repeats with no explanation mean the forecast is overstating demand.',
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
