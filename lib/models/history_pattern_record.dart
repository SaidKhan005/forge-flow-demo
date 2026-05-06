// One daypart-level signal record extracted from weekly history.
// Used by HistoryTeachingAnalyzer to surface recurring patterns.
//
// Phase 7.55k.3: DaypartPatternSummary now exists as a richer aggregate
// alternative carrying counts, averages, and exemplar IDs. This model
// remains the active path for HistoryTeachingAnalyzer and
// LearnTeachingAnalyzer until 7.55k.5 / 7.55k.6 migrate them.

class HistoryPatternRecord {
  final String weekId;
  final String weekLabel;
  final String dayLabel;
  final String daypart; // 'lunch' | 'dinner' | 'late_night'
  final String? servicePeriodLabel;
  final String leverId; // matches LeverCardData.id
  final bool isBenchmark; // true = favorable benchmark; false = leak

  const HistoryPatternRecord({
    required this.weekId,
    required this.weekLabel,
    required this.dayLabel,
    required this.daypart,
    this.servicePeriodLabel,
    required this.leverId,
    required this.isBenchmark,
  });

  String get daypartLabel {
    if (servicePeriodLabel != null && servicePeriodLabel!.trim().isNotEmpty) {
      return servicePeriodLabel!;
    }
    switch (daypart) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'late_night':
        return 'Late Night';
      default:
        return daypart;
    }
  }

  String get fullLabel => '$dayLabel $daypartLabel';
}
