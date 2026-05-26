import '../../services/settings/applicability_metadata_schemas.dart';

class VendorApplicabilityRecommendedDefault {
  const VendorApplicabilityRecommendedDefault({
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    this.metadata = const <String, Object?>{},
  });

  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
}

List<VendorApplicabilityRecommendedDefault>
recommendedVendorApplicabilityDefaultsFor(String settingKind) {
  return kVendorApplicabilityRecommendedDefaults
      .where((row) => row.settingKind == settingKind)
      .toList(growable: false);
}

final List<VendorApplicabilityRecommendedDefault>
kVendorApplicabilityRecommendedDefaults = List.unmodifiable(
  <VendorApplicabilityRecommendedDefault>[
    // Wage.
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'adp',
      enabled: true,
      metadata: <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
        'vendor_field': 'gross_wages',
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'agendrix',
      enabled: true,
      metadata: <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'humanity',
      enabled: true,
      metadata: <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'push_operations',
      enabled: true,
      metadata: <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'quickbooks_time',
      enabled: true,
      metadata: <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'seven_shifts',
      enabled: true,
      metadata: <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'toast',
      enabled: true,
      metadata: <String, Object?>{
        'authority_basis': 'vendor_pay_rate',
        'vendor_field': 'gross_wages',
        'notes': 'Requires Toast Payroll add-on.',
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'square',
      enabled: true,
      metadata: <String, Object?>{
        'authority_basis': 'vendor_pay_rate',
        'notes': 'Requires Square Payroll subscription.',
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'clover',
      enabled: false,
      metadata: <String, Object?>{
        'authority_basis': 'manual_mapping',
        'notes': 'Clover labor module not certified for wage authority.',
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.wage,
      settingKey: 'default',
      vendorSlug: 'oracle_micros_simphony',
      enabled: false,
      metadata: <String, Object?>{
        'authority_basis': 'manual_mapping',
        'notes': 'Simphony exports rates only; not approved as wage source.',
      },
    ),

    // Covers.
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'libro',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'opentable',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'sevenrooms',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'tock',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'toast',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'square',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'clover',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'aloha_ncr_voyix',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'lightspeed_lsk',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'revel',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.covers,
      settingKey: 'default',
      vendorSlug: 'oracle_micros_simphony',
      enabled: true,
      metadata: <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),

    // Data freshness.
    for (final vendor in <String>[
      'adp',
      'agendrix',
      'aloha_ncr_voyix',
      'clover',
      'humanity',
      'libro',
      'lightspeed_lsk',
      'opentable',
      'oracle_micros_simphony',
      'push_operations',
      'quickbooks_time',
      'revel',
      'seven_shifts',
      'sevenrooms',
      'square',
      'toast',
      'tock',
    ])
      VendorApplicabilityRecommendedDefault(
        settingKind: VendorApplicabilitySettingKind.polling,
        settingKey: 'standard',
        vendorSlug: vendor,
        enabled: true,
        metadata: <String, Object?>{'tier_key': 'standard'},
      ),
    VendorApplicabilityRecommendedDefault(
      settingKind: VendorApplicabilitySettingKind.polling,
      settingKey: 'premium',
      vendorSlug: 'toast',
      enabled: true,
      metadata: <String, Object?>{
        'tier_key': 'premium',
        'polling_seconds_override': 60,
      },
    ),
  ],
);
