// Phase 11W.7 / Wave A2 - validator unit tests.
//
// Pure-Dart tests for the operator-web business-timing validator. One
// test per named error code in the proxy contract.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

const String _kOpId = '11111111-1111-1111-1111-111111111111';

Map<String, Object?> _validBody({
  String scopeKind = 'operator',
  String scopeId = _kOpId,
  String effectiveAt = '2026-05-06',
  String iana = 'America/Toronto',
  String weekStart = 'monday',
  String businessDayStart = '04:00',
  List<Map<String, Object?>>? servicePeriods,
}) {
  return <String, Object?>{
    'scopeKind': scopeKind,
    'scopeId': scopeId,
    'effectiveAtBusinessDate': effectiveAt,
    'ianaTimezone': iana,
    'weekStartDay': weekStart,
    'businessDayStartLocal': businessDayStart,
    'servicePeriods':
        servicePeriods ??
        const <Map<String, Object?>>[
          <String, Object?>{
            'key': 'lunch',
            'label': 'Lunch',
            'startLocal': '11:00',
            'endLocal': '15:00',
          },
          <String, Object?>{
            'key': 'dinner',
            'label': 'Dinner',
            'startLocal': '17:00',
            'endLocal': '22:00',
          },
        ],
  };
}

void main() {
  group('validateNewBusinessTimingProfile happy path', () {
    test('parses a complete profile with two non-overlapping periods', () {
      final result = validateNewBusinessTimingProfile(_validBody());
      expect(result.scopeKind, equals('operator'));
      expect(result.scopeId, equals(_kOpId));
      expect(result.weekStartDay, equals('monday'));
      expect(result.weekStartDayInt, equals(1));
      expect(result.servicePeriods, hasLength(2));
      expect(result.servicePeriods[0].rollsPastMidnight, isFalse);
      expect(result.servicePeriods[0].startMinute, equals(11 * 60));
      expect(
        result.servicePeriods[0].applicableDays,
        equals(<int>[1, 2, 3, 4, 5, 6, 7]),
      );
      expect(result.servicePeriods[0].shortLabel, isEmpty);
      expect(result.servicePeriods[0].sortOrder, equals(1));
    });

    test('preserves service-period metadata on complete profile', () {
      final result = validateNewBusinessTimingProfile(
        _validBody(
          servicePeriods: const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'brunch',
              'label': 'Weekend Brunch',
              'startLocal': '10:00',
              'endLocal': '14:00',
              'applicableDays': <int>[6, 7],
              'shortLabel': 'B',
              'sortOrder': 2,
            },
          ],
        ),
      );
      final period = result.servicePeriods.single;
      expect(period.applicableDays, equals(<int>[6, 7]));
      expect(period.shortLabel, equals('B'));
      expect(period.sortOrder, equals(2));
    });

    test('allows same clock window when applicable days do not overlap', () {
      final result = validateNewBusinessTimingProfile(
        _validBody(
          servicePeriods: const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'lunch',
              'label': 'Lunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
              'applicableDays': <int>[1, 2, 3, 4, 5],
              'sortOrder': 1,
            },
            <String, Object?>{
              'key': 'brunch',
              'label': 'Weekend Brunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
              'applicableDays': <int>[6, 7],
              'shortLabel': 'B',
              'sortOrder': 2,
            },
          ],
        ),
      );
      expect(result.servicePeriods, hasLength(2));
    });

    test('detects past-midnight period', () {
      final result = validateNewBusinessTimingProfile(
        _validBody(
          servicePeriods: const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'late_night',
              'label': 'Late Night',
              'startLocal': '22:00',
              'endLocal': '02:00',
            },
          ],
        ),
      );
      expect(result.servicePeriods.single.rollsPastMidnight, isTrue);
    });
  });

  group('validateNewBusinessTimingProfile error codes', () {
    test('invalid_period_count - empty array', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(servicePeriods: const <Map<String, Object?>>[]),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_period_count',
          ),
        ),
      );
    });

    test('invalid_period_count - 5 periods', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'breakfast',
                'label': 'Breakfast',
                'startLocal': '07:00',
                'endLocal': '10:00',
              },
              <String, Object?>{
                'key': 'brunch',
                'label': 'Brunch',
                'startLocal': '10:00',
                'endLocal': '11:00',
              },
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
              },
              <String, Object?>{
                'key': 'dinner',
                'label': 'Dinner',
                'startLocal': '17:00',
                'endLocal': '22:00',
              },
              <String, Object?>{
                'key': 'late_night',
                'label': 'Late Night',
                'startLocal': '22:00',
                'endLocal': '02:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_period_count',
          ),
        ),
      );
    });

    test('invalid_quarter_hour_boundary on businessDayStart', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(businessDayStart: '04:07'),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_quarter_hour_boundary',
          ),
        ),
      );
    });

    test('invalid_quarter_hour_boundary on a service period startLocal', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:01',
                'endLocal': '15:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_quarter_hour_boundary',
          ),
        ),
      );
    });

    test('service_period_overlap', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
              },
              <String, Object?>{
                'key': 'late_lunch',
                'label': 'Late Lunch',
                'startLocal': '14:00',
                'endLocal': '16:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'service_period_overlap',
          ),
        ),
      );
    });

    test('multiple_past_midnight_periods', () {
      // Two periods that each roll past midnight (end <= start).
      // The validator should reject before reaching the overlap check
      // because rollingCount > 1.
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            businessDayStart: '12:00',
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'a',
                'label': 'A',
                'startLocal': '22:00',
                'endLocal': '02:00',
              },
              <String, Object?>{
                // 03:00 to 03:00 same minute is invalid (start == end -> not rolling).
                // 04:00 to 03:00 rolls past midnight (end < start).
                'key': 'b',
                'label': 'B',
                'startLocal': '04:00',
                'endLocal': '03:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'multiple_past_midnight_periods',
          ),
        ),
      );
    });

    test('business_day_start_inside_period', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            businessDayStart: '12:00',
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'business_day_start_inside_period',
          ),
        ),
      );
    });

    test('invalid_iana_timezone', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(iana: 'America/Atlantis'),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_iana_timezone',
          ),
        ),
      );
    });

    test('duplicate_service_period_key', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
              },
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch 2',
                'startLocal': '17:00',
                'endLocal': '18:00',
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'duplicate_service_period_key',
          ),
        ),
      );
    });

    test('invalid_scope on bad UUID', () {
      expect(
        () =>
            validateNewBusinessTimingProfile(_validBody(scopeId: 'not-a-uuid')),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_scope',
          ),
        ),
      );
    });

    test('invalid_week_start_day', () {
      expect(
        () => validateNewBusinessTimingProfile(_validBody(weekStart: 'fryday')),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_week_start_day',
          ),
        ),
      );
    });

    test('invalid_applicable_days on duplicate weekday', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'brunch',
                'label': 'Brunch',
                'startLocal': '10:00',
                'endLocal': '14:00',
                'applicableDays': <int>[6, 6],
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_applicable_days',
          ),
        ),
      );
    });

    test('duplicate_sort_order', () {
      expect(
        () => validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
                'sortOrder': 1,
              },
              <String, Object?>{
                'key': 'dinner',
                'label': 'Dinner',
                'startLocal': '17:00',
                'endLocal': '22:00',
                'sortOrder': 1,
              },
            ],
          ),
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'duplicate_sort_order',
          ),
        ),
      );
    });
  });

  group('validateOperatorAccountPatch', () {
    test('happy path with all six editable fields', () {
      final result = validateOperatorAccountPatch(<String, Object?>{
        'businessName': 'Forge & Flow Demo',
        'logoUrl': 'https://example.com/logo.png',
        'currencyCode': 'CAD',
        'localeTag': 'en-CA',
        'weekStartDay': 'monday',
        'rolloverHour': 4,
      });
      expect(result.changedFieldNames, hasLength(6));
      expect(result.fields['business_name'], equals('Forge & Flow Demo'));
      expect(result.fields['preferred_currency'], equals('CAD'));
      expect(result.fields['rollover_hour'], equals(4));
    });

    test('invalid_business_name on empty string', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'businessName': '   ',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_business_name',
          ),
        ),
      );
    });

    test('invalid_business_name on null', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'businessName': null,
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_business_name',
          ),
        ),
      );
    });

    test('invalid_logo_url on http URL', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'logoUrl': 'http://example.com/logo.png',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_logo_url',
          ),
        ),
      );
    });

    test('logoUrl null is allowed (clears the field)', () {
      final result = validateOperatorAccountPatch(const <String, Object?>{
        'logoUrl': null,
      });
      expect(result.fields['logo_url'], isNull);
      expect(result.changedFieldNames, contains('logoUrl'));
    });

    test('invalid_currency_code on lowercase', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'currencyCode': 'usd',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_currency_code',
          ),
        ),
      );
    });

    test('invalid_locale_tag on bad shape', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'localeTag': 'EN_US',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_locale_tag',
          ),
        ),
      );
    });

    test('invalid_week_start_day', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'weekStartDay': 'satturday',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_week_start_day',
          ),
        ),
      );
    });

    test('invalid_rollover_hour on out of range', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'rolloverHour': 24,
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_rollover_hour',
          ),
        ),
      );
    });

    test('invalid_field on unknown key', () {
      expect(
        () => validateOperatorAccountPatch(const <String, Object?>{
          'mysteryField': 'oops',
        }),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_field',
          ),
        ),
      );
    });
  });

  group('validateAddServicePeriod', () {
    test('happy path adds one period to an existing profile', () {
      final existing = validateNewBusinessTimingProfile(
        _validBody(
          servicePeriods: const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'lunch',
              'label': 'Lunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
            },
          ],
        ),
      );
      final outcome = validateAddServicePeriod(
        body: const <String, Object?>{
          'key': 'dinner',
          'label': 'Dinner',
          'startLocal': '17:00',
          'endLocal': '22:00',
        },
        existing: existing,
      );
      expect(outcome.added.key, equals('dinner'));
      expect(outcome.merged, hasLength(2));
    });

    test('preserves existing and added metadata in merged set', () {
      final existing = validateNewBusinessTimingProfile(
        _validBody(
          servicePeriods: const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'lunch',
              'label': 'Lunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
              'applicableDays': <int>[1, 2, 3, 4, 5],
              'shortLabel': 'L',
              'sortOrder': 1,
            },
          ],
        ),
      );
      final outcome = validateAddServicePeriod(
        body: const <String, Object?>{
          'key': 'brunch',
          'label': 'Weekend Brunch',
          'startLocal': '10:00',
          'endLocal': '14:00',
          'applicableDays': <int>[6, 7],
          'shortLabel': 'B',
          'sortOrder': 2,
        },
        existing: existing,
      );
      expect(outcome.merged[0].applicableDays, equals(<int>[1, 2, 3, 4, 5]));
      expect(outcome.merged[0].shortLabel, equals('L'));
      expect(outcome.merged[0].sortOrder, equals(1));
      expect(outcome.merged[1].applicableDays, equals(<int>[6, 7]));
      expect(outcome.merged[1].shortLabel, equals('B'));
      expect(outcome.merged[1].sortOrder, equals(2));
    });

    test('duplicate_service_period_key', () {
      final existing = validateNewBusinessTimingProfile(_validBody());
      expect(
        () => validateAddServicePeriod(
          body: const <String, Object?>{
            'key': 'lunch',
            'label': 'Lunch 2',
            'startLocal': '17:30',
            'endLocal': '18:30',
          },
          existing: existing,
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'duplicate_service_period_key',
          ),
        ),
      );
    });
  });

  group('validateUpdateServicePeriod', () {
    test(
      'partial profile patch preserves existing service-period metadata',
      () {
        final existing = validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'brunch',
                'label': 'Weekend Brunch',
                'startLocal': '10:00',
                'endLocal': '14:00',
                'applicableDays': <int>[6, 7],
                'shortLabel': 'B',
                'sortOrder': 2,
              },
            ],
          ),
        );
        final patched = validateProfilePatch(
          body: const <String, Object?>{'businessDayStartLocal': '04:30'},
          existing: existing,
        );
        final period = patched.servicePeriods.single;
        expect(period.applicableDays, equals(<int>[6, 7]));
        expect(period.shortLabel, equals('B'));
        expect(period.sortOrder, equals(2));
      },
    );

    test('rejects key rename via PATCH', () {
      final existing = validateNewBusinessTimingProfile(_validBody());
      expect(
        () => validateUpdateServicePeriod(
          body: const <String, Object?>{'key': 'lunch_renamed'},
          urlKey: 'lunch',
          existing: existing,
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'invalid_field',
          ),
        ),
      );
    });

    test('service_period_not_found when url key is unknown', () {
      final existing = validateNewBusinessTimingProfile(_validBody());
      expect(
        () => validateUpdateServicePeriod(
          body: const <String, Object?>{'label': 'X'},
          urlKey: 'unknown_key',
          existing: existing,
        ),
        throwsA(
          isA<BusinessTimingValidationError>().having(
            (e) => e.code,
            'code',
            'service_period_not_found',
          ),
        ),
      );
    });

    test(
      'service-period PATCH can update metadata and keep untouched rows',
      () {
        final existing = validateNewBusinessTimingProfile(
          _validBody(
            servicePeriods: const <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
                'applicableDays': <int>[1, 2, 3, 4, 5],
                'shortLabel': 'L',
                'sortOrder': 1,
              },
              <String, Object?>{
                'key': 'brunch',
                'label': 'Weekend Brunch',
                'startLocal': '10:00',
                'endLocal': '14:00',
                'applicableDays': <int>[6, 7],
                'shortLabel': 'B',
                'sortOrder': 2,
              },
            ],
          ),
        );
        final merged = validateUpdateServicePeriod(
          body: const <String, Object?>{
            'applicableDays': <int>[1, 2, 3],
            'shortLabel': 'M',
            'sortOrder': 1,
          },
          urlKey: 'lunch',
          existing: existing,
        );
        expect(merged[0].applicableDays, equals(<int>[1, 2, 3]));
        expect(merged[0].shortLabel, equals('M'));
        expect(merged[0].sortOrder, equals(1));
        expect(merged[1].applicableDays, equals(<int>[6, 7]));
        expect(merged[1].shortLabel, equals('B'));
        expect(merged[1].sortOrder, equals(2));
      },
    );
  });
}
