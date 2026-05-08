// Doc 1 timing web/admin live parity (2026-05-08) - tests for the
// operator-web Business setup live read adapter.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/http_business_timing_read_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';

void main() {
  group('HttpBusinessTimingReadGateway', () {
    late _RecordingWriteGateway live;
    late HttpBusinessTimingReadGateway gateway;

    setUp(() {
      live = _RecordingWriteGateway();
      gateway = HttpBusinessTimingReadGateway(gateway: live);
    });

    test('emits an empty bundle (writes-available) when no profiles exist',
        () async {
      live.profiles = const <BusinessTimingProfileWriteResult>[];
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
        operatorName: 'Acme Eats',
        locationName: 'Yonge & Bloor',
      );
      expect(bundle.writesAvailable, isTrue);
      expect(bundle.servicePeriods, isEmpty);
      expect(bundle.effectiveDateLabel, equals('No timing profile yet'));
      expect(bundle.hasLocationOverride, isFalse);
      expect(gateway.lastProfiles, isEmpty);
    });

    test(
        'projects operator-default fields with inherited markers when no '
        'location override exists', () async {
      live.profiles = <BusinessTimingProfileWriteResult>[
        _profile(
          profileId: 'op-default',
          scopeKind: 'operator',
          scopeId: 'op-1',
          ianaTimezone: 'America/Toronto',
          businessDayStart: '04:00',
          weekStart: 'monday',
        ),
      ];
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
        operatorName: 'Acme Eats',
        locationName: 'Yonge & Bloor',
      );
      expect(bundle.writesAvailable, isTrue);
      expect(bundle.hasLocationOverride, isFalse);
      expect(bundle.effectiveDateLabel, contains('2026-05-01'));
      expect(bundle.servicePeriods, hasLength(1));
      expect(bundle.servicePeriods.single.name, equals('Lunch'));
      // Every effective field reads as inherited from operator default.
      for (final field in bundle.effectiveFields) {
        expect(field.inherited, isTrue);
        expect(field.sourceLabel, equals('Operator default'));
      }
    });

    test(
        'flags the timezone field as a location override when the location '
        'profile differs', () async {
      live.profiles = <BusinessTimingProfileWriteResult>[
        _profile(
          profileId: 'op-default',
          scopeKind: 'operator',
          scopeId: 'op-1',
          ianaTimezone: 'America/Toronto',
          businessDayStart: '04:00',
          weekStart: 'monday',
        ),
        _profile(
          profileId: 'loc-override',
          scopeKind: 'location',
          scopeId: 'loc-1',
          ianaTimezone: 'America/Vancouver',
          businessDayStart: '04:00',
          weekStart: 'monday',
        ),
      ];
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(bundle.hasLocationOverride, isTrue);
      final tzField = bundle.effectiveFields.firstWhere(
        (f) => f.label == 'Timezone',
      );
      expect(tzField.value, equals('America/Vancouver'));
      expect(tzField.inherited, isFalse);
      expect(tzField.sourceLabel, equals('Location override'));
      // Business day start matches the operator default and is still
      // marked inherited.
      final dayField = bundle.effectiveFields.firstWhere(
        (f) => f.label == 'Business day starts',
      );
      expect(dayField.inherited, isTrue);
    });

    test(
        'selectProfileForLocation returns the location profile when present, '
        'else the operator default', () async {
      live.profiles = <BusinessTimingProfileWriteResult>[
        _profile(profileId: 'op-default', scopeKind: 'operator', scopeId: 'op-1'),
        _profile(
          profileId: 'loc-override',
          scopeKind: 'location',
          scopeId: 'loc-1',
        ),
      ];
      await gateway.loadTiming(operatorId: 'op-1', locationId: 'loc-1');
      expect(
        gateway.selectProfileForLocation('loc-1')?.profileId,
        equals('loc-override'),
      );
      expect(
        gateway.selectProfileForLocation('loc-other')?.profileId,
        equals('op-default'),
      );
    });

    test('selectProfileForLocation returns null before any load', () {
      expect(gateway.selectProfileForLocation('loc-1'), isNull);
    });

    test(
        'service periods come from the location override when the location '
        'profile defines any (whole-set replacement)', () async {
      live.profiles = <BusinessTimingProfileWriteResult>[
        _profile(
          profileId: 'op-default',
          scopeKind: 'operator',
          scopeId: 'op-1',
          servicePeriods: const <ServicePeriod>[
            ServicePeriod(
              key: 'lunch',
              label: 'Op Lunch',
              startLocal: '11:00',
              endLocal: '15:00',
              rollsPastMidnight: false,
            ),
          ],
        ),
        _profile(
          profileId: 'loc-override',
          scopeKind: 'location',
          scopeId: 'loc-1',
          servicePeriods: const <ServicePeriod>[
            ServicePeriod(
              key: 'brunch',
              label: 'Loc Brunch',
              startLocal: '09:00',
              endLocal: '12:00',
              rollsPastMidnight: false,
            ),
          ],
        ),
      ];
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(bundle.servicePeriods, hasLength(1));
      expect(bundle.servicePeriods.single.name, equals('Loc Brunch'));
    });
  });
}

BusinessTimingProfileWriteResult _profile({
  required String profileId,
  required String scopeKind,
  required String scopeId,
  String ianaTimezone = 'America/Toronto',
  String businessDayStart = '04:00',
  String weekStart = 'monday',
  List<ServicePeriod>? servicePeriods,
}) {
  return BusinessTimingProfileWriteResult(
    profileId: profileId,
    versionId: profileId,
    scopeKind: scopeKind,
    scopeId: scopeId,
    effectiveAtBusinessDate: '2026-05-01',
    ianaTimezone: ianaTimezone,
    weekStartDay: weekStart,
    businessDayStartLocal: businessDayStart,
    servicePeriods: servicePeriods ??
        const <ServicePeriod>[
          ServicePeriod(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
            rollsPastMidnight: false,
          ),
        ],
    createdAt: DateTime.utc(2026, 5, 1),
    updatedAt: DateTime.utc(2026, 5, 1),
  );
}

class _RecordingWriteGateway implements WebBusinessTimingGateway {
  List<BusinessTimingProfileWriteResult> profiles =
      const <BusinessTimingProfileWriteResult>[];
  int listCalls = 0;

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async {
    listCalls += 1;
    return List<BusinessTimingProfileWriteResult>.unmodifiable(profiles);
  }

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async {
    throw UnimplementedError();
  }
}
