import '../../operator_web/services/web_vendor_applicability_gateway.dart';
import 'vendor_applicability_admin_gateway.dart';

class AdminOperatorWebVendorApplicabilityGateway
    implements WebVendorApplicabilityGateway {
  const AdminOperatorWebVendorApplicabilityGateway({
    required VendorApplicabilityAdminGateway adminGateway,
    required String operatorId,
    required String locationId,
  }) : _adminGateway = adminGateway,
       _operatorId = operatorId,
       _locationId = locationId;

  final VendorApplicabilityAdminGateway _adminGateway;
  final String _operatorId;
  final String _locationId;

  @override
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  }) async {
    final rows = await _adminGateway.list(
      filter: VendorApplicabilityAdminFilter(
        operatorId: _operatorId,
        locationId: _locationId,
        settingKind: settingKind,
        settingKey: settingKey,
        currentOnly: true,
      ),
    );
    return <WebVendorApplicabilityRow>[
      for (final row in rows)
        WebVendorApplicabilityRow(
          id: row.id,
          operatorId: row.operatorId,
          settingKind: row.settingKind,
          settingKey: row.settingKey,
          vendorSlug: row.vendorSlug,
          enabled: row.enabled,
          metadata: row.metadata,
          effectiveFrom: row.effectiveFrom,
          effectiveUntil: row.effectiveUntil,
          createdAt: row.createdAt,
          createdBy: row.createdBy,
        ),
    ];
  }
}
