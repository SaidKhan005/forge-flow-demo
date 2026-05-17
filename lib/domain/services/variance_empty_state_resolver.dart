// Per-Daypart V1 / demo-seed workstream — Variance "This Week" empty-state
// copy clarity (presentation only, NOT a data/logic fix).
//
// The "This Week" tab shows a generic empty state whenever the shared
// `WeekData` is null. On the FIRST day of the current business week there
// are legitimately zero prior closed shifts in the week yet, and the
// day's own ended periods are not finalized — so a null `WeekData` on
// that day is EXPECTED, not an error or a no-data condition.
//
// This pure resolver classifies the null-`WeekData` case into either:
//   - weekStart : it is the first day of the configured business week,
//                 so "nothing closed yet" is normal — show reassuring copy.
//   - noData    : a genuine no-data / empty condition — show the honest
//                 empty message.
//
// It does NOT touch closed-truth, `getWeekToDate`, `shift_service`, or the
// `weekData == null` gate itself. It only decides which message string to
// display, derived from the SAME real business-date + week-start config the
// app/seed already use. The week-start day is read from configuration
// (`RestaurantTimingConfig.weekStartDay`); no weekday literal is hardcoded,
// so the predicate is correct for any operator (Monday-start, Sunday-start,
// or any other configured first day).
library;

/// Which empty-state copy the "This Week" tab should render when the
/// shared `WeekData` is null.
enum VarianceEmptyStateKind {
  /// First day of the configured business week: zero prior closed shifts
  /// in the week yet is expected. Show reassuring "new week" copy.
  weekStart,

  /// Genuine no-data / empty condition. Show the honest empty message.
  noData,
}

/// Pure, deterministic classifier for the null-`WeekData` empty state.
///
/// Does not depend on device clock, database, or runtime state — callers
/// pass the already-resolved current business date and the configured
/// week-start day.
class VarianceEmptyStateResolver {
  const VarianceEmptyStateResolver._();

  /// Classifies the empty state from the current business date and the
  /// operator's configured week-start day.
  ///
  /// [currentBusinessDate] is the ISO `YYYY-MM-DD` business date resolved
  /// from the SAME source the app/seed already use (mock-replay current
  /// business date in demo, latest closed business date otherwise). May be
  /// null when no business date can be resolved.
  ///
  /// [weekStartDay] is `RestaurantTimingConfig.weekStartDay`: the ISO
  /// weekday constant for day 1 of the business week (1 = Monday, ...,
  /// 7 = Sunday). May be null when no timing config is persisted.
  ///
  /// Returns [VarianceEmptyStateKind.weekStart] only when BOTH inputs are
  /// available AND the current business date's ISO weekday equals the
  /// configured week-start day. Any unresolved input, an unparseable date,
  /// or a non-week-start day yields [VarianceEmptyStateKind.noData] — the
  /// honest default. No weekday literal is hardcoded; the comparison is
  /// entirely config-driven.
  static VarianceEmptyStateKind classify({
    required String? currentBusinessDate,
    required int? weekStartDay,
  }) {
    if (currentBusinessDate == null || weekStartDay == null) {
      return VarianceEmptyStateKind.noData;
    }
    if (weekStartDay < DateTime.monday || weekStartDay > DateTime.sunday) {
      return VarianceEmptyStateKind.noData;
    }
    final parsed = _parseIsoDate(currentBusinessDate);
    if (parsed == null) {
      return VarianceEmptyStateKind.noData;
    }
    return parsed.weekday == weekStartDay
        ? VarianceEmptyStateKind.weekStart
        : VarianceEmptyStateKind.noData;
  }

  /// Parses a strict `YYYY-MM-DD` ISO date into a [DateTime], or null when
  /// the string is not a well-formed ISO date. Uses UTC so the weekday is
  /// stable regardless of the host timezone.
  static DateTime? _parseIsoDate(String isoDate) {
    final parts = isoDate.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final dt = DateTime.utc(year, month, day);
    // Reject overflow normalization (e.g. 2026-02-30 -> 2026-03-02).
    if (dt.year != year || dt.month != month || dt.day != day) return null;
    return dt;
  }
}
