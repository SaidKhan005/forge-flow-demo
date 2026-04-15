// Phase 7.55n.2 — Pure business-date resolver.
//
// Maps a restaurant-local timestamp + business-day start time to an
// ISO business date string.
//
// Resolution rule:
//   - if local time is before businessDayStartLocalTime → previous calendar date
//   - if local time is at or after businessDayStartLocalTime → same calendar date
//
// Important honesty note:
//   This resolver expects the caller to provide a timestamp already
//   expressed in restaurant-local time. It does not perform timezone
//   conversion. Full timezone-conversion support is not yet landed;
//   callers that have a UTC timestamp must convert it to restaurant-local
//   time before calling this resolver.
//
// This is the shared rule that later slices can wire into adapter ingestion
// and app bucketing.
library;

/// Pure, deterministic business-date resolver.
///
/// Does not depend on device clock, database, or runtime state.
/// Expects all inputs to already be in restaurant-local time.
class BusinessDateResolver {
  const BusinessDateResolver._();

  /// Resolves the business date for a restaurant-local [DateTime].
  ///
  /// [localTimestamp] must already be expressed in restaurant-local time.
  /// [businessDayStartLocalTime] is the cutoff in `HH:mm` format (e.g. `04:00`).
  ///
  /// If [localTimestamp]'s time-of-day is before the cutoff, the business
  /// date is the previous calendar date. Otherwise it is the same calendar
  /// date.
  static String resolve({
    required DateTime localTimestamp,
    required String businessDayStartLocalTime,
  }) {
    final cutoff = _parseHHmm(businessDayStartLocalTime);
    final localMinutes = localTimestamp.hour * 60 + localTimestamp.minute;

    final date =
        localMinutes < cutoff
            ? localTimestamp.subtract(const Duration(days: 1))
            : localTimestamp;

    return _toIsoDate(date);
  }

  /// Resolves the business date from an ISO datetime string.
  ///
  /// [localIsoTimestamp] must be parseable by [DateTime.parse] and must
  /// already represent restaurant-local time.
  static String resolveFromIso({
    required String localIsoTimestamp,
    required String businessDayStartLocalTime,
  }) {
    final dt = DateTime.parse(localIsoTimestamp);
    return resolve(
      localTimestamp: dt,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
  }

  /// Parses an `HH:mm` string into total minutes since midnight.
  static int _parseHHmm(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  /// Formats a [DateTime] as an ISO date string (`YYYY-MM-DD`).
  static String _toIsoDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}'
        '-${dt.day.toString().padLeft(2, '0')}';
  }
}
