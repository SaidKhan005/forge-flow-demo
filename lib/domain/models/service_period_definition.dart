/// A restaurant-owned service-period definition.
///
/// Replaces hardcoded daypart assumptions with explicit, restaurant-scoped
/// configuration. Each definition carries its own clock range, weekday
/// applicability, and sort order.
///
/// Phase 7.55n.1: persistence seam only — no runtime behavior wired yet.
library;

class ServicePeriodDefinition {
  /// Stable identifier for this service period (e.g. `lunch`, `dinner`).
  final String id;

  /// Human-readable label (e.g. `Lunch`, `Dinner`).
  final String label;

  /// Short label for compact UI (e.g. `L`, `D`).
  final String shortLabel;

  /// Sort order for display. Lower values sort first.
  final int sortOrder;

  /// Local start time in `HH:mm` format (e.g. `11:00`).
  final String startLocalTime;

  /// Local end time in `HH:mm` format (e.g. `15:00`).
  final String endLocalTime;

  /// Whether this service period's end time crosses midnight.
  final bool rollsPastMidnight;

  /// Weekdays this service period applies to.
  /// Uses ISO weekday constants: 1 = Monday, 7 = Sunday.
  final List<int> applicableDays;

  const ServicePeriodDefinition({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.sortOrder,
    required this.startLocalTime,
    required this.endLocalTime,
    required this.rollsPastMidnight,
    required this.applicableDays,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'short_label': shortLabel,
        'sort_order': sortOrder,
        'start_local_time': startLocalTime,
        'end_local_time': endLocalTime,
        'rolls_past_midnight': rollsPastMidnight,
        'applicable_days': applicableDays,
      };

  factory ServicePeriodDefinition.fromMap(Map<String, dynamic> m) =>
      ServicePeriodDefinition(
        id: m['id'] as String,
        label: m['label'] as String,
        shortLabel: m['short_label'] as String,
        sortOrder: m['sort_order'] as int,
        startLocalTime: m['start_local_time'] as String,
        endLocalTime: m['end_local_time'] as String,
        rollsPastMidnight: m['rolls_past_midnight'] as bool,
        applicableDays: (m['applicable_days'] as List<dynamic>).cast<int>(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServicePeriodDefinition &&
          id == other.id &&
          label == other.label &&
          shortLabel == other.shortLabel &&
          sortOrder == other.sortOrder &&
          startLocalTime == other.startLocalTime &&
          endLocalTime == other.endLocalTime &&
          rollsPastMidnight == other.rollsPastMidnight &&
          _listEquals(applicableDays, other.applicableDays);

  @override
  int get hashCode => Object.hash(
        id,
        label,
        shortLabel,
        sortOrder,
        startLocalTime,
        endLocalTime,
        rollsPastMidnight,
        Object.hashAll(applicableDays),
      );

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
