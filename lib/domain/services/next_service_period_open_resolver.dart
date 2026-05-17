// Per-Daypart V1 (closed-state Shift screen) — NextServicePeriodOpenResolver.
//
// Pure, deterministic helper that answers a single question for the
// closed-state Shift dashboard: "given the operator's configured service
// periods and a restaurant-local reference instant (the moment the
// operator is looking at the closed day), when does the next live shift
// open?"
//
// This is DISPLAY-ONLY plumbing. It performs no I/O, owns no formula,
// reads no persistence — it takes the SAME operator-scoped
// `ServicePeriodDefinition` list the Shift surface already resolves
// (`ShiftServicePeriodNotifier.definitions`, i.e. the persisted
// per-(operator, location) timing config; demo defs only as the
// fallback) and walks it forward to the earliest period start strictly
// after [localNow]. It respects `applicableDays` (Fri/Sat-only Late
// Night skips correctly), the canonical sort order
// (`ServicePeriodDefinitionResolver.ordered`), and a `rollsPastMidnight`
// period whose START is what reopens (the cross-midnight END does not
// open a shift). The restaurant timezone is the caller's concern: the
// caller passes a timezone-correct local instant in and renders the
// local instant this returns — there is no UTC math here.
//
// Returns null only when there are no usable definitions / no period
// will ever open (defensive — never expected with a configured
// restaurant), so the caller can fall back to NOT rendering the line
// rather than printing a phantom time (Metric Honesty Doctrine).
library;

import '../canonical_day_order.dart';
import '../models/service_period_definition.dart';
import 'service_period_definition_resolver.dart';

/// The next moment a live shift opens, expressed in restaurant-local
/// wall-clock terms.
class NextServicePeriodOpen {
  /// The restaurant-local instant the next service period starts. This
  /// is a naive wall-clock `DateTime` in the restaurant's local time
  /// (the caller supplies a local [localNow] and renders this local
  /// value directly — no timezone conversion happens in this resolver).
  final DateTime localOpen;

  /// The service-period definition that opens at [localOpen].
  final ServicePeriodDefinition definition;

  /// ISO weekday (1 = Monday, 7 = Sunday) of [localOpen].
  final int isoWeekday;

  /// Full weekday name for [localOpen] (e.g. `Friday`).
  String get weekdayName =>
      CanonicalDayOrder.fullNames[isoWeekday] ?? '';

  const NextServicePeriodOpen({
    required this.localOpen,
    required this.definition,
    required this.isoWeekday,
  });
}

class NextServicePeriodOpenResolver {
  const NextServicePeriodOpenResolver._();

  /// Resolves the next service-period open strictly after [localNow].
  ///
  /// [localNow] is the restaurant-local reference instant (the close
  /// moment / the moment the operator views the closed day). [definitions]
  /// is the operator-scoped service-period list (the SAME list the Shift
  /// surface already uses).
  ///
  /// Search rules (deterministic):
  ///   * Day 0 (the [localNow] calendar day): a period opens only if its
  ///     start time-of-day is STRICTLY after [localNow]'s time-of-day
  ///     (a period that already started today is not "next"). The day
  ///     must be in the period's `applicableDays`.
  ///   * Days 1..7 forward: the earliest applicable period start on the
  ///     first day that has one. (Bounding the search at 7 days covers a
  ///     full weekly cycle; a period applicable on any weekday is found
  ///     within 7 days.)
  ///   * Within a day, periods are evaluated in canonical sort order
  ///     (`ServicePeriodDefinitionResolver.ordered`) and the earliest
  ///     start wins; ties break on sort order then id (stable).
  ///   * A `rollsPastMidnight` period reopens at its START only — its
  ///     post-midnight END does not open a shift, so only `startLocalTime`
  ///     is considered (consistent with the rest of the daypart stack).
  ///
  /// Returns null when no definition is usable or none will ever open
  /// (defensive; not expected for a configured restaurant) — the caller
  /// then omits the reopen line rather than printing a phantom time.
  static NextServicePeriodOpen? resolve({
    required DateTime localNow,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final ordered = ServicePeriodDefinitionResolver.ordered(definitions);
    if (ordered.isEmpty) return null;

    final nowMinutes =
        localNow.hour * 60 + localNow.minute; // whole-minute resolution
    final nowSecondFraction = localNow.second +
        localNow.millisecond / 1000.0 +
        localNow.microsecond / 1000000.0;

    // Walk forward day by day. dayOffset 0 = the localNow calendar day.
    // 7 days bounds a full weekly applicability cycle.
    for (var dayOffset = 0; dayOffset <= 7; dayOffset++) {
      final candidateDate = DateTime(
        localNow.year,
        localNow.month,
        localNow.day,
      ).add(Duration(days: dayOffset));
      final isoWeekday = candidateDate.weekday; // 1=Mon..7=Sun

      ServicePeriodDefinition? best;
      int? bestStartMinutes;
      for (final d in ordered) {
        if (!d.applicableDays.contains(isoWeekday)) continue;
        final startMinutes = _parseHm(d.startLocalTime);
        if (startMinutes == null) continue;

        if (dayOffset == 0) {
          // Strictly-after rule for "today": a period whose start is at
          // or before the current wall-clock instant is not the NEXT
          // open. Equal-minute ties only count as future if there is a
          // sub-minute remainder pushing now past the boundary minute
          // (i.e. start minute strictly greater, OR same minute with
          // now exactly on the minute boundary — but a period starting
          // exactly now is "active", not "next", so require strictly
          // greater).
          if (startMinutes < nowMinutes) continue;
          if (startMinutes == nowMinutes && nowSecondFraction >= 0) {
            // Same minute: the period is starting now (or already
            // started this minute) — it is not the *next* open.
            continue;
          }
        }

        if (bestStartMinutes == null || startMinutes < bestStartMinutes) {
          best = d;
          bestStartMinutes = startMinutes;
        }
      }

      if (best != null && bestStartMinutes != null) {
        final localOpen = candidateDate.add(
          Duration(minutes: bestStartMinutes),
        );
        return NextServicePeriodOpen(
          localOpen: localOpen,
          definition: best,
          isoWeekday: isoWeekday,
        );
      }
    }
    return null;
  }

  static int? _parseHm(String hm) {
    final parts = hm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }
}
