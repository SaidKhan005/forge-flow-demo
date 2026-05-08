// Doc 1 timing web/admin live parity (2026-05-08) - Local resolver
// helpers for the operator-web Business setup read view.
//
// The full server-side resolver (`BusinessTimingProfileResolver`) lives
// in `lib/domain/services/business_timing_profile_resolver.dart`. This
// helper is the subset the operator-web shell needs: project the
// operator-default + optional location override that the proxy returns
// through `GET /v1/operator/business-timing-profiles` into per-field
// "value + source + inherited?" rows. Service periods follow the
// "whole-set override" rule from `business_timing_live_plan.md`.

import 'web_business_timing_gateway.dart';

class ResolvedTimingField<T> {
  const ResolvedTimingField({
    required this.value,
    required this.sourceLabel,
    required this.inheritedFromOperator,
  });

  final T value;
  final String sourceLabel;
  final bool inheritedFromOperator;
}

class ResolvedTimingViewModel {
  const ResolvedTimingViewModel({
    required this.timezone,
    required this.businessDayStart,
    required this.weekStartDay,
    required this.servicePeriods,
  });

  final ResolvedTimingField<String> timezone;
  final ResolvedTimingField<String> businessDayStart;
  final ResolvedTimingField<String> weekStartDay;
  final ResolvedTimingField<List<ServicePeriod>> servicePeriods;
}

ResolvedTimingViewModel resolveOperatorWebTimingFields({
  required BusinessTimingProfileWriteResult operatorProfile,
  BusinessTimingProfileWriteResult? locationProfile,
}) {
  ResolvedTimingField<String> pickString(
    String Function(BusinessTimingProfileWriteResult) read,
  ) {
    final operatorValue = read(operatorProfile);
    if (locationProfile == null) {
      return ResolvedTimingField<String>(
        value: operatorValue,
        sourceLabel: 'Operator default',
        inheritedFromOperator: true,
      );
    }
    final locationValue = read(locationProfile);
    if (locationValue.trim().isEmpty || locationValue == operatorValue) {
      return ResolvedTimingField<String>(
        value: operatorValue,
        sourceLabel: 'Operator default',
        inheritedFromOperator: true,
      );
    }
    return ResolvedTimingField<String>(
      value: locationValue,
      sourceLabel: 'Location override',
      inheritedFromOperator: false,
    );
  }

  // Service periods are a whole-set override per business_timing_live_plan.md:
  // when the location profile defines any periods, that set fully replaces
  // the operator default.
  ResolvedTimingField<List<ServicePeriod>> pickPeriods() {
    final operatorPeriods = operatorProfile.servicePeriods;
    if (locationProfile == null || locationProfile.servicePeriods.isEmpty) {
      return ResolvedTimingField<List<ServicePeriod>>(
        value: List<ServicePeriod>.unmodifiable(operatorPeriods),
        sourceLabel: 'Operator default',
        inheritedFromOperator: true,
      );
    }
    return ResolvedTimingField<List<ServicePeriod>>(
      value: List<ServicePeriod>.unmodifiable(locationProfile.servicePeriods),
      sourceLabel: 'Location override',
      inheritedFromOperator: false,
    );
  }

  return ResolvedTimingViewModel(
    timezone: pickString((p) => p.ianaTimezone),
    businessDayStart: pickString((p) => p.businessDayStartLocal),
    weekStartDay: pickString((p) => p.weekStartDay),
    servicePeriods: pickPeriods(),
  );
}
