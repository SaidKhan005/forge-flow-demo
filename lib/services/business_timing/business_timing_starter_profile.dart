/// Starter Business Timing values used before an operator customizes timing.
///
/// Timezone intentionally stays out of this helper. `locations.timezone`
/// remains the timezone source; Business Timing owns the business-day start,
/// business-week start, and service-period set.
class StarterBusinessTimingServicePeriod {
  const StarterBusinessTimingServicePeriod({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.sortOrder,
    this.shortLabel = '',
    this.applicableDays = kStarterBusinessTimingApplicableDays,
  });

  final String key;
  final String label;
  final String shortLabel;
  final int sortOrder;
  final String startLocal;
  final String endLocal;
  final List<int> applicableDays;

  bool get rollsPastMidnight {
    final start = _minutes(startLocal);
    final end = _minutes(endLocal);
    return end <= start;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'label': label,
    'shortLabel': shortLabel,
    'sortOrder': sortOrder,
    'startLocal': startLocal,
    'endLocal': endLocal,
    'rollsPastMidnight': rollsPastMidnight,
    'applicableDays': applicableDays,
  };
}

const String kStarterBusinessTimingProfileDisplayName =
    'Default business timing';
const String kStarterBusinessTimingDayStartLocal = '04:00';
const int kStarterBusinessTimingWeekStartDay = DateTime.monday;
const String kStarterBusinessTimingWeekStartDayWire = 'monday';
const String kStarterBusinessTimingCloseAuthority = 'vendor_finalization';
const List<int> kStarterBusinessTimingApplicableDays = <int>[
  1,
  2,
  3,
  4,
  5,
  6,
  7,
];

const kStarterBusinessTimingServicePeriods =
    <StarterBusinessTimingServicePeriod>[
      StarterBusinessTimingServicePeriod(
        key: 'lunch',
        label: 'Lunch',
        startLocal: '11:00',
        endLocal: '15:00',
        sortOrder: 1,
      ),
      StarterBusinessTimingServicePeriod(
        key: 'dinner',
        label: 'Dinner',
        startLocal: '17:00',
        endLocal: '22:00',
        sortOrder: 2,
      ),
    ];

int _minutes(String value) {
  final parts = value.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
