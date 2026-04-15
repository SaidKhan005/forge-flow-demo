// Phase 7.55n.5 — Shift boundary resolver.
//
// Pure, deterministic service that separates three runtime concepts:
//   1. Service period has ended — classification boundary.
//   2. Shift is finalized — closed historical truth boundary.
//   3. Row is eligible for closed-truth surfaces — downstream gate.
//
// Service-period end is based on the configured local end time and
// rollover behavior. It is classification-only and does NOT imply
// closed historical truth.
//
// Finalization depends on ShiftCloseAuthority:
//   - vendorFinalization: a row is finalized when the vendor says so
//     (i.e. status == 'closed').
//   - appLocalCutoffFallback: a closed row becomes finalized only when
//     the current operational business date is strictly later than the
//     row's business date.
//
// Honesty rule: local timestamps passed here are already restaurant-local.
// This resolver does NOT perform timezone conversion.

import '../models/restaurant_timing_config.dart';
import '../models/service_period_definition.dart';

class ShiftBoundaryResolver {
  const ShiftBoundaryResolver._();

  // ── Service-period end ──────────────────────────────────────────────────

  /// Whether the given [servicePeriod] has ended at [localTimestamp].
  ///
  /// For same-day periods (e.g. lunch 11:00–15:00): ended when local time
  /// is at or past the end time.
  ///
  /// For rollover periods (e.g. late_night 23:00–02:00): the end boundary
  /// lands on the next calendar day. The period is "still active" when
  /// local time is at-or-after start OR before end on the next day.
  /// It has ended when local time is at-or-after end AND before start.
  ///
  /// [localTimestamp] must be restaurant-local time. No timezone conversion
  /// is performed here.
  ///
  /// This is classification-only — it must NOT imply closed historical truth.
  static bool servicePeriodHasEnded({
    required DateTime localTimestamp,
    required ServicePeriodDefinition servicePeriod,
  }) {
    final localMinutes = localTimestamp.hour * 60 + localTimestamp.minute;
    final startMinutes = _parseTimeToMinutes(servicePeriod.startLocalTime);
    final endMinutes = _parseTimeToMinutes(servicePeriod.endLocalTime);

    if (!servicePeriod.rollsPastMidnight) {
      // Same-day period: ended when local time is at or past end.
      return localMinutes >= endMinutes;
    }

    // Rollover period (e.g. 23:00–02:00):
    // Active window spans midnight: [start..midnight) ∪ [midnight..end).
    // Ended when local time is in [end..start) — the gap between periods.
    if (startMinutes > endMinutes) {
      // Normal rollover: start > end (e.g. 23:00–02:00).
      // Active: localMinutes >= start OR localMinutes < end.
      // Ended: localMinutes >= end AND localMinutes < start.
      return localMinutes >= endMinutes && localMinutes < startMinutes;
    }

    // Edge case: start == end means a 24-hour period, never ends.
    return false;
  }

  // ── Shift finalization ──────────────────────────────────────────────────

  /// Whether a shift row is considered finalized (closed historical truth).
  ///
  /// Under [ShiftCloseAuthority.vendorFinalization]: the row is finalized
  /// when [rowStatus] is `'closed'` — the vendor/source system says so.
  ///
  /// Under [ShiftCloseAuthority.appLocalCutoffFallback]: the row is
  /// finalized only when [rowStatus] is `'closed'` AND the current
  /// operational business date is strictly later than the row's business
  /// date. A same-business-date closed row is NOT yet finalized — it is
  /// still operationally "today" and could theoretically be amended.
  ///
  /// [currentOperationalBusinessDate] is the ISO date string for the
  /// business day the restaurant is currently operating in. It comes from
  /// open-shift snapshot authority.
  ///
  /// [rowBusinessDate] is the ISO date string for the row's business day.
  /// If null, finalization cannot be determined under app-local-cutoff and
  /// the row is treated as not finalized.
  static bool isShiftFinalized({
    required String rowStatus,
    required ShiftCloseAuthority shiftCloseAuthority,
    String? rowBusinessDate,
    String? currentOperationalBusinessDate,
  }) {
    // Row must be closed by its status to even be a candidate.
    if (rowStatus != 'closed') return false;

    switch (shiftCloseAuthority) {
      case ShiftCloseAuthority.vendorFinalization:
        // Vendor says it's closed → it's finalized.
        return true;

      case ShiftCloseAuthority.appLocalCutoffFallback:
        // App-local fallback: closed + current operational business date
        // must be strictly later than the row's business date.
        if (rowBusinessDate == null ||
            currentOperationalBusinessDate == null) {
          // Cannot determine — treat as not finalized.
          return false;
        }
        return currentOperationalBusinessDate.compareTo(rowBusinessDate) > 0;
    }
  }

  // ── Closed-truth eligibility gate ───────────────────────────────────────

  /// Whether a row is eligible for closed-truth surfaces (WTD, History,
  /// Learn, benchmark daypart evidence).
  ///
  /// A row is eligible when:
  ///   1. Its status is `'closed'`.
  ///   2. It is finalized per the configured [shiftCloseAuthority].
  ///
  /// This is the single gate that downstream closed-truth consumers should
  /// use instead of checking `status == 'closed'` alone.
  static bool isEligibleForClosedTruth({
    required String rowStatus,
    required ShiftCloseAuthority shiftCloseAuthority,
    String? rowBusinessDate,
    String? currentOperationalBusinessDate,
  }) {
    return isShiftFinalized(
      rowStatus: rowStatus,
      shiftCloseAuthority: shiftCloseAuthority,
      rowBusinessDate: rowBusinessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Parses an `HH:mm` time string to minutes since midnight.
  static int _parseTimeToMinutes(String hhMm) {
    final parts = hhMm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}
