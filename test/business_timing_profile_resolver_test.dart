import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_timing_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/business_timing_profile_resolver.dart';

const _lunch = ServicePeriodDefinition(
  id: 'lunch',
  label: 'Lunch',
  shortLabel: 'L',
  sortOrder: 1,
  startLocalTime: '11:00',
  endLocalTime: '15:00',
  rollsPastMidnight: false,
  applicableDays: [1, 2, 3, 4, 5],
);

const _dinner = ServicePeriodDefinition(
  id: 'dinner',
  label: 'Dinner',
  shortLabel: 'D',
  sortOrder: 2,
  startLocalTime: '17:00',
  endLocalTime: '23:00',
  rollsPastMidnight: false,
  applicableDays: [1, 2, 3, 4, 5, 6, 7],
);

const _lateNight = ServicePeriodDefinition(
  id: 'late_night',
  label: 'Late Night',
  shortLabel: 'LN',
  sortOrder: 3,
  startLocalTime: '23:00',
  endLocalTime: '02:00',
  rollsPastMidnight: true,
  applicableDays: [5, 6],
);

const _brunch = ServicePeriodDefinition(
  id: 'brunch',
  label: 'Brunch',
  shortLabel: 'BR',
  sortOrder: 1,
  startLocalTime: '09:00',
  endLocalTime: '13:00',
  rollsPastMidnight: false,
  applicableDays: [6, 7],
);

BusinessTimingProfile _operatorDefault({
  List<ServicePeriodDefinition>? servicePeriods = const [_lunch, _dinner],
}) {
  return BusinessTimingProfile(
    profileId: 'operator-default',
    scope: BusinessTimingScope.operatorDefault,
    scopeId: 'operator-1',
    businessTimezone: 'America/New_York',
    businessDayStartLocalTime: '04:00',
    weekStartDay: DateTime.monday,
    servicePeriodDefinitions: servicePeriods,
    shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
    localCloseFallback: '04:00',
  );
}

BusinessTimingProfile _orgUnit({
  String profileId = 'region',
  String scopeId = 'region-1',
  String? businessTimezone,
  String? businessDayStartLocalTime,
  int? weekStartDay,
  List<ServicePeriodDefinition>? servicePeriods,
  ShiftCloseAuthority? shiftCloseAuthority,
}) {
  return BusinessTimingProfile(
    profileId: profileId,
    scope: BusinessTimingScope.orgUnit,
    scopeId: scopeId,
    businessTimezone: businessTimezone,
    businessDayStartLocalTime: businessDayStartLocalTime,
    weekStartDay: weekStartDay,
    servicePeriodDefinitions: servicePeriods,
    shiftCloseAuthority: shiftCloseAuthority,
  );
}

BusinessTimingProfile _location({
  String? businessTimezone,
  String? businessDayStartLocalTime,
  int? weekStartDay,
  List<ServicePeriodDefinition>? servicePeriods,
  ShiftCloseAuthority? shiftCloseAuthority,
}) {
  return BusinessTimingProfile(
    profileId: 'location',
    scope: BusinessTimingScope.location,
    scopeId: 'loc-1',
    businessTimezone: businessTimezone,
    businessDayStartLocalTime: businessDayStartLocalTime,
    weekStartDay: weekStartDay,
    servicePeriodDefinitions: servicePeriods,
    shiftCloseAuthority: shiftCloseAuthority,
  );
}

void _expectResolutionFailure(List<BusinessTimingProfile> profiles) {
  expect(
    () => BusinessTimingProfileResolver.resolve(profiles),
    throwsA(isA<BusinessTimingProfileResolutionException>()),
  );
}

void main() {
  group('BusinessTimingProfileResolver inheritance', () {
    test('lower profiles override higher scalar fields', () {
      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(),
        _orgUnit(
          businessTimezone: 'America/Chicago',
          weekStartDay: DateTime.sunday,
        ),
        _location(
          businessDayStartLocalTime: '05:00',
          shiftCloseAuthority: ShiftCloseAuthority.vendorFinalization,
        ),
      ]);

      expect(effective.businessTimezone, 'America/Chicago');
      expect(effective.businessDayStartLocalTime, '05:00');
      expect(effective.weekStartDay, DateTime.sunday);
      expect(
        effective.shiftCloseAuthority,
        ShiftCloseAuthority.vendorFinalization,
      );
      expect(effective.resolvedScope, BusinessTimingScope.location);
      expect(effective.resolvedScopeId, 'loc-1');
    });

    test('service periods override atomically instead of merging', () {
      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(servicePeriods: const [_lunch, _dinner]),
        _orgUnit(servicePeriods: const [_brunch]),
        _location(servicePeriods: const [_dinner, _lateNight]),
      ]);

      expect(effective.servicePeriodDefinitions.map((d) => d.id), [
        'dinner',
        'late_night',
      ]);
    });

    test('null service-period override inherits the higher set', () {
      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(servicePeriods: const [_lunch, _dinner]),
        _orgUnit(servicePeriods: const [_brunch]),
        _location(),
      ]);

      expect(effective.servicePeriodDefinitions.map((d) => d.id), ['brunch']);
    });

    test('effective profile can be converted to RestaurantTimingConfig', () {
      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(),
        _location(businessTimezone: 'America/St_Johns'),
      ]);

      final config = effective.toRestaurantTimingConfig(
        restaurantId: 'restaurant-1',
        createdAt: '2026-05-06T10:00:00Z',
        updatedAt: '2026-05-06T10:00:00Z',
      );

      expect(config.restaurantId, 'restaurant-1');
      expect(config.businessTimezone, 'America/St_Johns');
      expect(
        config.servicePeriodDefinitions,
        effective.servicePeriodDefinitions,
      );
    });
  });

  group('BusinessTimingProfileResolver validation', () {
    test('requires all effective fields after inheritance', () {
      _expectResolutionFailure([
        const BusinessTimingProfile(
          profileId: 'empty',
          scope: BusinessTimingScope.operatorDefault,
          scopeId: 'operator-1',
        ),
      ]);
    });

    test('allows one to four effective service periods', () {
      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(servicePeriods: const [_lunch]),
      ]);
      expect(effective.servicePeriodDefinitions, hasLength(1));
    });

    test('rejects more than four service periods', () {
      const extra1 = ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 0,
        startLocalTime: '07:00',
        endLocalTime: '09:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5],
      );
      const extra2 = ServicePeriodDefinition(
        id: 'happy_hour',
        label: 'Happy Hour',
        shortLabel: 'HH',
        sortOrder: 4,
        startLocalTime: '15:00',
        endLocalTime: '16:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5],
      );

      _expectResolutionFailure([
        _operatorDefault(
          servicePeriods: const [extra1, _lunch, extra2, _dinner, _lateNight],
        ),
      ]);
    });

    test('rejects overlapping periods on the same business date', () {
      const overlappingLunch = ServicePeriodDefinition(
        id: 'overlap_lunch',
        label: 'Overlap Lunch',
        shortLabel: 'OL',
        sortOrder: 2,
        startLocalTime: '14:00',
        endLocalTime: '18:00',
        rollsPastMidnight: false,
        applicableDays: [1],
      );

      _expectResolutionFailure([
        _operatorDefault(servicePeriods: const [_lunch, overlappingLunch]),
      ]);
    });

    test('allows overlapping clock ranges on different weekdays', () {
      const mondayLunch = ServicePeriodDefinition(
        id: 'monday_lunch',
        label: 'Monday Lunch',
        shortLabel: 'ML',
        sortOrder: 1,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1],
      );
      const tuesdayLunch = ServicePeriodDefinition(
        id: 'tuesday_lunch',
        label: 'Tuesday Lunch',
        shortLabel: 'TL',
        sortOrder: 1,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [2],
      );

      final effective = BusinessTimingProfileResolver.resolve([
        _operatorDefault(servicePeriods: const [mondayLunch, tuesdayLunch]),
      ]);

      expect(effective.servicePeriodDefinitions, hasLength(2));
    });

    test('rejects non-15-minute business-day and period times', () {
      _expectResolutionFailure([
        _operatorDefault(),
        _location(businessDayStartLocalTime: '04:10'),
      ]);

      const offIncrement = ServicePeriodDefinition(
        id: 'off_increment',
        label: 'Off Increment',
        shortLabel: 'OI',
        sortOrder: 1,
        startLocalTime: '11:10',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1],
      );
      _expectResolutionFailure([
        _operatorDefault(servicePeriods: const [offIncrement]),
      ]);
    });

    test('rejects more than one rolls-past-midnight period', () {
      const nightCap = ServicePeriodDefinition(
        id: 'night_cap',
        label: 'Night Cap',
        shortLabel: 'NC',
        sortOrder: 4,
        startLocalTime: '22:00',
        endLocalTime: '01:00',
        rollsPastMidnight: true,
        applicableDays: [5],
      );

      _expectResolutionFailure([
        _operatorDefault(servicePeriods: const [_dinner, _lateNight, nightCap]),
      ]);
    });

    test('rejects when business-day start falls inside a service period', () {
      const crossesBusinessStart = ServicePeriodDefinition(
        id: 'overnight',
        label: 'Overnight',
        shortLabel: 'ON',
        sortOrder: 1,
        startLocalTime: '03:00',
        endLocalTime: '05:00',
        rollsPastMidnight: false,
        applicableDays: [1],
      );

      _expectResolutionFailure([
        _operatorDefault(servicePeriods: const [crossesBusinessStart]),
      ]);
    });

    test(
      'rejects rollsPastMidnight when it does not match the clock range',
      () {
        const mismatched = ServicePeriodDefinition(
          id: 'mismatched',
          label: 'Mismatched',
          shortLabel: 'M',
          sortOrder: 1,
          startLocalTime: '23:00',
          endLocalTime: '02:00',
          rollsPastMidnight: false,
          applicableDays: [1],
        );

        _expectResolutionFailure([
          _operatorDefault(servicePeriods: const [mismatched]),
        ]);
      },
    );
  });
}
