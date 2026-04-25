// Phase 7.55o.3 — Schedule day/daypart view models.
//
// Extracted from lib/screens/schedule_builder.dart. Pure data classes
// surfaced by ScheduleForecastNotifier and rendered by the Plan day
// table. No behaviour or field change from the pre-split version.

/// Pre-computed Schedule day row — Plan-owned values only.
///
/// 7.55q.6: per-day planned labor package field removed. There is no
/// honest same-scope theoretical labor % at day granularity in the
/// repo today; the row carries Plan-owned values only.
class ScheduleDayView {
  final String day;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final List<ScheduleDaySubrow> subrows;

  const ScheduleDayView({
    required this.day,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.subrows,
  });
}

/// Pre-computed daypart sub-row — Plan-owned values only.
///
/// 7.55q.6: per-daypart planned labor package field removed. Same
/// reasoning as [ScheduleDayView] — no honest same-scope theoretical
/// labor % at daypart granularity exists today.
class ScheduleDaySubrow {
  final String label;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const ScheduleDaySubrow({
    required this.label,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}
