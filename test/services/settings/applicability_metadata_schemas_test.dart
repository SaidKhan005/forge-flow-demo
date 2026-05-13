import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/settings/applicability_metadata_schemas.dart';

void main() {
  group('vendor applicability metadata schemas', () {
    test('accepts narrow per-kind metadata objects', () {
      expect(
        validateApplicabilityMetadata(
          settingKind: VendorApplicabilitySettingKind.wage,
          metadata: const <String, Object?>{
            'authority_basis': 'job_code',
            'requires_job_code': true,
            'vendor_field': 'job_code',
            'notes': 'seeded from vendor setup',
          },
        ).isValid,
        isTrue,
      );
      expect(
        validateApplicabilityMetadata(
          settingKind: VendorApplicabilitySettingKind.covers,
          metadata: const <String, Object?>{
            'cover_filter': 'dine_in_only',
            'service_periods': <String>['lunch', 'dinner'],
            'exclude_voids': true,
          },
        ).isValid,
        isTrue,
      );
      expect(
        validateApplicabilityMetadata(
          settingKind: VendorApplicabilitySettingKind.polling,
          metadata: const <String, Object?>{
            'polling_seconds_override': 900,
            'tier_key': 'premium',
            'reason': 'vendor quota',
          },
        ).isValid,
        isTrue,
      );
    });

    test('rejects unknown setting kinds instead of opening an EAV path', () {
      final result = validateApplicabilityMetadata(
        settingKind: 'new_surface',
        metadata: const <String, Object?>{'anything': true},
      );

      expect(result.isValid, isFalse);
      expect(result.code, 'unknown_setting_kind');
    });

    test('rejects keys outside the kind schema', () {
      final result = validateApplicabilityMetadata(
        settingKind: VendorApplicabilitySettingKind.wage,
        metadata: const <String, Object?>{
          'authority_basis': 'job_code',
          'arbitrary_json_slot': 'nope',
        },
      );

      expect(result.isValid, isFalse);
      expect(result.code, 'metadata_key_not_allowed');
    });

    test('assert helper throws with schema diagnostics', () {
      expect(
        () => assertApplicabilityMetadataValid(
          settingKind: VendorApplicabilitySettingKind.polling,
          metadata: const <String, Object?>{'polling_seconds_override': 15},
        ),
        throwsA(
          isA<ApplicabilityMetadataValidationException>().having(
            (error) => error.code,
            'code',
            'invalid_polling_seconds_override',
          ),
        ),
      );
    });
  });
}
