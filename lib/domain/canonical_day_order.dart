// Phase 7.55m.1a — Canonical day-of-week ordering constants.
//
// Single source of truth for Mon–Sun day ordering used by both:
//   - BusinessDateAuthorityService (planning-anchor helpers)
//   - ScheduleDistributionWeights (schedule distribution ordering)
//   - DistributionWeightBuilder (smoothed weight iteration)
//   - ShiftService (day-number display helpers)
//   - BaselineManagerService (candidate sorting)
//
// Lives in the domain layer so domain models can reference it without
// importing data-layer services.

/// Canonical day-of-week ordering constants.
///
/// All day-ordering in the planning stack and schedule domain should
/// derive from this single source.
class CanonicalDayOrder {
  const CanonicalDayOrder._();

  /// Day-of-week labels in canonical Mon–Sun order.
  static const List<String> labels = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  /// Mon–Sun day ordering as a 0-based index map.
  ///
  /// Useful for sorting and comparison where a numeric index is needed.
  static const Map<String, int> index = {
    'Mon': 0,
    'Tue': 1,
    'Wed': 2,
    'Thu': 3,
    'Fri': 4,
    'Sat': 5,
    'Sun': 6,
  };

  /// Full day-of-week names indexed by 1-based day number.
  ///
  /// 1 = Monday, 7 = Sunday. Derived from [index] for display convenience.
  static const Map<int, String> fullNames = {
    1: 'Monday',
    2: 'Tuesday',
    3: 'Wednesday',
    4: 'Thursday',
    5: 'Friday',
    6: 'Saturday',
    7: 'Sunday',
  };

  /// Returns the 1-based day number for [dayLabel], or null if unrecognized.
  static int? dayNumber(String dayLabel) {
    final zeroIndex = index[dayLabel];
    return zeroIndex != null ? zeroIndex + 1 : null;
  }
}
