/// Restaurant-owned timing configuration.
///
/// Carries the persisted timing settings defined by the time boundary
/// contract: business-day start, week start, and service-period
/// definitions.
///
/// `businessTimezone` is composed at read time from [RestaurantLocation]
/// rather than duplicated here — [RestaurantLocation.businessTimezone]
/// remains the single authoritative timezone source.
///
/// Phase 7.55n.1: persistence seam only — no runtime behavior wired yet.
///
/// Per-Daypart V1 Slice 1.5 (operator decision 2026-05-15): the legacy
/// `shiftCloseAuthority` + `localCloseFallback` fields were removed.
/// Close-authority is now auto-derived per shift from the per-vendor
/// `CloseAuthorityCapability` lookup
/// (`lib/services/integration/close_authority_capability.dart`) +
/// the operator's [businessDayStartLocalTime] as the universal
/// fallback. No operator-facing toggle.
library;

import 'service_period_definition.dart';

/// Shift-close authority — used by [BusinessTimingProfile] /
/// [ShiftBoundaryResolver] downstream finalization gating. The
/// `RestaurantTimingConfig` no longer carries an operator-set value;
/// callers consult per-vendor capability + business-day-start instead.
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
  ///
  /// Per-Daypart V1 Slice 1.5: this is also the universal close-moment
  /// fallback when a shift's POS vendor does not expose a reliable
  /// finalization signal (see `close_authority_capability.dart`).
  final String businessDayStartLocalTime;

  /// ISO weekday constant for day 1 of the business week.
  /// 1 = Monday, 7 = Sunday.
  final int weekStartDay;

  /// Ordered service-period definitions for this restaurant.
  final List<ServicePeriodDefinition> servicePeriodDefinitions;

  final String createdAt;
  final String updatedAt;

  const RestaurantTimingConfig({
    required this.restaurantId,
    required this.businessTimezone,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.servicePeriodDefinitions,
    required this.createdAt,
    required this.updatedAt,
  });
}
