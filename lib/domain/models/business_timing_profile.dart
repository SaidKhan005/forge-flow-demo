/// Inherited business-timing profile models.
///
/// Profiles are partial overrides. The resolver applies candidates in
/// hierarchy order from highest scope to lowest scope, producing one
/// effective timing profile for a location.
library;

import 'restaurant_timing_config.dart';
import 'service_period_definition.dart';

enum BusinessTimingScope {
  operatorDefault('operator'),
  orgUnit('org_unit'),
  location('location');

  const BusinessTimingScope(this.value);
  final String value;

  static BusinessTimingScope fromValue(String value) {
    return switch (value) {
      'operator' => BusinessTimingScope.operatorDefault,
      'operator_default' => BusinessTimingScope.operatorDefault,
      'org_unit' => BusinessTimingScope.orgUnit,
      'location' => BusinessTimingScope.location,
      _ => throw ArgumentError('Unknown BusinessTimingScope: $value'),
    };
  }
}

class BusinessTimingProfile {
  final String profileId;
  final BusinessTimingScope scope;
  final String scopeId;

  /// Optional IANA timezone override.
  final String? businessTimezone;

  /// Optional local business-day rollover override in `HH:mm`.
  final String? businessDayStartLocalTime;

  /// Optional ISO weekday override for the business week start.
  /// 1 = Monday, 7 = Sunday.
  final int? weekStartDay;

  /// Optional atomic service-period set override.
  ///
  /// Null means "inherit". A non-null list replaces the inherited set
  /// wholesale; periods are never merged across profile levels.
  final List<ServicePeriodDefinition>? servicePeriodDefinitions;

  /// Optional shift-close authority override.
  final ShiftCloseAuthority? shiftCloseAuthority;

  /// Optional local fallback cutoff for app-owned close behavior.
  final String? localCloseFallback;

  const BusinessTimingProfile({
    required this.profileId,
    required this.scope,
    required this.scopeId,
    this.businessTimezone,
    this.businessDayStartLocalTime,
    this.weekStartDay,
    this.servicePeriodDefinitions,
    this.shiftCloseAuthority,
    this.localCloseFallback,
  });

  bool get hasServicePeriodOverride => servicePeriodDefinitions != null;
}

class EffectiveBusinessTimingProfile {
  final List<BusinessTimingProfile> inheritanceChain;
  final BusinessTimingScope resolvedScope;
  final String resolvedScopeId;
  final String businessTimezone;
  final String businessDayStartLocalTime;
  final int weekStartDay;
  final List<ServicePeriodDefinition> servicePeriodDefinitions;
  final ShiftCloseAuthority shiftCloseAuthority;
  final String? localCloseFallback;

  const EffectiveBusinessTimingProfile({
    required this.inheritanceChain,
    required this.resolvedScope,
    required this.resolvedScopeId,
    required this.businessTimezone,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.servicePeriodDefinitions,
    required this.shiftCloseAuthority,
    this.localCloseFallback,
  });

  RestaurantTimingConfig toRestaurantTimingConfig({
    required String restaurantId,
    required String createdAt,
    required String updatedAt,
  }) {
    return RestaurantTimingConfig(
      restaurantId: restaurantId,
      businessTimezone: businessTimezone,
      businessDayStartLocalTime: businessDayStartLocalTime,
      weekStartDay: weekStartDay,
      servicePeriodDefinitions: servicePeriodDefinitions,
      shiftCloseAuthority: shiftCloseAuthority,
      localCloseFallback: localCloseFallback,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
