// Pure helpers + presentation catalog for the friendly Vendor
// applicability admin screen.
//
// The Add/Edit dropdown and the rule chips need each vendor's
// operator-facing display name plus the three capability bits that drive
// per-kind filtering (category, covers-field exposure, webhook support).
// The authoritative source for that metadata is the proxy's pure-Dart
// `kAdminVisibleVendorCapabilityProfiles`
// (`tool/advisor_proxy/vendor_admin_status_catalog.dart`), which `lib/`
// app code must not import (it lives outside the published package and
// is built into the AOT proxy binary). So this file keeps a faithful
// `lib/`-side copy of just the fields this screen renders, guarded
// against drift by
// `test/admin/vendor_applicability_vendor_catalog_drift_test.dart`.
//
// The metadata-to-chips helper turns the narrow per-kind JSONB (see
// `lib/services/settings/applicability_metadata_schemas.dart`) into
// plain-English summary chips instead of raw JSON.

import '../../services/integration/integration_adapter_common.dart';
import '../../services/settings/applicability_metadata_schemas.dart';
import '../models/operator_location_admin_models.dart';

/// One vendor as the Vendor applicability screen needs to present it.
/// A trimmed projection of `VendorCapabilityProfile` carrying only the
/// fields the dropdown + chips + per-kind filter use.
class AdminVendorOption {
  const AdminVendorOption({
    required this.vendorId,
    required this.displayName,
    required this.category,
    required this.coversFieldExposed,
    required this.webhookSupport,
  });

  final String vendorId;
  final String displayName;
  final IntegrationCategory category;
  final bool coversFieldExposed;
  final VendorWebhookSupport webhookSupport;
}

/// Faithful `lib/`-side copy of the admin-visible vendor catalog,
/// projected to the fields this screen renders. Kept aligned with
/// `kAdminVisibleVendorCapabilityProfiles` by the drift test named in the
/// file header. Order matches the source catalog.
const List<AdminVendorOption> kAdminVendorApplicabilityOptions =
    <AdminVendorOption>[
      AdminVendorOption(
        vendorId: 'aloha_ncr_voyix',
        displayName: 'Aloha (NCR Voyix)',
        category: IntegrationCategory.pos,
        coversFieldExposed: true,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'clover',
        displayName: 'Clover',
        category: IntegrationCategory.pos,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'lightspeed_lsk',
        displayName: 'Lightspeed Restaurant K-Series',
        category: IntegrationCategory.pos,
        coversFieldExposed: true,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'oracle_micros_simphony',
        displayName: 'Oracle MICROS Simphony',
        category: IntegrationCategory.pos,
        coversFieldExposed: true,
        webhookSupport: VendorWebhookSupport.pollOnly,
      ),
      AdminVendorOption(
        vendorId: 'revel',
        displayName: 'Revel Systems',
        category: IntegrationCategory.pos,
        coversFieldExposed: true,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'square',
        displayName: 'Square',
        category: IntegrationCategory.pos,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'toast',
        displayName: 'Toast',
        category: IntegrationCategory.pos,
        coversFieldExposed: true,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'libro',
        displayName: 'Libro Reserve',
        category: IntegrationCategory.reservation,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'opentable',
        displayName: 'OpenTable',
        category: IntegrationCategory.reservation,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'sevenrooms',
        displayName: 'SevenRooms',
        category: IntegrationCategory.reservation,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.manualPaste,
      ),
      AdminVendorOption(
        vendorId: 'tock',
        displayName: 'Tock',
        category: IntegrationCategory.reservation,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.manualPaste,
      ),
      AdminVendorOption(
        vendorId: 'adp',
        displayName: 'ADP Workforce Now / Workforce Manager',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
      AdminVendorOption(
        vendorId: 'agendrix',
        displayName: 'Agendrix',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.pollOnly,
      ),
      AdminVendorOption(
        vendorId: 'humanity',
        displayName: 'Humanity',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.pollOnly,
      ),
      AdminVendorOption(
        vendorId: 'push_operations',
        displayName: 'Push Operations',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.pollOnly,
      ),
      AdminVendorOption(
        vendorId: 'quickbooks_time',
        displayName: 'QuickBooks Time',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.pollOnly,
      ),
      AdminVendorOption(
        vendorId: 'seven_shifts',
        displayName: '7shifts',
        category: IntegrationCategory.labor,
        coversFieldExposed: false,
        webhookSupport: VendorWebhookSupport.autoRegister,
      ),
    ];

/// Operator-facing display name for a vendor slug. Falls back to the raw
/// slug for any value the catalog does not know (e.g. an older row).
String vendorDisplayName(String vendorSlug) {
  for (final option in kAdminVendorApplicabilityOptions) {
    if (option.vendorId == vendorSlug) return option.displayName;
  }
  return vendorSlug;
}

/// Plain-English category label for a vendor slug.
String vendorCategoryLabel(String vendorSlug) {
  for (final option in kAdminVendorApplicabilityOptions) {
    if (option.vendorId == vendorSlug) {
      return _categoryLabel(option.category);
    }
  }
  return 'Vendor';
}

String _categoryLabel(IntegrationCategory category) {
  switch (category) {
    case IntegrationCategory.pos:
      return 'POS';
    case IntegrationCategory.labor:
      return 'Labor';
    case IntegrationCategory.reservation:
      return 'Reservations';
  }
}

/// Vendors that fit a setting kind, used to seed the Add/Edit dropdown
/// before the "Show all vendors" toggle is flipped:
///
///   * wage           -> labor vendors.
///   * covers         -> POS vendors that expose a covers field, or any
///                       reservation vendor.
///   * data freshness -> vendors with poll-only webhook support.
List<AdminVendorOption> vendorsForSettingKind(String settingKind) {
  bool predicate(AdminVendorOption v) {
    switch (settingKind) {
      case VendorApplicabilitySettingKind.wage:
        return v.category == IntegrationCategory.labor;
      case VendorApplicabilitySettingKind.covers:
        return (v.category == IntegrationCategory.pos &&
                v.coversFieldExposed) ||
            v.category == IntegrationCategory.reservation;
      case VendorApplicabilitySettingKind.polling:
        return v.webhookSupport == VendorWebhookSupport.pollOnly;
      default:
        return true;
    }
  }

  return kAdminVendorApplicabilityOptions
      .where(predicate)
      .toList(growable: false);
}

/// Human-readable "Applies to" label for a rule's scope. Resolves the
/// operator business name + location name from [operators] when present;
/// falls back to the raw id so the chip is never blank.
String appliesToLabelFor({
  required List<OperatorAdminBundle> operators,
  required String? operatorId,
  required String? locationId,
}) {
  if (operatorId == null) return 'All operators';
  final bundle = _bundleFor(operators, operatorId);
  final operatorLabel = bundle?.operator.businessName ?? operatorId;
  if (locationId == null) return operatorLabel;
  final locationLabel = _locationName(bundle, locationId) ?? locationId;
  return '$operatorLabel: $locationLabel';
}

OperatorAdminBundle? _bundleFor(
  List<OperatorAdminBundle> operators,
  String operatorId,
) {
  for (final b in operators) {
    if (b.operator.operatorId == operatorId) return b;
  }
  return null;
}

String? _locationName(OperatorAdminBundle? bundle, String locationId) {
  if (bundle == null) return null;
  for (final l in bundle.locations) {
    if (l.locationId == locationId) return l.name;
  }
  return null;
}

/// Friendly summary chips for a rule's per-kind metadata. Empty when the
/// rule has no extra detail. Never renders raw JSON.
List<String> friendlyMetadataChips({
  required String settingKind,
  required Map<String, Object?> metadata,
}) {
  final chips = <String>[];
  switch (settingKind) {
    case VendorApplicabilitySettingKind.wage:
      final basis = metadata['authority_basis'];
      if (basis is String) {
        chips.add('Pay rate: ${_wageAuthorityLabel(basis)}');
      }
      if (metadata['requires_job_code'] == true) {
        chips.add('Only shifts with a role');
      }
      final vendorField = metadata['vendor_field'];
      if (vendorField is String && vendorField.isNotEmpty) {
        chips.add('Vendor field: $vendorField');
      }
      break;
    case VendorApplicabilitySettingKind.covers:
      final filter = metadata['cover_filter'];
      if (filter is String) {
        chips.add('Guests: ${_coverFilterLabel(filter)}');
      }
      final periods = metadata['service_periods'];
      if (periods is List && periods.isNotEmpty) {
        chips.add('Periods: ${periods.whereType<String>().join(', ')}');
      }
      if (metadata['exclude_voids'] == true) {
        chips.add('Voided checks left out');
      }
      break;
    case VendorApplicabilitySettingKind.polling:
      final tier = metadata['tier_key'];
      if (tier is String) {
        chips.add('Check frequency: ${_tierLabel(tier)}');
      }
      final seconds = metadata['polling_seconds_override'];
      if (seconds is int) {
        chips.add('Every ${seconds ~/ 60} minutes');
      }
      break;
  }
  final notes = metadata['notes'];
  if (notes is String && notes.trim().isNotEmpty) {
    chips.add('Note: ${notes.trim()}');
  }
  return chips;
}

String _wageAuthorityLabel(String basis) {
  switch (basis) {
    case 'job_code':
      return 'by role';
    case 'vendor_pay_rate':
      return 'from vendor';
    case 'manual_mapping':
      return 'manual';
    default:
      return basis;
  }
}

String _coverFilterLabel(String filter) {
  switch (filter) {
    case 'dine_in_only':
      return 'dine-in only';
    case 'all_covers':
      return 'all guests';
    case 'exclude_cancelled':
      return 'no cancelled';
    default:
      return filter;
  }
}

String _tierLabel(String tier) {
  switch (tier) {
    case 'standard':
      return 'Standard';
    case 'premium':
      return 'Premium';
    case 'custom':
      return 'Custom';
    default:
      return tier;
  }
}
