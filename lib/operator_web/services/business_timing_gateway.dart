import 'package:flutter/foundation.dart';

/// Read seam for the operator-web Business setup timing surface.
///
/// The live backend routes are intentionally not assumed by this slice. The
/// router falls back to [DemoBusinessTimingGateway] so the console can render
/// inherited/effective timing safely before writes are available.
abstract class BusinessTimingGateway {
  Future<BusinessTimingBundle> loadTiming({
    required String operatorId,
    required String locationId,
    String? operatorName,
    String? locationName,
  });
}

@immutable
class BusinessTimingBundle {
  const BusinessTimingBundle({
    required this.operatorId,
    required this.locationId,
    required this.operatorName,
    required this.locationName,
    required this.effectiveDateLabel,
    required this.inheritanceChain,
    required this.effectiveFields,
    required this.servicePeriods,
    required this.hasLocationOverride,
    required this.writesAvailable,
  });

  final String operatorId;
  final String locationId;
  final String operatorName;
  final String locationName;
  final String effectiveDateLabel;
  final List<BusinessTimingScopeSummary> inheritanceChain;
  final List<BusinessTimingInheritedValue> effectiveFields;
  final List<BusinessTimingServicePeriod> servicePeriods;
  final bool hasLocationOverride;
  final bool writesAvailable;

  String get scopeLabel => '$operatorName / $locationName';
}

@immutable
class BusinessTimingScopeSummary {
  const BusinessTimingScopeSummary({
    required this.label,
    required this.scopeKind,
    required this.summary,
    required this.active,
  });

  final String label;
  final String scopeKind;
  final String summary;
  final bool active;
}

@immutable
class BusinessTimingInheritedValue {
  const BusinessTimingInheritedValue({
    required this.label,
    required this.value,
    required this.sourceLabel,
    required this.inherited,
  });

  final String label;
  final String value;
  final String sourceLabel;
  final bool inherited;
}

@immutable
class BusinessTimingServicePeriod {
  const BusinessTimingServicePeriod({
    required this.name,
    required this.startsAt,
    required this.endsAt,
    required this.sourceLabel,
    this.inherited = true,
    this.rollsPastMidnight = false,
    this.daysLabel,
  });

  final String name;
  final String startsAt;
  final String endsAt;
  final String sourceLabel;
  final bool inherited;
  final bool rollsPastMidnight;

  /// Fix #4 / S3 (G45 / Gap 28) — a plain-English list of the
  /// weekdays this period runs on (e.g. "Sat, Sun") when it is
  /// day-restricted, or `null` when it runs every day. Surfaced so a
  /// day-restricted period (e.g. "Weekend Brunch") is visible on the
  /// read surface instead of silently implying all-week.
  final String? daysLabel;
}

class DemoBusinessTimingGateway implements BusinessTimingGateway {
  const DemoBusinessTimingGateway();

  @override
  Future<BusinessTimingBundle> loadTiming({
    required String operatorId,
    required String locationId,
    String? operatorName,
    String? locationName,
  }) async {
    final opName = _clean(operatorName) ?? 'Demo Restaurant Group';
    final locName = _clean(locationName) ?? 'Demo Main Street';
    return BusinessTimingBundle(
      operatorId: operatorId,
      locationId: locationId,
      operatorName: opName,
      locationName: locName,
      effectiveDateLabel: 'Timing active now',
      hasLocationOverride: false,
      writesAvailable: false,
      inheritanceChain: <BusinessTimingScopeSummary>[
        BusinessTimingScopeSummary(
          label: opName,
          scopeKind: 'Operator default',
          summary: 'Business day starts at 04:00 with three service periods.',
          active: true,
        ),
        const BusinessTimingScopeSummary(
          label: 'Regional settings',
          scopeKind: 'Org unit',
          summary: 'No timing override set.',
          active: false,
        ),
        BusinessTimingScopeSummary(
          label: locName,
          scopeKind: 'Location',
          summary: 'Timezone is local; periods inherit from operator default.',
          active: true,
        ),
      ],
      effectiveFields: const <BusinessTimingInheritedValue>[
        BusinessTimingInheritedValue(
          label: 'Timezone',
          value: 'America/Toronto',
          sourceLabel: 'Location timezone',
          inherited: false,
        ),
        BusinessTimingInheritedValue(
          label: 'Business day starts',
          value: '04:00',
          sourceLabel: 'Operator default',
          inherited: true,
        ),
        BusinessTimingInheritedValue(
          label: 'Week starts',
          value: 'Monday',
          sourceLabel: 'Operator default',
          inherited: true,
        ),
      ],
      servicePeriods: const <BusinessTimingServicePeriod>[
        BusinessTimingServicePeriod(
          name: 'Lunch',
          startsAt: '11:00',
          endsAt: '15:00',
          sourceLabel: 'Operator default',
        ),
        BusinessTimingServicePeriod(
          name: 'Dinner',
          startsAt: '17:00',
          endsAt: '22:00',
          sourceLabel: 'Operator default',
        ),
        BusinessTimingServicePeriod(
          name: 'Late night',
          startsAt: '22:00',
          endsAt: '01:00',
          sourceLabel: 'Operator default',
          rollsPastMidnight: true,
        ),
      ],
    );
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}
