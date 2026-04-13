// Phase 7.55e.1 — Immutable distribution weights computed from closed ShiftRecords.
//
// Holds raw cover totals by dayLabel and dayLabel+daypart.
// Weights are integer cover sums, not percentages — downstream allocation
// (7.55e.2) will use largest-remainder logic for deterministic rounding.
//
// Phase 7.55m.1a: canonicalDayOrder now delegates to the shared
// CanonicalDayOrder source in lib/domain/canonical_day_order.dart.

import '../canonical_day_order.dart';

class ScheduleDistributionWeights {
  /// Canonical day ordering used throughout the schedule domain.
  ///
  /// Delegates to [CanonicalDayOrder.labels] — the single shared source.
  static const canonicalDayOrder = CanonicalDayOrder.labels;

  /// Total closed covers per dayLabel (e.g. {'Mon': 840, 'Tue': 920, ...}).
  /// Only includes positive-cover closed shifts. Unmodifiable.
  final Map<String, int> dayWeights;

  /// Day-specific daypart cover weights.
  /// e.g. {'Mon': {'lunch': 350, 'dinner': 490}, 'Sat': {'dinner': 600, ...}}.
  /// Unmodifiable (both outer and inner maps).
  final Map<String, Map<String, int>> daypartWeightsByDay;

  /// Number of closed ShiftRecords considered (before cover filtering).
  final int closedShiftCount;

  /// Number of distinct closed business days (weekId|dayLabel keys).
  final int closedBusinessDayCount;

  /// Sum of positive covers from closed shifts used in weight totals.
  final int totalCovers;

  /// True when history is sufficient to produce reliable weights.
  /// Requires closedBusinessDayCount >= threshold, totalCovers > 0,
  /// and at least one day weight entry.
  final bool isAvailable;

  const ScheduleDistributionWeights._({
    required this.dayWeights,
    required this.daypartWeightsByDay,
    required this.closedShiftCount,
    required this.closedBusinessDayCount,
    required this.totalCovers,
    required this.isAvailable,
  });

  /// Construct an available weights instance with unmodifiable maps.
  factory ScheduleDistributionWeights.available({
    required Map<String, int> dayWeights,
    required Map<String, Map<String, int>> daypartWeightsByDay,
    required int closedShiftCount,
    required int closedBusinessDayCount,
    required int totalCovers,
  }) {
    return ScheduleDistributionWeights._(
      dayWeights: Map.unmodifiable(dayWeights),
      daypartWeightsByDay: Map.unmodifiable(
        daypartWeightsByDay.map(
          (day, parts) => MapEntry(day, Map<String, int>.unmodifiable(parts)),
        ),
      ),
      closedShiftCount: closedShiftCount,
      closedBusinessDayCount: closedBusinessDayCount,
      totalCovers: totalCovers,
      isAvailable: true,
    );
  }

  /// Construct an unavailable weights instance — counts are preserved,
  /// weight maps are empty, isAvailable is false.
  factory ScheduleDistributionWeights.unavailable({
    required int closedShiftCount,
    required int closedBusinessDayCount,
    required int totalCovers,
  }) {
    return ScheduleDistributionWeights._(
      dayWeights: const {},
      daypartWeightsByDay: const {},
      closedShiftCount: closedShiftCount,
      closedBusinessDayCount: closedBusinessDayCount,
      totalCovers: totalCovers,
      isAvailable: false,
    );
  }

  /// Returns the daypart weights for the given dayLabel,
  /// or an empty unmodifiable map if the day has no data.
  Map<String, int> daypartWeightsFor(String dayLabel) {
    return daypartWeightsByDay[dayLabel] ?? const {};
  }

  /// Day weights in canonical Mon-Sun order as a list of (dayLabel, weight)
  /// pairs. Days not present in dayWeights get weight 0.
  List<(String, int)> get orderedDayWeights {
    return [
      for (final day in canonicalDayOrder) (day, dayWeights[day] ?? 0),
    ];
  }
}
