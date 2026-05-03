// Phase 8.0 — IANA-backed timezone converter at the adapter boundary.
//
// Architectural constraint (binding, see
// `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
// "Architectural constraint" / "Scenarios A–F"):
//
//   * Use an IANA-backed timezone library. Fixed-offset calculation
//     would silently mis-bucket DST fall-back timestamps twice a year.
//   * Every vendor timestamp is interpreted in the restaurant's
//     configured `businessTimezone` BEFORE any business-date decision.
//   * `BusinessDateResolver` (and its successor on Postgres) consume
//     pre-converted local timestamps; this helper produces them.
//
// Storage rule (Phase 7.55 Rule 11): operator-scoped fact tables
// store the source-truth instant as `TIMESTAMPTZ` (UTC) plus a
// denormalized `business_date` `DATE` computed at write from
// `location.timezone` + `business_day_rollover_hour`. This converter
// is the single helper every adapter calls so the projection is
// consistent.

import 'package:timezone/timezone.dart' as tz;

import '../../utils/iana_timezones.dart';

/// IANA-backed timezone converter.
///
/// Stateless on purpose — instantiate or use [shared] for tests that
/// want to inject a fake timezone database.
class IanaTimezoneConverter {
  IanaTimezoneConverter();

  /// Shared default instance. Lazy-initializes the timezone catalog
  /// the first time it is touched.
  static final IanaTimezoneConverter shared = IanaTimezoneConverter();

  /// Convert a UTC instant to local wall-clock time in the
  /// restaurant's configured [restaurantTimezone] (an IANA name like
  /// `America/Toronto`). Returns a `DateTime` whose `year/month/day/
  /// hour/minute/second` fields read the local clock at [instant].
  ///
  /// On DST fall-back ambiguity (Scenario C), the IANA database picks
  /// the canonical wall-clock value the same way Postgres
  /// `timestamptz at time zone 'America/New_York'` does — the
  /// `00:30 EDT` and `01:30 EST` instants both project to a `01:30`
  /// local wall clock, but `business_date` resolution still works
  /// correctly because the absolute instant is preserved in the
  /// underlying `tz.TZDateTime`.
  ///
  /// Throws [IanaTimezoneConverterError] when [restaurantTimezone] is
  /// not a known IANA name.
  DateTime toBusinessLocal({
    required String restaurantTimezone,
    required DateTime instant,
  }) {
    final location = _resolveLocation(restaurantTimezone);
    final converted = tz.TZDateTime.from(instant, location);
    // Return a "naive" DateTime carrying the local wall-clock fields
    // so consumers can compare hour-of-day and date-of-month without
    // accidentally re-interpreting the offset.
    return DateTime(
      converted.year,
      converted.month,
      converted.day,
      converted.hour,
      converted.minute,
      converted.second,
      converted.millisecond,
      converted.microsecond,
    );
  }

  /// Resolve the restaurant business date for a UTC [instant], given
  /// the restaurant's [restaurantTimezone] (IANA) and the per-location
  /// [businessDayRolloverHour] (0..23). The rollover hour determines
  /// when the business date flips: a 4 AM rollover means events
  /// before 04:00 local belong to the prior business date.
  ///
  /// This is the single source of business-date projection used by
  /// every adapter that writes operator-scoped facts. Per Phase 7.55
  /// Rule 11, the result is denormalized into the canonical fact
  /// table as a `DATE` column at write time and never re-derived at
  /// read.
  ///
  /// Throws [IanaTimezoneConverterError] on bad timezone or
  /// out-of-range rollover hour.
  DateTime toBusinessDate({
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime instant,
  }) {
    if (businessDayRolloverHour < 0 || businessDayRolloverHour > 23) {
      throw IanaTimezoneConverterError(
        'business_day_rollover_hour must be in [0, 23]',
        restaurantTimezone: restaurantTimezone,
      );
    }
    final local = toBusinessLocal(
      restaurantTimezone: restaurantTimezone,
      instant: instant,
    );
    // If the local hour is before the rollover, the event belongs to
    // the prior business date.
    final adjusted = local.hour < businessDayRolloverHour
        ? DateTime(local.year, local.month, local.day).subtract(
            const Duration(days: 1),
          )
        : DateTime(local.year, local.month, local.day);
    return DateTime.utc(adjusted.year, adjusted.month, adjusted.day);
  }

  /// Whether the underlying IANA database recognizes [restaurantTimezone].
  /// Cheap; cached.
  bool isKnownTimezone(String restaurantTimezone) =>
      isValidIanaTimezoneName(restaurantTimezone);

  tz.Location _resolveLocation(String restaurantTimezone) {
    if (!isValidIanaTimezoneName(restaurantTimezone)) {
      throw IanaTimezoneConverterError(
        'unknown IANA timezone: $restaurantTimezone',
        restaurantTimezone: restaurantTimezone,
      );
    }
    return tz.getLocation(restaurantTimezone);
  }
}

/// Thrown by [IanaTimezoneConverter] when input is invalid. The
/// timezone name is included in the message because it is operator-
/// owned configuration, not a secret.
class IanaTimezoneConverterError implements Exception {
  IanaTimezoneConverterError(this.message, {required this.restaurantTimezone});

  final String message;
  final String restaurantTimezone;

  @override
  String toString() =>
      'IanaTimezoneConverterError(tz=$restaurantTimezone): $message';
}
