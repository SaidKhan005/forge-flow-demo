// One daypart-level signal record extracted from weekly history.
// Used by HistoryTeachingAnalyzer to surface recurring patterns.

class HistoryPatternRecord {
  final String weekId;
  final String weekLabel;
  final String dayLabel;
  final String daypart;   // 'lunch' | 'dinner' | 'late_night'
  final String leverId;   // matches LeverCardData.id
  final bool isBenchmark; // true = favorable benchmark; false = leak

  const HistoryPatternRecord({
    required this.weekId,
    required this.weekLabel,
    required this.dayLabel,
    required this.daypart,
    required this.leverId,
    required this.isBenchmark,
  });

  String get daypartLabel {
    switch (daypart) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return daypart;
    }
  }

  String get fullLabel => '$dayLabel $daypartLabel';
}
