// Hardening Wave B1 — domain-model tests for the keyed Data Accuracy
// service-period setting.
//
// Coverage focus:
//   * Wire round-trip for both enums (covers_source 4-way + wage_source
//     4-way). The aggregator + Operator Web Console depend on the wire
//     strings matching the SQL CHECK constraint.
//   * `fromRow` projects a representative SELECT shape end-to-end.
//   * `fromRow` rejects malformed rows with StateError so a future
//     refactor that drops a column from the SELECT cannot silently
//     return a half-constructed model.
//   * `fromRow` accepts both DateTime and ISO-string forms of the
//     `effective_at_business_date` column (Postgres returns DateTime
//     for `date` columns under `package:postgres`; tests + CSVs feed
//     ISO strings).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';

void main() {
  group('ServicePeriodCoversSource wire round-trip', () {
    test('every enum value round-trips through wire/fromWire', () {
      for (final value in ServicePeriodCoversSource.values) {
        expect(
          ServicePeriodCoversSourceWire.fromWire(value.wire),
          equals(value),
        );
      }
    });

    test('wire values match the SQL CHECK constraint values exactly', () {
      expect(ServicePeriodCoversSource.vendor.wire, equals('vendor'));
      expect(ServicePeriodCoversSource.forecast.wire, equals('forecast'));
      expect(ServicePeriodCoversSource.manual.wire, equals('manual'));
      expect(
        ServicePeriodCoversSource.reservationPlusWalkin.wire,
        equals('reservation_plus_walkin'),
      );
    });

    test('fromWire rejects an unknown value with ArgumentError', () {
      expect(
        () => ServicePeriodCoversSourceWire.fromWire('phantom'),
        throwsArgumentError,
      );
    });
  });

  group('ServicePeriodWageSource wire round-trip', () {
    test('every enum value round-trips through wire/fromWire', () {
      for (final value in ServicePeriodWageSource.values) {
        expect(
          ServicePeriodWageSourceWire.fromWire(value.wire),
          equals(value),
        );
      }
    });

    test('wire values match the SQL CHECK constraint values exactly', () {
      expect(
        ServicePeriodWageSource.vendorPerEmployee.wire,
        equals('vendor_per_employee'),
      );
      expect(
        ServicePeriodWageSource.vendorPerPosition.wire,
        equals('vendor_per_position'),
      );
      expect(
        ServicePeriodWageSource.targetSubstitution.wire,
        equals('target_substitution'),
      );
      expect(ServicePeriodWageSource.manualMix.wire, equals('manual_mix'));
    });

    test('fromWire rejects an unknown value with ArgumentError', () {
      expect(
        () => ServicePeriodWageSourceWire.fromWire('vendor_only'),
        throwsArgumentError,
      );
    });
  });

  group('DataAccuracyServicePeriodSetting.fromRow', () {
    test('projects a representative SELECT row end-to-end', () {
      final row = <String, Object?>{
        'id': '11111111-1111-1111-1111-111111111111',
        'operator_id': '22222222-2222-2222-2222-222222222222',
        'location_id': '33333333-3333-3333-3333-333333333333',
        'service_period_key': 'lunch',
        'covers_source': 'manual',
        'wage_source': 'manual_mix',
        'effective_at_business_date': '2026-05-01',
        'created_at': DateTime.utc(2026, 5, 1, 10),
        'updated_at': DateTime.utc(2026, 5, 1, 11),
        'updated_by': 'user_alpha',
      };
      final setting = DataAccuracyServicePeriodSetting.fromRow(row);
      expect(setting.id, equals('11111111-1111-1111-1111-111111111111'));
      expect(setting.servicePeriodKey, equals('lunch'));
      expect(
        setting.coversSource,
        equals(ServicePeriodCoversSource.manual),
      );
      expect(
        setting.wageSource,
        equals(ServicePeriodWageSource.manualMix),
      );
      expect(setting.effectiveAtBusinessDate, equals('2026-05-01'));
      expect(setting.updatedBy, equals('user_alpha'));
    });

    test(
      'accepts effective_at_business_date as DateTime — Postgres '
      'returns DateTime for date columns under package:postgres',
      () {
        final row = <String, Object?>{
          'id': '11111111-1111-1111-1111-111111111111',
          'operator_id': '22222222-2222-2222-2222-222222222222',
          'location_id': '33333333-3333-3333-3333-333333333333',
          'service_period_key': 'dinner',
          'covers_source': 'vendor',
          'wage_source': 'vendor_per_employee',
          'effective_at_business_date': DateTime.utc(2026, 6, 1),
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 1),
          'updated_by': null,
        };
        final setting = DataAccuracyServicePeriodSetting.fromRow(row);
        expect(setting.effectiveAtBusinessDate, equals('2026-06-01'));
        expect(setting.updatedBy, isNull);
      },
    );

    test(
      'rejects malformed row missing required column with StateError',
      () {
        final row = <String, Object?>{
          'id': '11111111-1111-1111-1111-111111111111',
          'operator_id': '22222222-2222-2222-2222-222222222222',
          // location_id missing
          'service_period_key': 'lunch',
          'covers_source': 'vendor',
          'wage_source': 'vendor_per_employee',
          'effective_at_business_date': '2026-05-01',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 1),
        };
        expect(
          () => DataAccuracyServicePeriodSetting.fromRow(row),
          throwsStateError,
        );
      },
    );

    test('rejects null effective_at_business_date with StateError', () {
      final row = <String, Object?>{
        'id': '11111111-1111-1111-1111-111111111111',
        'operator_id': '22222222-2222-2222-2222-222222222222',
        'location_id': '33333333-3333-3333-3333-333333333333',
        'service_period_key': 'lunch',
        'covers_source': 'vendor',
        'wage_source': 'vendor_per_employee',
        'effective_at_business_date': null,
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 1),
      };
      expect(
        () => DataAccuracyServicePeriodSetting.fromRow(row),
        throwsStateError,
      );
    });
  });
}
