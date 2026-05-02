// Phase 10.5.1 — Daypart bucketing engine.
//
// Pure-function classifier and splitter that takes operational facts
// (POS lines, labor punches, reservations) and assigns them to
// restaurant-owned service periods. No state, no I/O.
//
// Boundary semantics (from `phase_10_5_shift_daypart_service_period_view_and_primary_driver.md`):
//   * Point-in-time facts (POS line, reservation): inclusive at both
//     `startLocalTime` and `endLocalTime`. An event at exactly
//     15:00:00 with Lunch 11:00–15:00 belongs to Lunch (per the
//     phase doc's locked example).
//   * Punch minutes use half-open intersection at the upper end so
//     `[14:30, 15:00) ∩ Lunch [11:00, 15:00) = 30 minutes` matches
//     the phase doc's worked example exactly. The minute starting at
//     15:00:00 is the first minute of the post-Lunch gap.
//   * Gap minutes between periods are emitted as segments with
//     `servicePeriodId == null` (`non_service`) so callers can
//     reconcile the full punch range without recomputing.
//
// Business-date weekday governs `applicableDays`, not the wall-clock
// weekday. A 02:00 Sunday-calendar instant with cutoff 04:00 belongs
// to Saturday's business date, so a Fri/Sat-only Late Night period
// stays applicable.
//
// Missing IANA timezone is a configuration error: the bucketer
// throws `MissingTimezoneError` rather than silently falling back to
// the device clock. Matches the
// `current_state_boundary_monitor`'s posture.
library;

import '../models/service_period_definition.dart';
import 'business_date_resolver.dart';
import 'service_period_definition_resolver.dart';

/// Restaurant timing context required by the bucketing engine.
///
/// Carries the restaurant's IANA timezone and the business-day
/// rollover cutoff. The engine assumes input timestamps are already
/// expressed in restaurant-local time (per the canonical-fact
/// contract); the IANA field is asserted to be non-empty so that
/// missing config fails loudly instead of degrading to the device
/// clock.
class BucketingLocationContext {
  /// IANA timezone (e.g. `America/St_Johns`). Asserted non-empty.
  final String iana;

  /// Business-day rollover cutoff in `HH:mm` (e.g. `04:00`).
  final String businessDayStartLocalTime;

  const BucketingLocationContext({
    required this.iana,
    required this.businessDayStartLocalTime,
  });
}

/// Thrown when the bucketing engine is invoked with a location that
/// has no usable IANA timezone. The engine refuses to fall back to
/// device-clock-as-truth.
class MissingTimezoneError implements Exception {
  final String message;
  const MissingTimezoneError(this.message);
  @override
  String toString() => 'MissingTimezoneError: $message';
}

/// A POS-line input for bucketing. `eventLocalTimestamp` must already
/// be in restaurant-local time (adapter-normalized).
class BucketingPosLine {
  final String sourceId;
  final DateTime eventLocalTimestamp;

  const BucketingPosLine({
    required this.sourceId,
    required this.eventLocalTimestamp,
  });
}

/// A labor-punch input for bucketing. Both timestamps must already
/// be in restaurant-local time.
class BucketingLaborPunch {
  final String sourceId;
  final DateTime clockedInLocal;
  final DateTime clockedOutLocal;

  const BucketingLaborPunch({
    required this.sourceId,
    required this.clockedInLocal,
    required this.clockedOutLocal,
  });
}

/// A reservation input for bucketing. `reservationLocalTimestamp`
/// must already be in restaurant-local time.
class BucketingReservation {
  final String sourceId;
  final DateTime reservationLocalTimestamp;

  const BucketingReservation({
    required this.sourceId,
    required this.reservationLocalTimestamp,
  });
}

/// One contiguous slice of a labor punch, bucketed into a single
/// service period. `servicePeriodId == null` represents `non_service`
/// minutes (the gap-time that must be excluded from per-period CPLH
/// denominators per the phase plan).
class LaborPunchSegment {
  final String? servicePeriodId;
  final DateTime startLocal;
  final DateTime endLocal;
  final int minutes;

  const LaborPunchSegment({
    required this.servicePeriodId,
    required this.startLocal,
    required this.endLocal,
    required this.minutes,
  });

  @override
  String toString() {
    return 'LaborPunchSegment('
        'servicePeriodId: ${servicePeriodId ?? 'non_service'}, '
        'startLocal: $startLocal, '
        'endLocal: $endLocal, '
        'minutes: $minutes)';
  }
}

class DaypartBucketer {
  const DaypartBucketer._();

  /// Returns the service-period id covering this POS line, or null
  /// when the event timestamp falls outside every applicable period
  /// (between periods → non_service).
  static String? bucketPosLine(
    BucketingPosLine line,
    BucketingLocationContext location,
    List<ServicePeriodDefinition> definitions,
  ) {
    _ensureLocation(location);
    return _classifyInstant(
      localTimestamp: line.eventLocalTimestamp,
      businessDayStartLocalTime: location.businessDayStartLocalTime,
      definitions: definitions,
    );
  }

  /// Returns the service-period id covering this reservation, or
  /// null when the timestamp falls outside every applicable period.
  static String? bucketReservation(
    BucketingReservation res,
    BucketingLocationContext location,
    List<ServicePeriodDefinition> definitions,
  ) {
    _ensureLocation(location);
    return _classifyInstant(
      localTimestamp: res.reservationLocalTimestamp,
      businessDayStartLocalTime: location.businessDayStartLocalTime,
      definitions: definitions,
    );
  }

  /// Splits the labor punch into per-service-period segments using
  /// the punch-split rule from the phase plan. Gap-time between
  /// periods is emitted as `non_service` segments
  /// (`servicePeriodId == null`) so callers can reconcile the full
  /// punch range. Segments are returned in chronological order and
  /// are minute-aligned (seconds are truncated to match the plan's
  /// minute-precision worked example).
  ///
  /// Returns an empty list when `clockedOutLocal <= clockedInLocal`
  /// after minute truncation (degenerate input).
  static List<LaborPunchSegment> bucketLaborPunch(
    BucketingLaborPunch punch,
    BucketingLocationContext location,
    List<ServicePeriodDefinition> definitions,
  ) {
    _ensureLocation(location);
    final start = _truncateToMinute(punch.clockedInLocal);
    final end = _truncateToMinute(punch.clockedOutLocal);
    if (!end.isAfter(start)) return const [];

    final ordered = ServicePeriodDefinitionResolver.ordered(definitions);
    final spannedDates = _businessDatesSpanning(
      rangeStart: start,
      rangeEnd: end,
      businessDayStartLocalTime: location.businessDayStartLocalTime,
    );

    final periodIntervals = <_PeriodInterval>[];
    for (final dateIso in spannedDates) {
      final weekday = DateTime.parse(dateIso).weekday;
      for (final d in ordered) {
        if (!d.applicableDays.contains(weekday)) continue;
        final intervals = _periodIntervalsOnBusinessDate(
          definition: d,
          businessDateIso: dateIso,
          businessDayStartLocalTime: location.businessDayStartLocalTime,
        );
        for (final iv in intervals) {
          final ivStart = iv.start.isAfter(start) ? iv.start : start;
          final ivEnd = iv.end.isBefore(end) ? iv.end : end;
          if (!ivEnd.isAfter(ivStart)) continue;
          periodIntervals.add(_PeriodInterval(d.id, ivStart, ivEnd));
        }
      }
    }

    periodIntervals.sort((a, b) => a.start.compareTo(b.start));

    final segments = <LaborPunchSegment>[];
    var cursor = start;
    for (final iv in periodIntervals) {
      if (iv.start.isAfter(cursor)) {
        segments.add(LaborPunchSegment(
          servicePeriodId: null,
          startLocal: cursor,
          endLocal: iv.start,
          minutes: iv.start.difference(cursor).inMinutes,
        ));
      }
      segments.add(LaborPunchSegment(
        servicePeriodId: iv.id,
        startLocal: iv.start,
        endLocal: iv.end,
        minutes: iv.end.difference(iv.start).inMinutes,
      ));
      cursor = iv.end;
    }
    if (cursor.isBefore(end)) {
      segments.add(LaborPunchSegment(
        servicePeriodId: null,
        startLocal: cursor,
        endLocal: end,
        minutes: end.difference(cursor).inMinutes,
      ));
    }
    return segments;
  }

  // ─── Internals ─────────────────────────────────────────────────────

  static void _ensureLocation(BucketingLocationContext location) {
    if (location.iana.trim().isEmpty) {
      throw const MissingTimezoneError(
        'BucketingLocationContext.iana is empty; refuse to fall back '
        'to the device clock. Configure the restaurant business '
        'timezone before bucketing operational facts.',
      );
    }
  }

  /// Point-in-time classification with inclusive endpoints. Compares
  /// the local time-of-day at full sub-minute precision so the
  /// "inclusive end" rule applies *only* to the exact boundary
  /// instant: `15:00:00.000` belongs to Lunch (Lunch 11:00–15:00),
  /// but `15:00:00.001` and beyond fall into the post-Lunch gap.
  ///
  /// First matching period (in ordered/sortOrder order) wins, so
  /// back-to-back boundaries resolve to the earlier period.
  static String? _classifyInstant({
    required DateTime localTimestamp,
    required String businessDayStartLocalTime,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final businessDateIso = BusinessDateResolver.resolve(
      localTimestamp: localTimestamp,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
    final businessWeekday = DateTime.parse(businessDateIso).weekday;
    final localTimeOfDay = Duration(
      hours: localTimestamp.hour,
      minutes: localTimestamp.minute,
      seconds: localTimestamp.second,
      milliseconds: localTimestamp.millisecond,
      microseconds: localTimestamp.microsecond,
    );
    final ordered = ServicePeriodDefinitionResolver.ordered(definitions);
    for (final d in ordered) {
      if (!d.applicableDays.contains(businessWeekday)) continue;
      final startMin = _parseHm(d.startLocalTime);
      final endMin = _parseHm(d.endLocalTime);
      if (startMin == null || endMin == null) continue;
      final start = Duration(minutes: startMin);
      final end = Duration(minutes: endMin);
      if (d.rollsPastMidnight) {
        if (localTimeOfDay >= start || localTimeOfDay <= end) return d.id;
      } else {
        if (localTimeOfDay >= start && localTimeOfDay <= end) return d.id;
      }
    }
    return null;
  }

  /// Sample at start, end, and every 30 minutes between to enumerate
  /// every business date the punch range touches. Cheap for typical
  /// shift durations (an 8-hour punch yields ≤17 probes).
  static List<String> _businessDatesSpanning({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required String businessDayStartLocalTime,
  }) {
    final dates = <String>{};
    for (var t = rangeStart;
        !t.isAfter(rangeEnd);
        t = t.add(const Duration(minutes: 30))) {
      dates.add(BusinessDateResolver.resolve(
        localTimestamp: t,
        businessDayStartLocalTime: businessDayStartLocalTime,
      ));
    }
    dates.add(BusinessDateResolver.resolve(
      localTimestamp: rangeEnd,
      businessDayStartLocalTime: businessDayStartLocalTime,
    ));
    final sorted = dates.toList()..sort();
    return sorted;
  }

  /// Resolves the concrete `[start, end)` calendar interval for
  /// [definition] on the given business date. Honors
  /// `rollsPastMidnight` and the configured rollover cutoff so
  /// Late Night on business date D = `[calendar D 23:00, calendar
  /// D+1 02:00)`.
  static List<_PeriodInterval> _periodIntervalsOnBusinessDate({
    required ServicePeriodDefinition definition,
    required String businessDateIso,
    required String businessDayStartLocalTime,
  }) {
    final cutoffMin = _parseHm(businessDayStartLocalTime) ?? 0;
    final startMin = _parseHm(definition.startLocalTime);
    final endMin = _parseHm(definition.endLocalTime);
    if (startMin == null || endMin == null) return const [];

    final businessDate = DateTime.parse(businessDateIso);
    final startCalendar = startMin >= cutoffMin
        ? businessDate
        : businessDate.add(const Duration(days: 1));
    final startInstant = startCalendar.add(Duration(minutes: startMin));
    final DateTime endInstant;
    if (definition.rollsPastMidnight) {
      final endCalendar = startCalendar.add(const Duration(days: 1));
      endInstant = endCalendar.add(Duration(minutes: endMin));
    } else {
      endInstant = startCalendar.add(Duration(minutes: endMin));
    }
    return [_PeriodInterval(definition.id, startInstant, endInstant)];
  }

  static int? _parseHm(String hm) {
    final parts = hm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static DateTime _truncateToMinute(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute);
}

class _PeriodInterval {
  final String id;
  final DateTime start;
  final DateTime end;
  const _PeriodInterval(this.id, this.start, this.end);
}
