/// Restaurant-owned timing configuration.
///
/// Carries the persisted timing settings defined by the time boundary
/// contract: business-day start, week start, service-period definitions,
/// and shift-close authority.
///
/// `businessTimezone` is composed at read time from [RestaurantLocation]
/// rather than duplicated here — [RestaurantLocation.businessTimezone]
/// remains the single authoritative timezone source.
///
/// Phase 7.55n.1: persistence seam only — no runtime behavior wired yet.
library;

import 'service_period_definition.dart';

/// Shift-close authority per the time boundary contract.
enum ShiftCloseAuthority {
  /// Source system (vendor) owns close/finalization truth.
  vendorFinalization('vendor_finalization'),

  /// App uses a local-time cutoff fallback (demo / offline scenarios).
  appLocalCutoffFallback('app_local_cutoff_fallback');

  const ShiftCloseAuthority(this.value);
  final String value;

  static ShiftCloseAuthority fromValue(String v) => switch (v) {
        'vendor_finalization' => ShiftCloseAuthority.vendorFinalization,
        'app_local_cutoff_fallback' =>
          ShiftCloseAuthority.appLocalCutoffFallback,
        _ => throw ArgumentError('Unknown ShiftCloseAuthority: $v'),
      };
}

class RestaurantTimingConfig {
  final String restaurantId;

  /// Composed at read time from RestaurantLocation — not persisted here.
  final String businessTimezone;

  /// Local time when the business day rolls over, in `HH:mm` format.
  final String businessDayStartLocalTime;

  /// ISO weekday constant for day 1 of the business week.
  /// 1 = Monday, 7 = Sunday.
  final int weekStartDay;

  /// Ordered service-period definitions for this restaurant.
  final List<ServicePeriodDefinition> servicePeriodDefinitions;

  /// How shift close/finalization is determined.
  final ShiftCloseAuthority shiftCloseAuthority;

  /// Optional local-time fallback for app-controlled close (demo/offline).
  /// Only meaningful when [shiftCloseAuthority] is
  /// [ShiftCloseAuthority.appLocalCutoffFallback].
  final String? localCloseFallback;

  final String createdAt;
  final String updatedAt;

  const RestaurantTimingConfig({
    required this.restaurantId,
    required this.businessTimezone,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.servicePeriodDefinitions,
    required this.shiftCloseAuthority,
    this.localCloseFallback,
    required this.createdAt,
    required this.updatedAt,
  });
}
