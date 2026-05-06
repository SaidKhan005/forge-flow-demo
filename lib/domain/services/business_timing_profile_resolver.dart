/// Pure inherited business-timing profile resolver.
///
/// Candidate profiles must be supplied in hierarchy order from highest
/// scope to lowest scope. Later profiles override earlier profiles
/// field-by-field, except service periods, which override atomically
/// as a whole set.
library;

import '../models/business_timing_profile.dart';
import '../models/restaurant_timing_config.dart';
import '../models/service_period_definition.dart';

class BusinessTimingProfileResolutionException implements Exception {
  final String message;
  const BusinessTimingProfileResolutionException(this.message);

  @override
  String toString() => 'BusinessTimingProfileResolutionException: $message';
}

class BusinessTimingProfileResolver {
  const BusinessTimingProfileResolver._();

  static EffectiveBusinessTimingProfile resolve(
    List<BusinessTimingProfile> candidates,
  ) {
    if (candidates.isEmpty) {
      throw const BusinessTimingProfileResolutionException(
        'At least one business timing profile is required.',
      );
    }

    String? businessTimezone;
    String? businessDayStartLocalTime;
    int? weekStartDay;
    List<ServicePeriodDefinition>? servicePeriodDefinitions;
    ShiftCloseAuthority? shiftCloseAuthority;
    String? localCloseFallback;
    BusinessTimingProfile? deepestProfile;

    for (final candidate in candidates) {
      deepestProfile = candidate;

      if (candidate.businessTimezone != null) {
        final value = candidate.businessTimezone!.trim();
        if (value.isEmpty) {
          throw BusinessTimingProfileResolutionException(
            'Profile ${candidate.profileId} has an empty businessTimezone.',
          );
        }
        businessTimezone = value;
      }

      if (candidate.businessDayStartLocalTime != null) {
        businessDayStartLocalTime = candidate.businessDayStartLocalTime!.trim();
      }

      if (candidate.weekStartDay != null) {
        weekStartDay = candidate.weekStartDay;
      }

      if (candidate.servicePeriodDefinitions != null) {
        servicePeriodDefinitions = List<ServicePeriodDefinition>.unmodifiable(
          candidate.servicePeriodDefinitions!,
        );
      }

      if (candidate.shiftCloseAuthority != null) {
        shiftCloseAuthority = candidate.shiftCloseAuthority;
      }

      if (candidate.localCloseFallback != null) {
        localCloseFallback = candidate.localCloseFallback!.trim();
      }
    }

    final resolvedBusinessTimezone = _required(
      value: businessTimezone,
      fieldName: 'businessTimezone',
    );
    final resolvedBusinessDayStart = _required(
      value: businessDayStartLocalTime,
      fieldName: 'businessDayStartLocalTime',
    );
    final resolvedWeekStartDay =
        weekStartDay ??
        (throw const BusinessTimingProfileResolutionException(
          'Missing required weekStartDay after inheritance resolution.',
        ));
    final resolvedServicePeriods =
        servicePeriodDefinitions ??
        (throw const BusinessTimingProfileResolutionException(
          'Missing required servicePeriodDefinitions after inheritance '
          'resolution.',
        ));
    final resolvedShiftCloseAuthority =
        shiftCloseAuthority ??
        (throw const BusinessTimingProfileResolutionException(
          'Missing required shiftCloseAuthority after inheritance resolution.',
        ));

    _validateWeekStart(resolvedWeekStartDay);
    _validateTime(
      resolvedBusinessDayStart,
      fieldName: 'businessDayStartLocalTime',
    );
    if (localCloseFallback != null && localCloseFallback.isNotEmpty) {
      _validateTime(localCloseFallback, fieldName: 'localCloseFallback');
    }
    _validateServicePeriods(
      businessDayStartLocalTime: resolvedBusinessDayStart,
      servicePeriods: resolvedServicePeriods,
    );

    final resolvedLocalCloseFallback = (localCloseFallback?.isEmpty ?? true)
        ? null
        : localCloseFallback;

    return EffectiveBusinessTimingProfile(
      inheritanceChain: List<BusinessTimingProfile>.unmodifiable(candidates),
      resolvedScope: deepestProfile!.scope,
      resolvedScopeId: deepestProfile.scopeId,
      businessTimezone: resolvedBusinessTimezone,
      businessDayStartLocalTime: resolvedBusinessDayStart,
      weekStartDay: resolvedWeekStartDay,
      servicePeriodDefinitions: List<ServicePeriodDefinition>.unmodifiable(
        resolvedServicePeriods,
      ),
      shiftCloseAuthority: resolvedShiftCloseAuthority,
      localCloseFallback: resolvedLocalCloseFallback,
    );
  }

  static String _required({required String? value, required String fieldName}) {
    if (value == null || value.trim().isEmpty) {
      throw BusinessTimingProfileResolutionException(
        'Missing required $fieldName after inheritance resolution.',
      );
    }
    return value.trim();
  }

  static void _validateWeekStart(int weekStartDay) {
    if (weekStartDay < DateTime.monday || weekStartDay > DateTime.sunday) {
      throw BusinessTimingProfileResolutionException(
        'weekStartDay must be an ISO weekday from 1 to 7; got '
        '$weekStartDay.',
      );
    }
  }

  static void _validateServicePeriods({
    required String businessDayStartLocalTime,
    required List<ServicePeriodDefinition> servicePeriods,
  }) {
    if (servicePeriods.isEmpty) {
      throw const BusinessTimingProfileResolutionException(
        'An effective timing profile must define at least one service period.',
      );
    }
    if (servicePeriods.length > 4) {
      throw BusinessTimingProfileResolutionException(
        'An effective timing profile may define at most 4 service periods; '
        'got ${servicePeriods.length}.',
      );
    }

    final businessStartMinutes = _validateTime(
      businessDayStartLocalTime,
      fieldName: 'businessDayStartLocalTime',
    );
    final ids = <String>{};
    var rollsPastMidnightCount = 0;
    final intervalsByWeekday = <int, List<_PeriodInterval>>{
      for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++)
        weekday: <_PeriodInterval>[],
    };

    for (final period in servicePeriods) {
      if (period.id.trim().isEmpty) {
        throw const BusinessTimingProfileResolutionException(
          'Service period ids must be non-empty.',
        );
      }
      if (!ids.add(period.id)) {
        throw BusinessTimingProfileResolutionException(
          'Duplicate service period id: ${period.id}.',
        );
      }
      if (period.rollsPastMidnight) rollsPastMidnightCount++;
      if (rollsPastMidnightCount > 1) {
        throw const BusinessTimingProfileResolutionException(
          'At most one service period may roll past midnight.',
        );
      }
      if (period.applicableDays.isEmpty) {
        throw BusinessTimingProfileResolutionException(
          'Service period ${period.id} must apply to at least one weekday.',
        );
      }
      for (final weekday in period.applicableDays) {
        if (weekday < DateTime.monday || weekday > DateTime.sunday) {
          throw BusinessTimingProfileResolutionException(
            'Service period ${period.id} has invalid weekday $weekday.',
          );
        }
      }

      final interval = _intervalFor(
        period: period,
        businessStartMinutes: businessStartMinutes,
      );
      for (final weekday in period.applicableDays) {
        intervalsByWeekday[weekday]!.add(interval);
      }
    }

    for (final entry in intervalsByWeekday.entries) {
      final intervals = entry.value..sort((a, b) => a.start.compareTo(b.start));
      for (var i = 1; i < intervals.length; i++) {
        final previous = intervals[i - 1];
        final current = intervals[i];
        if (current.start < previous.end) {
          throw BusinessTimingProfileResolutionException(
            'Service periods ${previous.id} and ${current.id} overlap on '
            'ISO weekday ${entry.key}.',
          );
        }
      }
    }
  }

  static _PeriodInterval _intervalFor({
    required ServicePeriodDefinition period,
    required int businessStartMinutes,
  }) {
    final start = _validateTime(
      period.startLocalTime,
      fieldName: '${period.id}.startLocalTime',
    );
    final end = _validateTime(
      period.endLocalTime,
      fieldName: '${period.id}.endLocalTime',
    );

    if (start == end) {
      throw BusinessTimingProfileResolutionException(
        'Service period ${period.id} must have different start and end times.',
      );
    }

    final crossesMidnightByClock = end < start;
    if (period.rollsPastMidnight != crossesMidnightByClock) {
      throw BusinessTimingProfileResolutionException(
        'Service period ${period.id} rollsPastMidnight must match its clock '
        'range.',
      );
    }

    final relativeStart = _relativeToBusinessStart(
      minutes: start,
      businessStartMinutes: businessStartMinutes,
    );
    var relativeEnd = _relativeToBusinessStart(
      minutes: end,
      businessStartMinutes: businessStartMinutes,
    );
    if (relativeEnd <= relativeStart) {
      relativeEnd += _minutesPerDay;
    }

    final duration = relativeEnd - relativeStart;
    if (duration <= 0 || duration > _minutesPerDay) {
      throw BusinessTimingProfileResolutionException(
        'Service period ${period.id} must be longer than zero minutes and no '
        'longer than 24 hours.',
      );
    }

    if (relativeEnd > _minutesPerDay) {
      throw BusinessTimingProfileResolutionException(
        'businessDayStartLocalTime cannot fall inside service period '
        '${period.id}.',
      );
    }

    return _PeriodInterval(period.id, relativeStart, relativeEnd);
  }

  static int _validateTime(String value, {required String fieldName}) {
    final match = _timePattern.firstMatch(value);
    if (match == null) {
      throw BusinessTimingProfileResolutionException(
        '$fieldName must use HH:mm in 24-hour local time; got "$value".',
      );
    }
    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final total = hours * 60 + minutes;
    if (total % 15 != 0) {
      throw BusinessTimingProfileResolutionException(
        '$fieldName must use 15-minute increments; got "$value".',
      );
    }
    return total;
  }

  static int _relativeToBusinessStart({
    required int minutes,
    required int businessStartMinutes,
  }) {
    final value = minutes - businessStartMinutes;
    return value < 0 ? value + _minutesPerDay : value;
  }

  static final RegExp _timePattern = RegExp(
    r'^([01][0-9]|2[0-3]):([0-5][0-9])$',
  );
  static const int _minutesPerDay = 24 * 60;
}

class _PeriodInterval {
  final String id;
  final int start;
  final int end;

  const _PeriodInterval(this.id, this.start, this.end);
}
